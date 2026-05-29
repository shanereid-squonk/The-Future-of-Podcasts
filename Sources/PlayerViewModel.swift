import Foundation
import Combine
import AVFoundation

@MainActor
final class PlayerViewModel: NSObject, ObservableObject {
    enum DrivingPromptState: Equatable {
        case idle
        case announcingPrompt
        case listening
        case submitting
        case speakingFeedback
    }

    @Published var episode: Episode = MockEpisodeProvider.sample
    @Published var activePrompt: Prompt?
    @Published var showPrompt = false
    @Published var answerText = ""
    @Published var feedbackText = ""
    @Published var lastScore: Int = 0
    @Published var lastGrade: PromptGrade = .f
    @Published var lastAwardedPoints: Int = 0
    @Published var isEvaluating = false
    @Published var interactiveModeEnabled = true
    @Published var promptResults: [PromptResult] = []
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var drivingModeEnabled = false
    @Published private(set) var drivingPromptState: DrivingPromptState = .idle
    @Published private(set) var drivingStatusText: String = ""

    let audioManager = AudioPlayerManager()
    let speechManager = SpeechRecognitionManager()
    let aiService = AIService()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var cancellables = Set<AnyCancellable>()

    private var promptedIDs = Set<UUID>()
    private let nowPlaying = NowPlayingManager.shared
    private weak var pointsStore: PointsStore?
    private var silenceWatchTask: Task<Void, Never>?
    private var transcriptUpdateDate = Date()
    private var listeningStartDate = Date()

    override init() {
        super.init()
        speechSynthesizer.delegate = self
        audioManager.load(url: episode.audioURL)
        audioManager.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.isPlaying = value
            }
            .store(in: &cancellables)

        audioManager.$currentTime
            .receive(on: RunLoop.main)
            .sink { [weak self] t in
                self?.currentTime = t
            }
            .store(in: &cancellables)

        audioManager.$duration
            .receive(on: RunLoop.main)
            .sink { [weak self] d in
                self?.duration = d
            }
            .store(in: &cancellables)

        // Wire remote command handlers
        nowPlaying.playHandler = { [weak self] in self?.audioManager.play() }
        nowPlaying.pauseHandler = { [weak self] in self?.audioManager.pause() }
        nowPlaying.skipForwardHandler = { [weak self] in self?.skip(by: 15) }
        nowPlaying.skipBackwardHandler = { [weak self] in self?.skip(by: -15) }

        audioManager.$currentTime
            .receive(on: RunLoop.main)
            .sink { [weak self] t in
                guard let self else { return }
                self.nowPlaying.update(elapsed: t, isPlaying: self.isPlaying, duration: self.audioManager.duration)
            }
            .store(in: &cancellables)

