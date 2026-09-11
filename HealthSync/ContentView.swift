import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("概览", systemImage: "waveform.path.ecg")
                }
            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
        }
    }
}

#Preview {
    ContentView()
        .environment(HermesSettings())
        .environment(AppState.shared)
}
