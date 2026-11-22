import SwiftUI

struct ContentView: View {
    @StateObject private var streamer = AudioStreamer()
    @AppStorage("host") private var host = "192.168.1.100"
    @AppStorage("port") private var port = "8000"
    @State private var permissionDenied = false

    var body: some View {
        VStack(spacing: 18) {
            Text("RealCam · Nasłuch")
                .font(.largeTitle.bold())
            Text(streamer.statusText)
                .foregroundStyle(streamer.running ? .green : .secondary)
                .font(.subheadline)

            // Miernik głośności
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 6)
                        .fill(streamer.level > 0.5 ? Color.red : Color.green)
                        .frame(width: geo.size.width * streamer.level)
                        .animation(.easeOut(duration: 0.1), value: streamer.level)
                }
            }
            .frame(height: 18)

            VStack(spacing: 10) {
                TextField("IP serwera (PC)", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.decimalPad)
                    .autocorrectionDisabled()
                TextField("Port", text: $port)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
            }

            if streamer.connected {
                Button(role: .destructive) {
                    streamer.disconnect()
                } label: {
                    Text("Zatrzymaj nasłuch").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Text("Możesz zablokować telefon lub zgasić ekran — nasłuch działa dalej w tle.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Button {
                    streamer.connect(host: host, port: Int(port) ?? 8000)
                } label: {
                    Text("Połącz i nasłuchuj").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            if permissionDenied {
                Text("Brak zgody na mikrofon. Włącz go w Ustawieniach → RealCam.")
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .padding()
        .onAppear {
            streamer.requestPermission { granted in
                permissionDenied = !granted
            }
        }
    }
}
