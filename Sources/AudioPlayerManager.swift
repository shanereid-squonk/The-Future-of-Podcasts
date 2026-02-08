import AVFoundation
import Combine

extension Notification.Name {
    static let audioDurationUpdated = Notification.Name("AudioDurationUpdated")
}

final class AudioPlayerManager: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isBuffering: Bool = false

    private var itemFailureObserver: NSObjectProtocol?
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var bufferEmptyObserver: NSKeyValueObservation?
    private var likelyToKeepUpObserver: NSKeyValueObservation?
    private var statusObserver: NSKeyValueObservation?
    private var interruptionObserver: NSObjectProtocol?
    private var wasPlayingBeforeInterruption = false

    private func configureAudioSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
        } catch {
            // Failed to set audio session; playback may be muted by silent switch
        }
        #endif
    }

    private func removeTimeObserver() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    func load(url: URL) {
        // Reset any existing state
        pause()
        removeTimeObserver()

        // Detach and release any existing player item and observer
        if let _ = player?.currentItem {
            player?.replaceCurrentItem(with: nil)
        }
        player = nil
        if let token = itemFailureObserver {
            NotificationCenter.default.removeObserver(token)
            itemFailureObserver = nil
        }
        bufferEmptyObserver = nil
        likelyToKeepUpObserver = nil
        statusObserver = nil
        if let token = interruptionObserver {
            NotificationCenter.default.removeObserver(token)
            interruptionObserver = nil
        }
        wasPlayingBeforeInterruption = false

        // Clear published state so UI resets
        isPlaying = false
        currentTime = 0
        duration = 0
        isBuffering = false

        // Create and assign a new player for the provided URL (simple, stable path)
        let item = AVPlayerItem(url: url)
        isBuffering = true

        // Observe buffering state
        bufferEmptyObserver = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] _, change in
            guard let self else { return }
            DispatchQueue.main.async { self.isBuffering = true }
        }
        likelyToKeepUpObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] _, change in
            guard let self else { return }
            DispatchQueue.main.async { self.isBuffering = true != (change.newValue ?? false) }
        }
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                if item.status == .readyToPlay {
                    self.isBuffering = false
                }
            }
        }

        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        newPlayer.seek(to: .zero)
        player = newPlayer

        // Configure audio session so playback works even with the silent switch
        configureAudioSession()

        #if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            guard let info = note.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            switch type {
            case .began:
                self.wasPlayingBeforeInterruption = self.isPlaying
                self.pause()
            case .ended:
                if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume), self.wasPlayingBeforeInterruption {
                        self.play()
                    }
                }
                self.wasPlayingBeforeInterruption = false
            @unknown default:
                break
            }
        }
        #endif

        // Optional: observe failures to aid debugging
        itemFailureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { note in
            if let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                print("AVPlayer failed to play: \(err)")
            } else {
                print("AVPlayer failed to play to end.")
            }
        }

        // Start observing time updates for UI
        observeTime()
    }

    func play() {
        player?.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player?.seek(to: time)
    }

    private func observeTime() {
        guard let player else { return }
        let interval = CMTime(seconds: 0.1, preferredTimescale: 1000)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            currentTime = time.seconds
            if let durationSeconds = player.currentItem?.duration.seconds, durationSeconds.isFinite {
                if duration != durationSeconds {
                    duration = durationSeconds
                    NotificationCenter.default.post(name: .audioDurationUpdated, object: nil, userInfo: ["duration": durationSeconds])
                } else {
                    duration = durationSeconds
                }
            }
        }
    }

    deinit {
        bufferEmptyObserver = nil
        likelyToKeepUpObserver = nil
        statusObserver = nil
        if let token = interruptionObserver { NotificationCenter.default.removeObserver(token) }
        removeTimeObserver()
    }
}

