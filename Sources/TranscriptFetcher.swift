import Foundation

struct TranscriptFetcher {
    // Public entry: fetch transcript from an Apple Podcasts share URL
    func fetch(appleURL: URL) async throws -> String? {
        // 1) Resolve show/feed and episode metadata
        guard let showId = extractShowId(from: appleURL) else { return nil }
        let feedURL = try await fetchFeedURL(showId: showId)

        var episodeGUID: String? = nil
        var episodeTitle: String? = nil
        if let episodeId = extractEpisodeId(from: appleURL) {
            (episodeGUID, episodeTitle) = try await fetchEpisodeMeta(showId: showId, episodeId: episodeId)
        }

        // 2) Fetch and parse RSS
        let items = try await parseRSSItems(feedURL: feedURL)

        // 3) Find matching item
        let item = matchItem(in: items, guid: episodeGUID, title: episodeTitle)

        // 4) Prefer explicit transcript
        if let transcript = item.transcript {
            return try await downloadTranscript(from: transcript.url, advertisedType: transcript.type)
        }

        // 5) Fallbacks: content:encoded, then description
        if let content = item.contentEncoded, !content.isEmpty {
            return stripHTML(content)
        }
        if let desc = item.description, !desc.isEmpty {
            return stripHTML(desc)
        }

        return nil
    }

    // Fetch both the episode title and transcript (if available)
    func fetchMetadata(appleURL: URL) async throws -> (title: String?, transcript: String?) {
        // 1) Resolve show/feed and episode metadata
        guard let showId = extractShowId(from: appleURL) else { return (nil, nil) }
        let feedURL = try await fetchFeedURL(showId: showId)

        var episodeGUID: String? = nil
        var episodeTitle: String? = nil
        if let episodeId = extractEpisodeId(from: appleURL) {
            (episodeGUID, episodeTitle) = try await fetchEpisodeMeta(showId: showId, episodeId: episodeId)
        }

        // 2) Fetch and parse RSS
        let items = try await parseRSSItems(feedURL: feedURL)

        // 3) Find matching item
        let item = matchItem(in: items, guid: episodeGUID, title: episodeTitle)

        // 4) Prefer explicit transcript
        var transcriptText: String? = nil
        if let transcript = item.transcript {
            transcriptText = try? await downloadTranscript(from: transcript.url, advertisedType: transcript.type)
        }

        // 5) Fallbacks: content:encoded, then description
        if transcriptText == nil, let content = item.contentEncoded, !content.isEmpty {
            transcriptText = stripHTML(content)
        }
        if transcriptText == nil, let desc = item.description, !desc.isEmpty {
            transcriptText = stripHTML(desc)
        }

        return (item.title, transcriptText)
    }

    // MARK: - Apple Lookup API

    private func extractShowId(from url: URL) -> String? {
        let full = url.absoluteString
        if let range = full.range(of: "id(\\d+)", options: .regularExpression) {
            let token = String(full[range]) // e.g., "id1234567890"
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
        guard let feed = lookup.results.first?.feedUrl, let url = URL(string: feed) else {
            throw FetchError.feedNotFound
        }
        return url
    }

    private func fetchEpisodeMeta(showId: String, episodeId: String) async throws -> (guid: String?, title: String?) {
        guard let episodeIdInt = Int(episodeId) else { return (nil, nil) }
        let endpoint = URL(string: "https://itunes.apple.com/lookup?id=\(showId)&entity=podcastEpisode&limit=200")!
        let (data, _) = try await URLSession.shared.data(from: endpoint)
        let lookup = try JSONDecoder().decode(LookupResponse.self, from: data)
        if let match = lookup.results.first(where: { $0.trackId == episodeIdInt }) {
            return (match.episodeGuid, match.trackName)
        }
        return (nil, nil)
    }

    private struct LookupResponse: Decodable { let results: [LookupItem] }
    private struct LookupItem: Decodable {
        let feedUrl: String?
        let trackId: Int?
        let trackName: String?
        let episodeGuid: String?
    }

    enum FetchError: Error { case feedNotFound }

    // MARK: - RSS Parsing

    private func parseRSSItems(feedURL: URL) async throws -> [RSSItem] {
        let (data, _) = try await URLSession.shared.data(from: feedURL)
        let parser = RSSParser()
        return try parser.parseItems(data: data)
    }

    private func matchItem(in items: [RSSItem], guid: String?, title: String?) -> RSSItem {
        if let guid, let item = items.first(where: { $0.guid == guid }) { return item }
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if let item = items.first(where: { ($0.title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) == t }) { return item }
        }
        return items.first ?? RSSItem()
    }

    // MARK: - Transcript download

    private func downloadTranscript(from url: URL, advertisedType: String?) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("text/plain, application/json, text/html; q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)

        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        let type = advertisedType?.lowercased() ?? contentType

        if let type, type.contains("application/json") {
            // Expect array or object of segments with a `text` field; join texts
            if let joined = try? decodeTranscriptJSON(data) { return joined }
        }
        if let type, type.contains("text/html") {
            let html = String(data: data, encoding: .utf8) ?? ""
            return stripHTML(html)
        }
        // Default: treat as plain text
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func decodeTranscriptJSON(_ data: Data) throws -> String {
        // Try common shapes: [{"text":"..."}], { segments: [{text:"..."}] }
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let parts = array.compactMap { $0["text"] as? String }
            if !parts.isEmpty { return parts.joined(separator: " ") }
        }
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let arr = dict["segments"] as? [[String: Any]] {
                let parts = arr.compactMap { $0["text"] as? String }
                if !parts.isEmpty { return parts.joined(separator: " ") }
            }
            if let s = dict["text"] as? String { return s }
        }
        throw NSError(domain: "Transcript", code: 0, userInfo: [NSLocalizedDescriptionKey: "Unsupported JSON transcript shape"])
    }

    private func stripHTML(_ html: String) -> String {
        let noTags = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return noTags.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - RSS Parser
private final class RSSParser: NSObject, XMLParserDelegate {
    struct ItemBuilder {
        var guid: String?
        var title: String?
        var transcriptURL: URL?
        var transcriptType: String?
        var contentEncoded: String?
        var description: String?
    }

    private(set) var items: [RSSItem] = []
    private var current = ItemBuilder()
    private var currentText = ""

    func parseItems(data: Data) throws -> [RSSItem] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { throw parser.parserError ?? NSError(domain: "RSS", code: -1) }
        return items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentText = ""
        if elementName == "item" { current = ItemBuilder() }
        if elementName == "enclosure" { /* not needed here */ }
        // podcast:transcript may appear as "podcast:transcript" or "transcript" depending on parser
        if elementName == "podcast:transcript" || elementName == "transcript" {
            if let urlStr = attributeDict["url"], let u = URL(string: urlStr) { current.transcriptURL = u }
            if let t = attributeDict["type"] { current.transcriptType = t }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "guid" { current.guid = currentText.trimmingCharacters(in: .whitespacesAndNewlines) }
        if elementName == "title" { current.title = currentText.trimmingCharacters(in: .whitespacesAndNewlines) }
        if elementName == "content:encoded" { current.contentEncoded = currentText }
        if elementName == "description" { current.description = currentText }
        if elementName == "item" {
            items.append(RSSItem(
                guid: current.guid,
                title: current.title,
                transcript: current.transcriptURL.map { (url: $0, type: current.transcriptType) },
                contentEncoded: current.contentEncoded,
                description: current.description
            ))
        }
        currentText = ""
    }
}

private struct RSSItem {
    var guid: String?
    var title: String?
    var transcript: (url: URL, type: String?)?
    var contentEncoded: String?
    var description: String?
}
