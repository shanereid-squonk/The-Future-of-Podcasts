import Foundation

final class PlayerDurationCache {
    static let shared = PlayerDurationCache()
    private init() {}

    // Last known audio duration in seconds, updated by ContentView when
    // AudioPlayerManager posts .audioDurationUpdated notifications.
    var duration: Double = 0
}
