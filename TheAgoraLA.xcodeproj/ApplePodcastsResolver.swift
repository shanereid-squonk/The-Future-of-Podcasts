import Foundation

struct ApplePodcastsResolver {
    // Apple Lookup API response models
    private struct LookupResponse: Decodable {
        let results: [LookupItem]
    }

    private struct LookupItem: Decodable {
        let feedUrl: String?
        let collectionId: Int?
        let trackId: Int?
        let trackName: String?
        let episodeGuid: String?
    }

    enum ResolverError: Error {
        case unrecognizedLink
        case feedNotFound
        case enclosureNotFound
    }

    // Public entry point: resolve an Apple Podcasts share URL to a direct MP3 URL
    func resolve(from appleURL: URL) async throws -> URL {
        // Extract show and episode identifiers from the Apple Podcasts URL
        guard let showId = extractShowId(from: appleURL) else {
            throw ResolverError.unrecognizedLink
        }
        let episodeId = extractEpisodeId(from: appleURL)

        // 1) Lookup the show's RSS feed URL
        let feedURL = try await fetchFeedURL(showId: showId)

        // 2) If we have an episode id, try to get its episodeGuid and title for precise matching
        let episodeMeta = try await fetchEpisodeMeta(showId: showId, episodeId: episodeId)

        // 3) Parse the RSS and find the matching item's enclosure URL
        let enclosure = try await findEnclosure(in: feedURL, matchGuid: episodeMeta.guid, matchTitle: episodeMeta.title)
        return enclosure
    }

    // MARK: - Parsing Apple Podcasts URL

    private func extractShowId(from url: URL) -> String? {
        // Look for "id#########" anywhere in the URL
        let full = url.absoluteString
        if let range = full.range(of: "id(\\d+)", options: .regularExpression) {
            let idToken = String(full[range]) // e.g., "id1234567890"
            return String(idToken.dropFirst(2))
        }
        return nil
    }

    private func extractEpisodeId(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "i" })?
            .value
    }

    // MARK: - Apple Lookup API

    private func fetchFeedURL(showId: String) async throws -> URL {
        let endpoint = URL(string: "https://itunes.apple.com/lookup?id=\(showId)")!
        let (data, _) = try await URLSession.shared.data(from: endpoint)
        let lookup = try JSONDecoder().decode(LookupResponse.self, from: data)
        guard let feed = lookup.results.first?.feedUrl, let url = URL(string: feed) else {
            throw ResolverError.feedNotFound
        }
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

    // MARK: - RSS Parsing and matching

    private func findEnclosure(in feedURL: URL, matchGuid: String?, matchTitle: String?) async throws -> URL {
        let (data, _) = try await URLSession.shared.data(from: feedURL)
        let items = try RSSParser().parseItems(data: data)

        // 1) Exact GUID match
        if let guid = matchGuid, let item = items.first(where: { $0.guid == guid }), let url = item.enclosure {
            return url
        }

        // 2) Title match (case-insensitive)
        if let title = matchTitle?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if let item = items.first(where: { ($0.title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) == title }), let url = item.enclosure {
                return url
            }
        }

        // 3) Fallback: first item with an enclosure (latest episode)
        if let url = items.first(where: { $0.enclosure != nil })?.enclosure {
            return url
        }

        throw ResolverError.enclosureNotFound
    }
}

// Minimal RSS parser for <guid>, <title>, and <enclosure url="…"> attributes
final class RSSParser: NSObject, XMLParserDelegate {
    struct Item {
        var guid: String?
        var title: String?
        var enclosure: URL?
    }

    private var items: [Item] = []
    private var currentItem: Item?
    private var currentElement: String = ""
    private var currentText: String = ""

    func parseItems(data: Data) throws -> [Item] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { throw parser.parserError ?? ApplePodcastsResolver.ResolverError.enclosureNotFound }
        return items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        currentText = ""
        if elementName == "item" { currentItem = Item() }
        if elementName == "enclosure", let urlString = attributeDict["url"], let url = URL(string: urlString) {
            currentItem?.enclosure = url
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "guid" { currentItem?.guid = currentText.trimmingCharacters(in: .whitespacesAndNewlines) }
        if elementName == "title" { currentItem?.title = currentText.trimmingCharacters(in: .whitespacesAndNewlines) }
        if elementName == "item", let item = currentItem { items.append(item); currentItem = nil }
        currentElement = ""
        currentText = ""
    }
}
