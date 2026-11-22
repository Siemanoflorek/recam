import SwiftUI

/// Headless: po starcie pyta o mikrofon i gaśnie (czarny ekran).
/// Nasłuch i sterowanie idą z panelu na realiveserwis.pl.
/// Potrójne dotknięcie ekranu pokazuje mały status (do testów).
struct ContentView: View {
    @StateObject private var streamer = AudioStreamer()
    @State private var permissionDenied = false
    @State private var showStatus = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if permissionDenied {
                VStack(spacing: 10) {
                    Text("Brak zgody na mikrofon")
                        .foregroundColor(.white)
                    Text("Włącz w Ustawieniach → RealCam")
                        .foregroundColor(.gray).font(.footnote)
                }
            } else if showStatus {
                VStack(spacing: 8) {
                    Text("RealCam").foregroundColor(.white).font(.headline)
                    Text(streamer.statusText)
                        .foregroundColor(streamer.connected ? .green : .gray)
                        .font(.footnote)
                }
            }
        }
        .statusBarHidden(true)
        .contentShape(Rectangle())
        .onTapGesture(count: 3) { showStatus.toggle() }   // ukryty podgląd statusu
        .onAppear {
            streamer.requestPermission { granted in
                if granted { streamer.begin() } else { permissionDenied = true }
            }
        }
    }
}
