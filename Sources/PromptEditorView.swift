import SwiftUI
import Foundation
import AVFoundation

struct PromptEditorView: View {
    @ObservedObject var episodeStore: EpisodeStore
    @Environment(\.dismiss) private var dismiss
    @State private var newQuestion = ""
    @State private var newAnswer = ""
    @State private var newTimestamp = ""
    @State private var newLeadTime = 0.0
    @State private var audioURLText = ""
    @State private var titleText = ""
    @State private var transcriptText = ""
    @State private var showInvalidURL = false
    @State private var isResolving = false
    @State private var isAnalyzingPrompts = false
    @State private var transcriptExpanded = false
    @State private var selectedPromptCount = 3
    @State private var showAdditionalPromptsStack = false

    var body: some View {
        let visiblePrompts = Array(episodeStore.episode.prompts.prefix(3))
        let additionalPrompts = Array(episodeStore.episode.prompts.dropFirst(3))

        VStack(spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Episode Setup")
                        .font(AgoraTheme.cardTitleFont)
                        .foregroundColor(AgoraTheme.ink)

                    Text("Update your audio source and prompts below.")
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                }
                Spacer()
                AgoraTag(text: "Editor")
            }

            AgoraCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Episode Title")
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                    TextField("Enter title", text: $titleText)
                        .agoraFieldStyle()

                    Text("Audio URL (MP3)")
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                    TextField("https://...", text: $audioURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .agoraFieldStyle()
                        .overlay(alignment: .trailing) {
                            if !audioURLText.isEmpty {
                                Button {
                                    audioURLText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(AgoraTheme.inkMuted)
                                        .padding(.trailing, 10)
                                }
                                .accessibilityLabel("Clear URL")
                            }
                        }

                    Text("Episode Transcript (optional)")
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                    if transcriptExpanded {
                        TextEditor(text: $transcriptText)
                            .frame(minHeight: 200)
                            .padding(10)
                            .background(Color.white.opacity(0.85))
                            .cornerRadius(14)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(AgoraTheme.cardStroke, lineWidth: 1)
                            )
                        HStack {
                            Spacer()
                            Button("Show less") { transcriptExpanded = false }
                                .buttonStyle(AgoraOutlineButtonStyle())
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            if transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("No transcript yet")
                                    .font(AgoraTheme.tagFont)
                                    .foregroundColor(AgoraTheme.inkMuted)
                            } else {
                                Text(transcriptText)
                                    .font(AgoraTheme.bodyFont)
                                    .foregroundColor(AgoraTheme.ink)
                                    .lineLimit(4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            HStack {
                                Spacer()
                                Button("Show more") { transcriptExpanded = true }
                                    .buttonStyle(AgoraOutlineButtonStyle())
                            }
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.85))
                        .cornerRadius(14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(AgoraTheme.cardStroke, lineWidth: 1)
                        )
                    }

                    Button("Save Episode Details") {
                        saveEpisodeDetails()
                    }
                    .buttonStyle(AgoraPillButtonStyle())
                    .disabled(isResolving)

