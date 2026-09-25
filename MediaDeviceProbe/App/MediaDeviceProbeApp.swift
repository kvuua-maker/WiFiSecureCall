import SwiftUI

@main
struct MediaDeviceProbeApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Text("WiFi Secure Call")
                    .font(.title2.bold())
                Text("Media Device Route Probe")
                    .font(.headline)
                Text("This isolated app only installs the iOS 27 Media Sharing Extension used to test whether Phone can expose it as a call-audio route.")
                    .multilineTextAlignment(.center)
                    .padding()
            }
            .padding()
        }
    }
}
