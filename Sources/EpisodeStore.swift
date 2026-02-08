import Foundation

@MainActor
final class EpisodeStore: ObservableObject {
    @Published var episode: Episode

    private let storageKey = "TheAgoraLA.Episode.Data"

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(Episode.self, from: data) {
            episode = saved
        } else {
            episode = MockEpisodeProvider.sample
        }
    }

    func updateEpisode(_ updated: Episode) {
        episode = updated
        persist()
    }

    func addPrompt(_ prompt: Prompt) {
        episode = Episode(
            id: episode.id,
            title: episode.title,
            audioURL: episode.audioURL,
            prompts: episode.prompts + [prompt],
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: episode.transcript
        )
        persist()
    }

    func updatePrompt(_ prompt: Prompt) {
        let updatedPrompts = episode.prompts.map { existing in
            existing.id == prompt.id ? prompt : existing
        }
        episode = Episode(
            id: episode.id,
            title: episode.title,
            audioURL: episode.audioURL,
            prompts: updatedPrompts,
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: episode.transcript
        )
        persist()
    }

    func deletePrompt(_ prompt: Prompt) {
        let updatedPrompts = episode.prompts.filter { $0.id != prompt.id }
        episode = Episode(
            id: episode.id,
            title: episode.title,
            audioURL: episode.audioURL,
            prompts: updatedPrompts,
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: episode.transcript
        )
        persist()
    }

    func updateAudioURL(_ url: URL) {
        episode = Episode(
            id: episode.id,
            title: episode.title,
            audioURL: url,
            prompts: episode.prompts,
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: episode.transcript
        )
        persist()
    }

    func updateTitle(_ title: String) {
        episode = Episode(
            id: episode.id,
            title: title,
            audioURL: episode.audioURL,
            prompts: episode.prompts,
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: episode.transcript
        )
        persist()
    }
    
    func updateTranscript(_ transcript: String?) {
        episode = Episode(
            id: episode.id,
            title: episode.title,
            audioURL: episode.audioURL,
            prompts: episode.prompts,
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: transcript
        )
        persist()
    }
    
    func updateTitleAndTranscript(title: String, transcript: String?) {
        episode = Episode(
            id: episode.id,
            title: title,
            audioURL: episode.audioURL,
            prompts: episode.prompts,
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: transcript
        )
        persist()
    }
    
    func replacePrompts(_ newPrompts: [Prompt]) {
        episode = Episode(
            id: episode.id,
            title: episode.title,
            audioURL: episode.audioURL,
            prompts: newPrompts,
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: episode.transcript
        )
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(episode) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