                    if isResolving {
                        ProgressView("Resolving Apple Podcasts link...")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Button("Analyze Podcast & Generate Prompts") {
                    isAnalyzingPrompts = true
                    Task {
                        defer { Task { await MainActor.run { isAnalyzingPrompts = false } } }

                        // 1) Ensure the episode reflects the current URL field
                        let input = audioURLText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if input.lowercased().hasPrefix("https://") {
                            if let url = URL(string: input), url.host?.contains("podcasts.apple.com") == true {
                                // Resolve Apple Podcasts link and fetch metadata
                                do {
                                    let resolved = try await PodcastLinkResolver().resolve(from: url)
                                    let metadata = try? await TranscriptFetcher().fetchMetadata(appleURL: url)

                                    if let rawTitle = metadata?.title, !rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        await MainActor.run { titleText = rawTitle }
                                        episodeStore.updateTitle(rawTitle)
                                    }
                                    episodeStore.updateAudioURL(resolved)
                                    await MainActor.run { audioURLText = resolved.absoluteString }

                                    if let t = metadata?.transcript, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        await MainActor.run { transcriptText = t }
                                        episodeStore.updateTranscript(t)
                                    } else {
                                        episodeStore.updateTranscript(transcriptText.isEmpty ? nil : transcriptText)
                                    }
                                } catch {
                                    // If resolution fails, keep existing episode URL
                                }
                            } else if let direct = URL(string: input) {
                                // Direct media URL: adopt it immediately
                                episodeStore.updateAudioURL(direct)
                                episodeStore.updateTranscript(transcriptText.isEmpty ? nil : transcriptText)
                            }
                        }

                        // 2) Measure real media duration first, then fall back to player cache.
                        var duration = await measureAudioDurationSeconds(from: episodeStore.episode.audioURL)
                        if let measured = duration {
                            await MainActor.run { PlayerDurationCache.shared.duration = measured }
                        } else {
                            let durationDeadline = Date().addingTimeInterval(20)
                            var cached = await PlayerDurationProvider.shared.currentDuration
                            while cached < 10 && Date() < durationDeadline {
                                try? await Task.sleep(nanoseconds: 300_000_000)
                                cached = await PlayerDurationProvider.shared.currentDuration
                            }
                            if cached > 10 {
                                duration = cached
                            }
                        }
                        var effectiveDuration = duration

                        // 3) Wait for transcript
                        let transcriptDeadline = Date().addingTimeInterval(20)
                        var text = episodeStore.episode.transcript ?? transcriptText
                        while text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Date() < transcriptDeadline {
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            text = episodeStore.episode.transcript ?? transcriptText
                        }

                        // Require transcript for content-aware prompt placement
                        let trimmedTranscript = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedTranscript.isEmpty else { return }

                        if effectiveDuration == nil || !(effectiveDuration!.isFinite) || effectiveDuration! <= 10 {
                            effectiveDuration = estimateDurationFromTranscript(trimmedTranscript)
                        }
                        guard let effectiveDuration, effectiveDuration > 10 else { return }

                        // 4) Generate transcript-aware prompts from the dedicated AI worker.
                        let requestedCount = max(3, min(9, selectedPromptCount))
                        let generated = await generatePrompts(
                            transcript: trimmedTranscript,
                            audioDuration: effectiveDuration,
                            requestedCount: requestedCount
                        )
                        guard !generated.isEmpty else { return }
                        await MainActor.run { episodeStore.replacePrompts(generated) }
                    }
                }
                .buttonStyle(AgoraPillButtonStyle())
                .disabled(isResolving || isAnalyzingPrompts)

                Menu {
                    ForEach(3...9, id: \.self) { count in
                        Button("\(count) prompts") {
                            selectedPromptCount = count
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("Prompt Count")
                        Text("\(selectedPromptCount)")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(AgoraOutlineButtonStyle())
                .disabled(isAnalyzingPrompts)

                if isAnalyzingPrompts {
                    ProgressView("Analyzing podcast to generate \(selectedPromptCount) prompts...")
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                }
            }

            Text("Prompts")
                .font(AgoraTheme.cardTitleFont)
                .foregroundColor(AgoraTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(Array(visiblePrompts.enumerated()), id: \.element.id) { index, prompt in
                PromptRow(index: index, prompt: prompt, episodeDuration: promptEditorDurationSeconds) {
                    episodeStore.deletePrompt(prompt)
                } onUpdate: { updated in
                    episodeStore.updatePrompt(updated)
                }
            }

            if !additionalPrompts.isEmpty {
                Button(showAdditionalPromptsStack ? "Hide additional prompts" : "See additional prompts generated") {
                    showAdditionalPromptsStack.toggle()
                }
                .buttonStyle(AgoraOutlineButtonStyle())
            }

            if showAdditionalPromptsStack, !additionalPrompts.isEmpty {
                AdditionalPromptsCarousel(
                    prompts: additionalPrompts,
                    startIndex: visiblePrompts.count,
                    episodeDuration: promptEditorDurationSeconds
                ) { prompt in
                    episodeStore.deletePrompt(prompt)
                } onUpdate: { updated in
                    episodeStore.updatePrompt(updated)
                }
                .frame(height: 640)
            }

            AgoraCard {
                VStack(spacing: 10) {
                    Text("Add New Prompt")
                        .font(AgoraTheme.cardTitleFont)
                        .foregroundColor(AgoraTheme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    TextField("Timestamp (seconds)", text: $newTimestamp)
                        .keyboardType(.decimalPad)
                        .agoraFieldStyle()

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Lead Time: \(Int(newLeadTime))s before prompt")
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)
                            Spacer()
                            Menu {
                                ForEach([0, 5, 10, 15, 20, 30], id: \.self) { step in
                                    Button("\(step)s") { newLeadTime = Double(step) }
                                }
                            } label: {
                                Text("Quick Select")
                            }
                            .buttonStyle(AgoraOutlineButtonStyle())
                        }
                        Slider(value: $newLeadTime, in: 0...60, step: 5)
                    }
                    .padding(.top, 4)

                    TextField("Question", text: $newQuestion)
                        .agoraFieldStyle()

                    TextField("Expected answer", text: $newAnswer)
                        .agoraFieldStyle()

                    Button("Add Prompt") {
                        addPrompt()
                    }
                    .buttonStyle(AgoraPillButtonStyle())
                }
            }
        }
        .padding(16)
        .onAppear {
            audioURLText = episodeStore.episode.audioURL.absoluteString
            titleText = episodeStore.episode.title
            transcriptText = episodeStore.episode.transcript ?? ""
        }
        .alert("Invalid URL", isPresented: $showInvalidURL) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please enter a valid URL that starts with https://")
        }
    }

    private func generatePrompts(transcript: String, audioDuration: Double, requestedCount: Int) async -> [Prompt] {
        let boundedCount = max(3, min(9, requestedCount))
        let primaryService = AIService()
        let generated = await primaryService.generatePrompts(
            transcript: transcript,
            audioDuration: audioDuration,
            desiredCount: boundedCount
        )
        return Array(generated.sorted { $0.timestampSeconds < $1.timestampSeconds }.prefix(boundedCount))
    }

    private func paddedPromptSet(from prompts: [Prompt], transcript: String, audioDuration: Double, targetCount: Int) -> [Prompt] {
        var result = prompts
        let duration = max(audioDuration, 60)
        let startPad = min(45, max(8, duration * 0.08))
        let endPad = min(30, max(6, duration * 0.06))
        let usableStart = min(startPad, duration)
        let usableEnd = max(usableStart, duration - endPad)
        let span = max(usableEnd - usableStart, 1)

        let sentences = transcript
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var usedQuestionKeys = Set(result.map { normalizedPromptKey($0.question) })
        var usedAnswerKeys = Set(result.map { normalizedPromptKey($0.expectedAnswer) })

        while result.count < targetCount {
            let slot = result.count
            let ratio = Double(slot + 1) / Double(targetCount + 1)
            let timestamp = usableStart + (ratio * span)

            let sentenceIndex = min(Int(round(ratio * Double(max(sentences.count - 1, 0)))), max(sentences.count - 1, 0))
            let answerSeed: String = sentences.isEmpty
                ? "In this segment, the speaker presents a concrete argument with implications for the broader discussion."
                : sentences[sentenceIndex]

            let answer = answerSeed.hasSuffix(".") ? answerSeed : (answerSeed + ".")
            let question = fallbackQuestion(
                for: answer,
                slot: slot,
                totalSlots: targetCount,
                usedQuestionKeys: &usedQuestionKeys
            )

            let aKey = normalizedPromptKey(answer)
            if usedAnswerKeys.contains(aKey) {
                let fallbackAnswer = "\(answer) Segment \(slot + 1)."
                let fallbackQuestion = fallbackQuestion(
                    for: fallbackAnswer,
                    slot: slot,
                    totalSlots: targetCount,
                    usedQuestionKeys: &usedQuestionKeys
                )
                result.append(
                    Prompt(
                        id: UUID(),
                        timestampSeconds: timestamp,
                        question: fallbackQuestion,
                        expectedAnswer: fallbackAnswer,
                        leadTimeSeconds: 0
                    )
                )
                usedQuestionKeys.insert(normalizedPromptKey(fallbackQuestion))
                usedAnswerKeys.insert(normalizedPromptKey(fallbackAnswer))
                continue
            }

            result.append(
                Prompt(
                    id: UUID(),
                    timestampSeconds: timestamp,
                    question: question,
                    expectedAnswer: answer,
                    leadTimeSeconds: 0
                )
            )
            usedAnswerKeys.insert(aKey)
        }

        return result
    }

    private func fallbackQuestion(
        for answer: String,
        slot: Int,
        totalSlots: Int,
        usedQuestionKeys: inout Set<String>
    ) -> String {
        let anchor = fallbackAnchor(from: answer)
        let secondary = fallbackSecondaryTopic(from: answer, excluding: anchor)
        let detail = fallbackDetail(from: answer)

        var candidates: [String] = []
        if slot <= 0 {
            candidates = [
                "What assumption is doing the most work in this part of the episode's claim about \(anchor)?",
                "Why does the speaker open this stretch by emphasizing \(anchor)?",
                "Which detail here gives the argument about \(anchor) its initial force?"
            ]
        } else if slot >= totalSlots - 1 {
            candidates = [
                "If the claim about \(anchor) holds, what should listeners change after hearing this section?",
                "What consequence tied to \(anchor) does this closing segment make hardest to ignore?",
                "What unresolved issue about \(anchor) remains after this point?"
            ]
        } else {
            candidates = [
                "What tension around \(anchor) is this section exposing, and how is it addressed?",
                "Which evidence in this segment most strengthens or weakens the claim about \(anchor)?",
                "How does this part connect \(anchor) to the episode's broader point about \(secondary)?"
            ]
        }

        if let detail {
            candidates.append("How should listeners interpret the detail \"\(detail)\" before accepting the argument about \(anchor)?")
        }
        candidates.append("What reason in this section most strongly supports the claim about \(anchor), and what still needs proof?")

        for candidate in candidates {
            let cleaned = normalizedQuestion(candidate)
            let key = normalizedPromptKey(cleaned)
            if usedQuestionKeys.insert(key).inserted {
                return cleaned
            }
        }

        let fallback = normalizedQuestion("Which part of the argument about \(anchor) should listeners test most carefully?")
        usedQuestionKeys.insert(normalizedPromptKey(fallback))
        return fallback
    }

    private func fallbackAnchor(from text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "this claim" }

        let seed = cleaned.components(separatedBy: CharacterSet(charactersIn: ".!?")).first ?? cleaned
        var words = seed.split(separator: " ").map {
            $0.trimmingCharacters(in: .punctuationCharacters)
        }.filter { !$0.isEmpty }
        let stop = Set([
            "the", "a", "an", "this", "that", "these", "those", "and", "but", "or",
            "so", "then", "because", "however", "well", "also"
        ])
        while let first = words.first, stop.contains(first.lowercased()), words.count > 2 {
            words.removeFirst()
        }
        while let last = words.last, stop.contains(last.lowercased()), words.count > 2 {
            words.removeLast()
        }
        let phrase = words.prefix(7).joined(separator: " ")
        return phrase.isEmpty ? "this claim" : phrase
    }

    private func fallbackSecondaryTopic(from text: String, excluding anchor: String) -> String {
        let anchorKey = normalizedPromptKey(anchor)
        let words = text.lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline || $0.isPunctuation })
            .map(String.init)
        let stop = Set([
            "about", "after", "again", "because", "episode", "podcast", "segment",
            "section", "speaker", "there", "their", "these", "those", "this", "that",
            "what", "when", "where", "which", "while", "with", "would"
        ])
        for word in words where word.count >= 5 && !stop.contains(word) {
            let key = normalizedPromptKey(word)
            if !key.isEmpty && !anchorKey.contains(key) {
                return word
            }
        }
        return "the broader argument"
    }

    private func fallbackDetail(from text: String) -> String? {
        if let quotedRange = text.range(of: "\"([^\"]{4,80})\"", options: .regularExpression) {
            let detail = String(text[quotedRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !detail.isEmpty { return detail }
        }
        if let numericRange = text.range(
            of: "\\b(?:[A-Za-z]+\\s+){0,2}\\d+(?:\\.\\d+)?%?(?:\\s+[A-Za-z]+){0,3}\\b",
            options: .regularExpression
        ) {
            let detail = String(text[numericRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !detail.isEmpty { return detail }
        }
        return nil
    }

    private func normalizedQuestion(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.prefix(1).uppercased() + cleaned.dropFirst()
        if !cleaned.hasSuffix("?") {
            cleaned.append("?")
        }
        return cleaned
    }

    private func normalizedPromptKey(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveEpisodeDetails() {
        let input = audioURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.lowercased().hasPrefix("https://") else {
            showInvalidURL = true
            return
        }

        // Handle Apple Podcasts shared links by resolving to a direct media URL
        if let url = URL(string: input), url.host?.contains("podcasts.apple.com") == true {
            isResolving = true
            Task { @MainActor in
                defer { isResolving = false }
                do {
                    let resolved = try await PodcastLinkResolver().resolve(from: url)
                    // Update the store immediately so the player reloads
                    episodeStore.updateAudioURL(resolved)
                    audioURLText = resolved.absoluteString

                    // Try to fetch episode title (and transcript) from the Apple Podcasts link (in parallel)
                    let metadata = try? await TranscriptFetcher().fetchMetadata(appleURL: url)
                    if let rawTitle = metadata?.title {
                        let fetchedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !fetchedTitle.isEmpty {
                            titleText = fetchedTitle
                            episodeStore.updateTitle(fetchedTitle)
                        }
                    }
                    if let t = metadata?.transcript, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        transcriptText = t
                        episodeStore.updateTranscript(t)
                    } else {
                        episodeStore.updateTranscript(transcriptText.isEmpty ? nil : transcriptText)
                    }

                    // Wait briefly for the player to prepare (duration reported)
                    await waitForPlayerPreparation(timeoutSeconds: 5)

                    // Background auto-fetch transcript if still missing
                    Task {
                        if episodeStore.episode.transcript == nil || (episodeStore.episode.transcript?.isEmpty == true) {
                            if let transcript = try? await TranscriptFetcher().fetch(appleURL: url) {
                                episodeStore.updateTranscript(transcript)
                                await MainActor.run { transcriptText = transcript }
                            }
                        }
                    }
                } catch {
                    showInvalidURL = true
                }
            }
            return
        }

        // Otherwise treat as a direct URL (AVPlayer can handle redirects and various audio formats)
        guard let url = URL(string: input) else {
            showInvalidURL = true
            return
        }

        Task { @MainActor in
            episodeStore.updateTitle(titleText.isEmpty ? "Untitled Episode" : titleText)
            episodeStore.updateAudioURL(url)
            episodeStore.updateTranscript(transcriptText.isEmpty ? nil : transcriptText)

            // Wait briefly for the player to prepare (duration reported)
            await waitForPlayerPreparation(timeoutSeconds: 5)
        }
    }

    @MainActor
    private func waitForPlayerPreparation(timeoutSeconds: Double) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if PlayerDurationCache.shared.duration > 0 {
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func measureAudioDurationSeconds(from url: URL) async -> Double? {
        await withTaskGroup(of: Double?.self, returning: Double?.self) { group in
            group.addTask {
                let asset = AVURLAsset(url: url)
                do {
                    let duration = try await asset.load(.duration)
                    let seconds = duration.seconds
                    guard seconds.isFinite, seconds > 10 else { return nil }
                    return seconds
                } catch {
                    return nil
                }
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                return nil
            }

            let measured = await group.next() ?? nil
            group.cancelAll()
            return measured
        }
    }

    private func estimateDurationFromTranscript(_ transcript: String) -> Double {
        let words = transcript.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        if words == 0 { return 0 }
        // 2.6 words/sec ~= 156 wpm typical spoken pace.
        let estimated = Double(words) / 2.6
        return max(180, min(86_400, estimated))
    }

    private func addPrompt() {
        guard let timestamp = Double(newTimestamp) else { return }
        guard !newQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !newAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let prompt = Prompt(
            id: UUID(),
            timestampSeconds: timestamp,
            question: newQuestion,
            expectedAnswer: newAnswer,
            leadTimeSeconds: newLeadTime
        )

        episodeStore.addPrompt(prompt)
        newTimestamp = ""
        newQuestion = ""
        newAnswer = ""
        newLeadTime = 0
    }

    private var promptEditorDurationSeconds: Double {
        let maxPrompt = episodeStore.episode.prompts.map(\.timestampSeconds).max() ?? 0
        return max(PlayerDurationCache.shared.duration, maxPrompt + 60, 600)
    }
}

private struct PromptRow: View {
    let index: Int
    let prompt: Prompt
    let episodeDuration: Double
    let onDelete: () -> Void
    let onUpdate: (Prompt) -> Void

    @State private var question: String
    @State private var expectedAnswer: String
    @State private var timestampSeconds: Double
    @State private var leadTimeSeconds: Double
    @State private var showFullQuestion = false
    @State private var showFullAnswer = false

    init(index: Int, prompt: Prompt, episodeDuration: Double, onDelete: @escaping () -> Void, onUpdate: @escaping (Prompt) -> Void) {
        self.index = index
        self.prompt = prompt
        self.episodeDuration = episodeDuration
        self.onDelete = onDelete
        self.onUpdate = onUpdate
        _question = State(initialValue: prompt.question)
        _expectedAnswer = State(initialValue: prompt.expectedAnswer)
        _timestampSeconds = State(initialValue: prompt.timestampSeconds)
        _leadTimeSeconds = State(initialValue: prompt.leadTimeSeconds)
    }

    var body: some View {
        AgoraCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Time: \(formatSeconds(timestampSeconds))")
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.inkMuted)

                    Spacer()

                    AgoraTag(text: positionLabel)

                    Button("Delete") {
                        onDelete()
                    }
                    .buttonStyle(AgoraOutlineButtonStyle())
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Select time")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                        Spacer()
                        Menu {
                            ForEach(quickSelectTimestamps, id: \.self) { value in
                                Button("\(formatSeconds(value))") { timestampSeconds = value }
                            }
                        } label: {
                            Text("Quick Select")
                        }
                        .buttonStyle(AgoraOutlineButtonStyle())
                    }
                    Slider(value: $timestampSeconds, in: timestampRange, step: timestampStep)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Lead Time: \(Int(leadTimeSeconds))s before prompt")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                        Spacer()
                        Menu {
                            ForEach([0, 5, 10, 15, 20, 30], id: \.self) { step in
                                Button("\(step)s") { leadTimeSeconds = Double(step) }
                            }
                        } label: {
                            Text("Quick Select")
                        }
                        .buttonStyle(AgoraOutlineButtonStyle())
                    }
                    Slider(value: $leadTimeSeconds, in: 0...60, step: 5)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Question")
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.inkMuted)

                    if showFullQuestion {
                        TextEditor(text: $question)
                            .frame(height: 130)
                            .agoraFieldStyle()
                    } else {
                        TextField("Question", text: $question)
                            .agoraFieldStyle()
                    }

                    HStack {
                        Spacer()
                        Button(showFullQuestion ? "Show less" : "Show more") {
                            showFullQuestion.toggle()
                        }
                        .buttonStyle(AgoraOutlineButtonStyle())
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Expected Answer")
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.inkMuted)

                    if showFullAnswer {
                        TextEditor(text: $expectedAnswer)
                            .frame(height: 130)
                            .agoraFieldStyle()
                    } else {
                        TextField("Expected answer", text: $expectedAnswer)
                            .agoraFieldStyle()
                    }

                    HStack {
                        Spacer()
                        Button(showFullAnswer ? "Show less" : "Show more") {
                            showFullAnswer.toggle()
                        }
                        .buttonStyle(AgoraOutlineButtonStyle())
                    }
                }

                Button("Save Prompt") {
                    let updated = Prompt(
                        id: prompt.id,
                        timestampSeconds: timestampSeconds,
                        question: question,
                        expectedAnswer: expectedAnswer,
                        leadTimeSeconds: leadTimeSeconds
                    )
                    onUpdate(updated)
                }
                .buttonStyle(AgoraPillButtonStyle())
            }
        }
    }

    private var positionLabel: String {
        switch index {
        case 0: return "Beginning"
        case 1: return "Middle"
        case 2: return "Late"
        default: return "Custom"
        }
    }

    private var timestampRange: ClosedRange<Double> {
        let duration = max(episodeDuration, 60)
        let startPad = min(45, max(8, duration * 0.08))
        let endPad = min(30, max(6, duration * 0.06))
        let usableStart = min(startPad, duration)
        let usableEnd = max(usableStart, duration - endPad)
        let segment = max((usableEnd - usableStart) / 3, 1)

        let firstEnd = min(usableEnd, usableStart + segment)
        let secondStart = firstEnd
        let secondEnd = min(usableEnd, usableStart + (2 * segment))
        let thirdStart = secondEnd

        switch index {
        case 0: return usableStart...firstEnd
        case 1: return secondStart...secondEnd
        case 2: return thirdStart...usableEnd
        default: return usableStart...usableEnd
        }
    }

    private var timestampStep: Double {
        let duration = max(episodeDuration, 1)
        if duration >= 10_800 { return 60 } // 3h+
        if duration >= 3_600 { return 30 }  // 1h+
        if duration >= 1_200 { return 15 }  // 20m+
        return 5
    }

    private var quickSelectTimestamps: [Double] {
        let r = timestampRange
        let span = r.upperBound - r.lowerBound
        guard span > 1 else { return [r.lowerBound] }
        let step = span / 4
        return (0...4).map { i in
            r.lowerBound + (Double(i) * step)
        }
    }

    private func formatSeconds(_ seconds: Double) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let minutes = (s % 3600) / 60
        let r = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, minutes, r) }
        let shortMinutes = s / 60
        if shortMinutes > 0 { return String(format: "%d:%02d", shortMinutes, r) }
        return "\(s)s"
    }
}

