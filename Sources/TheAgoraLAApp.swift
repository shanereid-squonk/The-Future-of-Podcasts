import SwiftUI

@main
struct TheAgoraLAApp: App {
    @StateObject private var pointsStore = PointsStore()
    @StateObject private var episodeStore = EpisodeStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(pointsStore)
                .environmentObject(episodeStore)
        }
    }
}
