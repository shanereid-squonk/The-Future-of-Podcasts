import SwiftUI
import Foundation

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

    var body: some View {
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

                        // 2) Wait for realistic duration and transcript
                        let deadline = Date().addingTimeInterval(15)
                        var duration = await PlayerDurationProvider.shared.currentDuration
                        while duration < 10 && Date() < deadline {
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            duration = await PlayerDurationProvider.shared.currentDuration
                        }

                        var text = episodeStore.episode.transcript ?? transcriptText
                        while text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Date() < deadline {
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            text = episodeStore.episode.transcript ?? transcriptText
                        }

                        // Require transcript for content-aware prompt placement
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

                        // 3) Generate prompts (Beginning/Middle/End)
                        let generated = await AIService().generatePrompts(transcript: text, audioDuration: duration, desiredCount: 3)
                        await MainActor.run { episodeStore.replacePrompts(generated) }
                    }
                }
                .buttonStyle(AgoraPillButtonStyle())
                .disabled(isResolving || isAnalyzingPrompts)

                if isAnalyzingPrompts {
                    ProgressView("Analyzing podcast to generate prompts...")
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                }
            }

            Text("Prompts")
                .font(AgoraTheme.cardTitleFont)
                .foregroundColor(AgoraTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(Array(episodeStore.episode.prompts.enumerated()), id: \.element.id) { index, prompt in
                PromptRow(index: index, prompt: prompt) {
                    episodeStore.deletePrompt(prompt)
                } onUpdate: { updated in
                    episodeStore.updatePrompt(updated)
                }
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

                    // Dismiss only after the player is ready
                    self.dismiss()

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

            dismiss()
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
}

private struct PromptRow: View {
    let index: Int
    let prompt: Prompt
    let onDelete: () -> Void
    let onUpdate: (Prompt) -> Void

    @State private var question: String
    @State private var expectedAnswer: String
    @State private var timestampSeconds: Double
    @State private var leadTimeSeconds: Double

    init(index: Int, prompt: Prompt, onDelete: @escaping () -> Void, onUpdate: @escaping (Prompt) -> Void) {
        self.index = index
        self.prompt = prompt
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
                    Text("Time: \(String(format: "%.0f", timestampSeconds))s")
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

                TextField("Question", text: $question)
                    .agoraFieldStyle()

                TextField("Expected answer", text: $expectedAnswer)
                    .agoraFieldStyle()

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
        switch index {
        case 0: return 0...30 // 0-30s
        case 1: return 60...120 // 1-2 minutes
        case 2: return 150...3600 // 2:30 to 60 minutes (practical upper bound)
        default: return 0...3600
        }
    }

    private var timestampStep: Double {
        switch index {
        case 0, 1: return 5
        case 2: return 10
        default: return 5
        }
    }

    private var quickSelectTimestamps: [Double] {
        switch index {
        case 0: return [0, 5, 10, 15, 20, 25, 30]
        case 1: return [60, 75, 90, 105, 120]
        case 2: return [150, 180, 210, 240, 300, 600, 900]
        default: return [30, 60, 90]
        }
    }

    private func formatSeconds(_ seconds: Double) -> String {
        let s = Int(seconds)
        let m = s / 60
        let r = s % 60
        if m > 0 { return String(format: "%d:%02d", m, r) }
        return "\(s)s"
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

