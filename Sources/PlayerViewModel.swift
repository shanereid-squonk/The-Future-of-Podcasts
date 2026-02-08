import Foundation
import Combine

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var episode: Episode = MockEpisodeProvider.sample
    @Published var activePrompt: Prompt?
    @Published var showPrompt = false
    @Published var answerText = ""
    @Published var feedbackText = ""
    @Published var lastScore: Int = 0
    @Published var isEvaluating = false
    @Published var interactiveModeEnabled = true
    @Published var promptResults: [PromptResult] = []
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    let audioManager = AudioPlayerManager()
    let speechManager = SpeechRecognitionManager()
    let aiService = AIService()
    private var cancellables = Set<AnyCancellable>()

    private var promptedIDs = Set<UUID>()
    private let nowPlaying = NowPlayingManager.shared

    init() {
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
    }

    func updateEpisode(_ updated: Episode) {
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
        }
    }

    func submitAnswer(pointsStore: PointsStore) async {
        guard let prompt = activePrompt else { return }
        guard !answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isEvaluating = true
        let result = await aiService.evaluateAnswer(
            question: prompt.question,
            expectedAnswer: prompt.expectedAnswer,
            userAnswer: answerText,
            transcript: episode.transcript,
            progressSeconds: audioManager.currentTime
        )

        lastScore = result.score
        feedbackText = result.feedback
        promptResults.append(
            PromptResult(prompt: prompt, answer: answerText, score: result.score, feedback: result.feedback)
        )

        if result.awardedPoints > 0 {
            pointsStore.add(points: result.awardedPoints)
        }

        isEvaluating = false
    }

    func continuePlayback() {
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
}

