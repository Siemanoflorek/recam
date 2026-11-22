import AVFoundation
import Foundation

/// Nasłuchuje mikrofonu i wysyła dźwięk (PCM 16 kHz mono, Int16) po WebSocket
/// do serwera na PC. Działa też w tle / przy zablokowanym telefonie
/// dzięki trybowi `audio` w Info.plist.
final class AudioStreamer: NSObject, ObservableObject {

    @Published var connected = false
    @Published var running = false
    @Published var level: Double = 0        // 0…1, do miernika w aplikacji
    @Published var statusText = "Rozłączony"

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    private let sendQueue = DispatchQueue(label: "realcam.audio.send")
    private var sending = false

    // MARK: - Uprawnienia

    func requestPermission(completion: @escaping (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // MARK: - Połączenie

    func connect(host: String, port: Int) {
        let clean = host.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: "ws://\(clean):\(port)/stream") else {
            setStatus("Zły adres IP")
            return
        }
        let session = URLSession(configuration: .default)
        self.urlSession = session
        let task = session.webSocketTask(with: url)
        self.webSocket = task
        task.resume()
        receiveLoop()
        DispatchQueue.main.async {
            self.connected = true
            self.statusText = "Łączenie z \(clean)…"
        }
        startAudio()
        registerInterruptionHandler()
    }

    func disconnect() {
        stopAudio()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        NotificationCenter.default.removeObserver(self)
        DispatchQueue.main.async {
            self.connected = false
            self.running = false
            self.level = 0
            self.statusText = "Rozłączony"
        }
    }

    private func receiveLoop() {
        webSocket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.setStatus("Utracono połączenie")
            case .success:
                self.receiveLoop()
            }
        }
    }

    // MARK: - Sesja audio + silnik

    @discardableResult
    private func startAudio() -> Bool {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord,
                              mode: .default,
                              options: [.mixWithOthers, .allowBluetooth])
            try s.setActive(true)
        } catch {
            setStatus("Błąd sesji audio")
            return false
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        // W trakcie przerwania format bywa chwilowo pusty – wtedy jeszcze nie startujemy.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return false }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer, inputFormat: inputFormat)
        }

        engine.prepare()
        do {
            try engine.start()
            DispatchQueue.main.async {
                self.running = true
                self.statusText = "Nasłuch…"
            }
            return true
        } catch {
            setStatus("Nie udało się uruchomić mikrofonu")
            return false
        }
    }

    private func stopAudio() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Konwersja + wysyłka klatki

    private func handle(buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }

        let count = Int(out.frameLength)
        let data = Data(bytes: ch[0], count: count * MemoryLayout<Int16>.size)

        // Miernik głośności (RMS) do podglądu w aplikacji.
        updateLevel(ch[0], count: count)

        sendQueue.async { [weak self] in
            guard let self, !self.sending, let ws = self.webSocket else { return }
            self.sending = true
            ws.send(.data(data)) { _ in self.sending = false }
        }
    }

    private func updateLevel(_ samples: UnsafeMutablePointer<Int16>, count: Int) {
        guard count > 0 else { return }
        var sum: Double = 0
        for i in 0..<count {
            let v = Double(samples[i])
            sum += v * v
        }
        let rms = (sum / Double(count)).squareRoot()
        let lvl = min(1.0, rms / 32_768 * 4)
        DispatchQueue.main.async { self.level = lvl }
    }

    // MARK: - Przerwania (połączenie, Siri, reset audio)

    private func registerInterruptionHandler() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleInterruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: nil)
        // Gdy serwer audio systemu się zresetuje – trzeba zbudować wszystko od zera.
        nc.addObserver(self, selector: #selector(handleMediaReset),
                       name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // Wchodzi połączenie – iOS przejmuje mikrofon. Czysto zatrzymujemy,
            // ale NIE rozłączamy WebSocket – sesja z serwerem zostaje.
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            DispatchQueue.main.async {
                self.running = false
                self.statusText = "Przerwa (połączenie)…"
            }
        case .ended:
            // Rozmowa skończona – wracamy do nasłuchu. System zwalnia mikrofon
            // z lekkim opóźnieniem, więc ponawiamy aż się uda.
            if connected { restartWithRetry(attempt: 0) }
        @unknown default:
            break
        }
    }

    @objc private func handleMediaReset() {
        if connected {
            converter = nil
            restartWithRetry(attempt: 0)
        }
    }

    /// Wznawia nasłuch po przerwie. Jeśli mikrofon nie jest jeszcze wolny
    /// (np. tuż po odłożeniu słuchawki), próbuje ponownie co 0,5 s.
    private func restartWithRetry(attempt: Int) {
        guard connected else { return }
        if startAudio() {
            return                      // wróciło – koniec
        }
        guard attempt < 20 else {       // ~10 s prób, potem odpuść
            setStatus("Nie udało się wznowić — kliknij Połącz ponownie")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.restartWithRetry(attempt: attempt + 1)
        }
    }

    private func setStatus(_ s: String) {
        DispatchQueue.main.async { self.statusText = s }
    }
}
