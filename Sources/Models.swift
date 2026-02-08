import Foundation

struct Episode: Identifiable, Codable {
    let id: UUID
    let title: String
    let audioURL: URL
    let prompts: [Prompt]
    let feedURL: URL?
    let episodeGUID: String?
    let transcript: String?

    init(id: UUID, title: String, audioURL: URL, prompts: [Prompt], feedURL: URL? = nil, episodeGUID: String? = nil, transcript: String? = nil) {
        self.id = id
        self.title = title
        self.audioURL = audioURL
        self.prompts = prompts
        self.feedURL = feedURL
        self.episodeGUID = episodeGUID
        self.transcript = transcript
    }

    private enum CodingKeys: String, CodingKey { case id, title, audioURL, prompts, feedURL, episodeGUID, transcript }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        audioURL = try container.decode(URL.self, forKey: .audioURL)
        prompts = try container.decode([Prompt].self, forKey: .prompts)
        feedURL = try container.decodeIfPresent(URL.self, forKey: .feedURL)
        episodeGUID = try container.decodeIfPresent(String.self, forKey: .episodeGUID)
        transcript = try container.decodeIfPresent(String.self, forKey: .transcript)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(audioURL, forKey: .audioURL)
        try container.encode(prompts, forKey: .prompts)
        try container.encodeIfPresent(feedURL, forKey: .feedURL)
        try container.encodeIfPresent(episodeGUID, forKey: .episodeGUID)
        try container.encodeIfPresent(transcript, forKey: .transcript)
    }
}

struct Prompt: Identifiable, Codable {
    let id: UUID
    let timestampSeconds: Double
    let question: String
    let expectedAnswer: String
    let leadTimeSeconds: Double

    init(id: UUID, timestampSeconds: Double, question: String, expectedAnswer: String, leadTimeSeconds: Double = 0) {
        self.id = id
        self.timestampSeconds = timestampSeconds
        self.question = question
        self.expectedAnswer = expectedAnswer
        self.leadTimeSeconds = leadTimeSeconds
    }

    enum CodingKeys: String, CodingKey {
        case id
        case timestampSeconds
        case question
        case expectedAnswer
        case leadTimeSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestampSeconds = try container.decode(Double.self, forKey: .timestampSeconds)
        question = try container.decode(String.self, forKey: .question)
        expectedAnswer = try container.decode(String.self, forKey: .expectedAnswer)
        leadTimeSeconds = try container.decodeIfPresent(Double.self, forKey: .leadTimeSeconds) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestampSeconds, forKey: .timestampSeconds)
        try container.encode(question, forKey: .question)
        try container.encode(expectedAnswer, forKey: .expectedAnswer)
        try container.encode(leadTimeSeconds, forKey: .leadTimeSeconds)
    }
}

struct PromptResult: Identifiable {
    let id = UUID()
    let prompt: Prompt
    let answer: String
    let score: Int
    let feedback: String
}