private struct AdditionalPromptsCarousel: View {
    let prompts: [Prompt]
    let startIndex: Int
    let episodeDuration: Double
    let onDelete: (Prompt) -> Void
    let onUpdate: (Prompt) -> Void

    @State private var selection = 0

    var body: some View {
        AgoraCard {
            VStack(spacing: 12) {
                if prompts.isEmpty {
                    Text("No additional prompts available.")
                        .font(AgoraTheme.bodyFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    TabView(selection: $selection) {
                        ForEach(Array(prompts.enumerated()), id: \.element.id) { offset, prompt in
                            PromptRow(
                                index: startIndex + offset,
                                prompt: prompt,
                                episodeDuration: episodeDuration
                            ) {
                                onDelete(prompt)
                            } onUpdate: { updated in
                                onUpdate(updated)
                            }
                            .tag(offset)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 12)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .always))
                    .indexViewStyle(.page(backgroundDisplayMode: .always))
                }
            }
            .padding(10)
        }
    }
}

private extension View {
    func agoraFieldStyle() -> some View {
        self
            .font(AgoraTheme.bodyFont)
            .padding(12)
            .background(Color.white.opacity(0.85))
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(AgoraTheme.cardStroke, lineWidth: 1)
            )
    }
}
private struct PodcastLinkResolver {
    private struct LookupResponse: Decodable { let results: [LookupItem] }
    private struct LookupItem: Decodable {
        let feedUrl: String?
        let trackId: Int?
        let trackName: String?
        let episodeGuid: String?
    }