        audioManager.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] playing in
                guard let self else { return }
                self.nowPlaying.update(elapsed: self.audioManager.currentTime, isPlaying: playing, duration: self.audioManager.duration)
            }
            .store(in: &cancellables)

        speechManager.$transcript
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                guard let self else { return }
                guard self.drivingModeEnabled else { return }
                guard self.drivingPromptState == .listening else { return }
                self.answerText = text
                self.transcriptUpdateDate = Date()
            }
            .store(in: &cancellables)
    }

    func bind(pointsStore: PointsStore) {
        self.pointsStore = pointsStore
    }

    func updateEpisode(_ updated: Episode) {
        cancelDrivingFlow()
        episode = updated
        audioManager.load(url: updated.audioURL)
        nowPlaying.configure(title: updated.title, duration: 0)
        PlayerDurationCache.shared.duration = 0
        promptedIDs.removeAll()
        showPrompt = false
        activePrompt = nil
    }

    func togglePlay() {
        if audioManager.isPlaying {
            audioManager.pause()
        } else {
            audioManager.play()
        }
    }

    func skip(by seconds: Double) {
        let duration = max(audioManager.duration, 0)
        let current = max(audioManager.currentTime, 0)
        let target = min(max(current + seconds, 0), duration)
        audioManager.seek(to: target)
    }

    func checkForPrompt(at time: Double) {
        guard interactiveModeEnabled else { return }
        guard !showPrompt else { return }

        if let nextPrompt = episode.prompts.first(where: { ($0.timestampSeconds - $0.leadTimeSeconds) <= time && !promptedIDs.contains($0.id) }) {
            promptedIDs.insert(nextPrompt.id)
            activePrompt = nextPrompt
            showPrompt = true
            audioManager.pause()
            answerText = ""
            feedbackText = ""
            lastScore = 0
            lastGrade = .f
            lastAwardedPoints = 0
            if drivingModeEnabled {
                beginDrivingFlow(for: nextPrompt)
            } else {
                drivingPromptState = .idle
                drivingStatusText = ""
            }
        }
    }

    func submitAnswer(pointsStore: PointsStore) async {
        guard let prompt = activePrompt else { return }
        guard !answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isEvaluating else { return }

        isEvaluating = true
        if drivingModeEnabled {
            drivingPromptState = .submitting
            drivingStatusText = "Grading your answer..."
        }
        defer { isEvaluating = false }

        let result = await aiService.evaluateAnswer(
            question: prompt.question,
            expectedAnswer: prompt.expectedAnswer,
            userAnswer: answerText,
            transcript: episode.transcript,
            progressSeconds: audioManager.currentTime
        )

        lastScore = result.score
        lastGrade = result.grade
        lastAwardedPoints = result.awardedPoints
        feedbackText = result.feedback
        promptResults.append(
            PromptResult(
                prompt: prompt,
                answer: answerText,
                score: result.score,
                grade: result.grade,
                awardedPoints: result.awardedPoints,
                feedback: result.feedback
            )
        )

        if result.awardedPoints > 0 {
            pointsStore.add(points: result.awardedPoints)
        }
        if drivingModeEnabled {
            drivingPromptState = .speakingFeedback
            drivingStatusText = "Reading feedback..."
            speak(text: result.feedback)
        }
    }

    func continuePlayback() {
        cancelDrivingFlow()
        showPrompt = false
        activePrompt = nil
        audioManager.play()
    }

    func toggleRecording() {
        if speechManager.isRecording {
            speechManager.stopRecording()
        } else {
            speechManager.startRecording()
        }
    }

    func drivingMicTapped() {
        if speechManager.isRecording {
            Task { await stopListeningAndSubmitIfPossible() }
        } else {
            startListening()
        }
    }

    private func beginDrivingFlow(for prompt: Prompt) {
        cancelDrivingFlow()
        drivingPromptState = .announcingPrompt
        drivingStatusText = "Reading prompt..."
        speak(text: prompt.question)
    }

    private func startListening() {
        guard drivingModeEnabled else { return }
        guard showPrompt else { return }
        guard activePrompt != nil else { return }

        speechSynthesizer.stopSpeaking(at: .immediate)
        answerText = ""
        transcriptUpdateDate = Date()
        listeningStartDate = Date()
        drivingPromptState = .listening
        drivingStatusText = "Listening..."
        speechManager.startRecording()
        startSilenceWatch()
    }

    private func startSilenceWatch() {
        silenceWatchTask?.cancel()
        silenceWatchTask = Task { @MainActor in
            while !Task.isCancelled && drivingPromptState == .listening && showPrompt {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard speechManager.isRecording else { continue }
                let transcript = speechManager.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !transcript.isEmpty else { continue }
                let silence = Date().timeIntervalSince(transcriptUpdateDate)
                let listenTime = Date().timeIntervalSince(listeningStartDate)
                if silence >= 1.8 && listenTime >= 2.0 {
                    await stopListeningAndSubmitIfPossible()
                    return
                }
            }
        }
    }

    private func stopListeningAndSubmitIfPossible() async {
        speechManager.stopRecording()
        silenceWatchTask?.cancel()
        let transcript = speechManager.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            drivingPromptState = .idle
            drivingStatusText = "No speech captured. Tap mic to try again."
            return
        }
        answerText = transcript
        guard let pointsStore else {
            drivingPromptState = .idle
            drivingStatusText = "Unable to grade right now."
            return
        }
        await submitAnswer(pointsStore: pointsStore)
    }

    private func cancelDrivingFlow() {
        silenceWatchTask?.cancel()
        silenceWatchTask = nil
        if speechManager.isRecording {
            speechManager.stopRecording()
        }
        speechSynthesizer.stopSpeaking(at: .immediate)
        drivingPromptState = .idle
        drivingStatusText = ""
    }

    private func speak(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {}
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.49
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.1
        speechSynthesizer.speak(utterance)
    }
}

extension PlayerViewModel: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard drivingModeEnabled else { return }
            switch drivingPromptState {
            case .announcingPrompt:
                startListening()
            case .speakingFeedback:
                continuePlayback()
            default:
                break
            }
        }
    }
}
