import SwiftUI

@main
struct NexusRemoteApp: App {
    @StateObject private var client = RemoteClient()
    @StateObject private var model = RemoteModel()
    @StateObject private var voice = PhoneVoice()

    var body: some Scene {
        WindowGroup {
            Group {
                if client.paired {
                    MainTabs()
                } else {
                    PairingView()
                }
            }
            .environmentObject(client)
            .environmentObject(model)
            .environmentObject(voice)
            .preferredColorScheme(.dark)
            .tint(RTheme.cyan)
            .onAppear { model.client = client }
        }
    }
}

struct MainTabs: View {
    @EnvironmentObject var model: RemoteModel
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            HomeView(tab: $tab).tabItem { Label("Home", systemImage: "circle.hexagongrid") }.tag(0)
            CommandView().tabItem { Label("Command", systemImage: "waveform") }.tag(1)
            ReviewView().tabItem { Label("Review", systemImage: "tray.full") }.badge(model.review.count).tag(2)
            InsightsView().tabItem { Label("Insights", systemImage: "lightbulb") }.badge(model.insights.count).tag(3)
            MoreView().tabItem { Label("More", systemImage: "square.grid.2x2") }.tag(4)
        }
        .task { await model.refreshAll() }
    }
}
