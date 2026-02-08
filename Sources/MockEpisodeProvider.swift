import Foundation

enum MockEpisodeProvider {
    static let sample = Episode(
        id: UUID(),
        title: "Keynote: The Agora and the Future of Community",
        audioURL: URL(string: "https://example.com/episode.mp3")!,
        prompts: [
            Prompt(
                id: UUID(),
                timestampSeconds: 30,
                question: "Quick check: What is the speaker's main claim so far?",
                expectedAnswer: "The keynote argues that community is built through shared rituals, not just shared platforms.",
                leadTimeSeconds: 0
            ),
            Prompt(
                id: UUID(),
                timestampSeconds: 120,
                question: "What is the strongest example the speaker uses to support the claim?",
                expectedAnswer: "They point to the Agora model where in-person exchanges created accountability and trust.",
                leadTimeSeconds: 0
            ),
            Prompt(
                id: UUID(),
                timestampSeconds: 240,
                question: "What is the call to action for listeners?",
                expectedAnswer: "Design spaces that reward contribution and make participation visible.",
                leadTimeSeconds: 0
            )
        ]
    )
}
