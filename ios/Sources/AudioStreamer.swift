import AVFoundation
import Foundation

/// RealCam — nasłuch headless. Po starcie łączy się do przekaźnika w panelu
/// (wss, przez internet), streamuje mikrofon i słucha komend start/stop z panelu.
/// Działa w tle (tryb audio) i sam się łączy ponownie po zerwaniu sieci.
final class AudioStreamer: NSObject, ObservableObject {

    @Published var statusText = "Start…"
    @Published var connected = false
    @Published var paused = false

    // ===== KONFIGURACJA (adres panelu + sekret telefonu) =====
    private let serverURL =
        "wss://realiveserwis.pl/ws/realcam?role=phone&token=__REALCAM_TOKEN__"
    // =========================================================

    private var engine = AVAudioEngine()
    private let silenceEngine = AVAudioEngine()   // cisza podtrzymująca życie w tle (bez mikrofonu)
    private var silenceNode: AVAudioSourceNode?
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let sendQueue = DispatchQueue(label: "realcam.send")
    private var sending = false

    private var shouldRun = false
    private var reconnecting = false

    // MARK: - Uprawnienia
    func requestPermission(completion: @escaping (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // MARK: - Start (wywoływane raz, po zgodzie na mikrofon)
    func begin() {
        guard !shouldRun else { return }
        shouldRun = true
        startAudio()
        connect()
        registerInterruptionHandler()
    }

    // MARK: - WebSocket + automatyczne wznawianie
    private func connect() {
        guard shouldRun, let url = URL(string: serverURL) else { return }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        urlSession = session
        let task = session.webSocketTask(with: url)
        webSocket = task
        task.resume()
        setStatus("Łączenie…")
        receiveLoop()
    }

    private func scheduleReconnect() {
        guard shouldRun, !reconnecting else { return }
        reconnecting = true
        DispatchQueue.main.async { self.connected = false; self.statusText = "Ponawiam…" }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.reconnecting = false
            self.webSocket = nil
            self.connect()
        }
    }

    private func receiveLoop() {
        webSocket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.scheduleReconnect()
            case .success(let message):
                switch message {
                case .string(let text): self.handleCommand(text)
                case .data(let d): if let t = String(data: d, encoding: .utf8) { self.handleCommand(t) }
                @unknown default: break
                }
                self.receiveLoop()
            }
        }
    }

    /// Komendy z panelu: {"cmd":"stop"} / {"cmd":"start"}
    private func handleCommand(_ text: String) {
        if text.contains("\"stop\"") {
            DispatchQueue.main.async { self.paused = true;  self.statusText = "Zatrzymano (panel)"; self.pauseCapture() }
        } else if text.contains("\"start\"") {
            DispatchQueue.main.async { self.paused = false; self.statusText = "Nasłuch"; self.resumeCapture() }
        }
    }

    // MARK: - Pauza / wznowienie (sterowanie z panelu)

    /// Pauza: wyłącza mikrofon (pomarańczowa kropka gaśnie), ale podtrzymuje
    /// działanie w tle cichym odtwarzaniem, żeby złapać komendę "wznów".
    private func pauseCapture() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        startSilence()
    }

    /// Wznowienie: wyłącza ciszę i włącza mikrofon z powrotem (kropka wraca).
    private func resumeCapture() {
        stopSilence()
        restartAudioWithRetry(0)   // ponawiaj — wejście bywa gotowe dopiero po chwili od zmiany kategorii
    }

    private func startSilence() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? s.setActive(true)
        if silenceNode == nil {
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
            let node = AVAudioSourceNode(format: fmt) { isSilence, _, _, abl -> OSStatus in
                isSilence.pointee = true
                let buffers = UnsafeMutableAudioBufferListPointer(abl)
                for b in buffers { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
                return noErr
            }
            silenceNode = node
            silenceEngine.attach(node)
            silenceEngine.connect(node, to: silenceEngine.mainMixerNode, format: fmt)
        }
        silenceEngine.prepare()
        try? silenceEngine.start()
    }

    private func stopSilence() {
        if silenceEngine.isRunning { silenceEngine.stop() }
    }

    // MARK: - Audio
    private func startAudio() {
        sending = false
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetooth])
            try s.setActive(true)
        } catch { setStatus("Błąd sesji audio"); return }

        // Świeży silnik — po przełączeniu sesji w pauzie (.playback) stary input bywa nieświeży.
        engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer, inputFormat: inputFormat)
        }
        engine.prepare()
        do { try engine.start() } catch { setStatus("Nie udało się uruchomić mikrofonu") }
    }

    private func handle(buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        // W pauzie trzymamy mikrofon aktywny (żeby żyć w tle i łapać "start"),
        // ale nie wysyłamy dźwięku.
        guard !paused, connected, !sending, let ws = webSocket, let converter else { return }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false; var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let data = Data(bytes: ch[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)

        sendQueue.async { [weak self] in
            guard let self, !self.sending else { return }
            self.sending = true
            ws.send(.data(data)) { _ in self.sending = false }
        }
    }

    // MARK: - Przerwania (połączenie, Siri) — wznawiamy nasłuch
    private func registerInterruptionHandler() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            stopSilence()
        } else if type == .ended {
            if paused { startSilence() } else { restartAudioWithRetry(0) }
        }
    }

    private func restartAudioWithRetry(_ attempt: Int) {
        guard shouldRun else { return }
        startAudio()
        if engine.isRunning { return }
        if attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.restartAudioWithRetry(attempt + 1)
            }
        }
    }

    private func setStatus(_ s: String) { DispatchQueue.main.async { self.statusText = s } }
}

// MARK: - Otwarcie/zamknięcie połączenia
extension AudioStreamer: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async {
            self.connected = true
            self.statusText = self.paused ? "Zatrzymano (panel)" : "Nasłuch"
        }
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        scheduleReconnect()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { scheduleReconnect() }
    }
}