    enum ResolverError: Error { case unrecognizedLink, feedNotFound, enclosureNotFound }

    func resolve(from appleURL: URL) async throws -> URL {
        guard let showId = extractShowId(from: appleURL) else { throw ResolverError.unrecognizedLink }
        let episodeId = extractEpisodeId(from: appleURL)
        let feedURL = try await fetchFeedURL(showId: showId)
        let episodeMeta = try await fetchEpisodeMeta(showId: showId, episodeId: episodeId)
        return try await findEnclosure(in: feedURL, matchGuid: episodeMeta.guid, matchTitle: episodeMeta.title)
    }

    private func extractShowId(from url: URL) -> String? {
        let full = url.absoluteString
        if let range = full.range(of: "id(\\d+)", options: .regularExpression) {
            let token = String(full[range])
            return String(token.dropFirst(2))
        }
        return nil
    }

    private func extractEpisodeId(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "i" })?
            .value
    }

    private func fetchFeedURL(showId: String) async throws -> URL {
        let endpoint = URL(string: "https://itunes.apple.com/lookup?id=\(showId)")!
        let (data, _) = try await URLSession.shared.data(from: endpoint)
        let lookup = try JSONDecoder().decode(LookupResponse.self, from: data)
        guard let feed = lookup.results.first?.feedUrl, let url = URL(string: feed) else { throw ResolverError.feedNotFound }
        return url
    }

    private func fetchEpisodeMeta(showId: String, episodeId: String?) async throws -> (guid: String?, title: String?) {
        guard let episodeId, let episodeIdInt = Int(episodeId) else { return (nil, nil) }
        let endpoint = URL(string: "https://itunes.apple.com/lookup?id=\(showId)&entity=podcastEpisode&limit=200")!
        let (data, _) = try await URLSession.shared.data(from: endpoint)
        let lookup = try JSONDecoder().decode(LookupResponse.self, from: data)
        if let match = lookup.results.first(where: { $0.trackId == episodeIdInt }) {
            return (match.episodeGuid, match.trackName)
        }
        return (nil, nil)
    }

    private func findEnclosure(in feedURL: URL, matchGuid: String?, matchTitle: String?) async throws -> URL {
        let (data, _) = try await URLSession.shared.data(from: feedURL)
        let items = try Parser().parseItems(data: data)

        // 1) Exact GUID match
        if let guid = matchGuid, let item = items.first(where: { $0.guid == guid }), let url = item.enclosure {
            return url
        }

        // Helper: normalize titles for robust comparisons
        func normalize(_ s: String) -> String {
            let lowered = s.lowercased()
            let stripped = lowered.replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            let squashed = stripped.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            return squashed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func tokens(_ s: String) -> Set<String> { Set(normalize(s).split(separator: " ").map(String.init)) }

        // 2) Title-based matching: exact normalized match, then contains, then best token overlap
        if let raw = matchTitle, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let target = normalize(raw)

            // Exact normalized match
            if let item = items.first(where: { normalize($0.title ?? "") == target }), let url = item.enclosure {
                return url
            }
            // Contains either way
            if let item = items.first(where: {
                let t = normalize($0.title ?? "")
                return t.contains(target) || target.contains(t)
            }), let url = item.enclosure {
                return url
            }
            // Best Jaccard token overlap
            let targetTokens = tokens(target)
            let ranked = items.compactMap { it -> (item: Parser.Item, score: Double)? in
                let t = normalize(it.title ?? "")
                guard !t.isEmpty else { return nil }
                let toks = tokens(t)
                if toks.isEmpty { return nil }
                let inter = toks.intersection(targetTokens).count
                let union = toks.union(targetTokens).count
                let score = union > 0 ? Double(inter) / Double(union) : 0
                return (it, score)
            }.sorted(by: { $0.score > $1.score })

            if let best = ranked.first, best.score >= 0.6, let url = best.item.enclosure {
                return url
            }
        }

        // 3) Fallback for show-level links: use the latest episode with an enclosure.
        if let url = items.first(where: { $0.enclosure != nil })?.enclosure {
            return url
        }

        throw ResolverError.enclosureNotFound
    }

    private final class Parser: NSObject, XMLParserDelegate {
        struct Item { var guid: String?; var title: String?; var enclosure: URL? }
        private var items: [Item] = []
        private var currentItem: Item?
        private var currentText: String = ""

        func parseItems(data: Data) throws -> [Item] {
            let parser = XMLParser(data: data)
            parser.delegate = self
            guard parser.parse() else { throw parser.parserError ?? ResolverError.enclosureNotFound }
            return items
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
            if elementName == "item" { currentItem = Item() }
            if elementName == "enclosure", let urlString = attributeDict["url"], let url = URL(string: urlString) {
                currentItem?.enclosure = url
            }
            currentText = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { currentText += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "guid" { currentItem?.guid = currentText.trimmingCharacters(in: .whitespacesAndNewlines) }
            if elementName == "title" { currentItem?.title = currentText.trimmingCharacters(in: .whitespacesAndNewlines) }
            if elementName == "item", let item = currentItem { items.append(item); currentItem = nil }
            currentText = ""
        }
    }
}

private actor PlayerDurationProvider {
    static let shared = PlayerDurationProvider()
    private init() {}

    var currentDuration: Double {
        // Attempt to read duration via NotificationCenter or a shared reference if available.
        // As a simple approximation, return a reasonable default if unknown.
        // This can be replaced by a proper dependency injection of the player if desired.
        return  max(PlayerDurationCache.shared.duration, 1)
    }
}
