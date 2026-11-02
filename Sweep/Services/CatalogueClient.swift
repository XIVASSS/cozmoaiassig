import Foundation

struct CatalogueClient {
    var session: URLSession = CatalogueClient.catalogueSession

    private static let catalogueSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config)
    }()

    func search(text: String, binding: String = "") async -> CatalogueMatch? {
        let spine = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard spine.count >= 3 else { return nil }
        for query in queryAttempts(spine).prefix(4) {
            let hits = await openLibrary(query, spine: spine)
            let agreeing = hits.filter {
                MeasureMath.catalogueAgrees(ocr: spine, title: $0.title, author: $0.author, published: $0.firstPublishYear)
            }
            let named = agreeing.filter { authorOnSpine($0.author, spine: spine) }
            let pool: [CatalogueMatch]
            if !named.isEmpty {
                pool = named
            } else if Set(agreeing.map { $0.author.lowercased() }.filter { !$0.isEmpty }).count > 1 {
                continue
            } else if let only = agreeing.first, !MeasureMath.titleIsDistinctive(only.title) {
                continue
            } else {
                pool = agreeing
            }
            if let best = pool.max(by: { rank($0) < rank($1) }) {
                var copy = best
                copy.score += BindingHint.scoreAdjustment(match: best, binding: binding)
                return copy
            }
        }
        if !AppSecrets.googleBooksAPIKey.isEmpty, let google = await googleBooks(spine) {
            if MeasureMath.catalogueAgrees(ocr: spine, title: google.title, author: google.author, published: google.firstPublishYear) {
                return google
            }
        }
        return nil
    }

    /// A short slice first. Open Library misses a whole glued line and finds "Joy Harjo our songs came through".
    func queryAttempts(_ text: String) -> [String] {
        let normalized = MeasureMath.spineForSearch(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let words = normalized.split(separator: " ").map(String.init)
        let solid = words.filter { $0.count > 2 }
        var queries: [String] = []
        let skip: Set<String> = ["book", "books", "press", "edited", "with", "from", "that", "this"]
        var content: [String] = []
        var seenWords = Set<String>()
        let longer = solid.filter { $0.count >= 5 }
        for word in solid where word.count >= 4 && !skip.contains(word.lowercased()) && !isGarbled(word) {
            if word.count == 4, longer.contains(where: { $0.lowercased().hasPrefix(word.lowercased()) }) { continue }
            if seenWords.insert(word.lowercased()).inserted { content.append(word) }
        }
        if content.count >= 2 {
            if let yearIndex = content.firstIndex(where: { $0.count == 4 && Int($0) != nil }), yearIndex >= 2 {
                let start = max(0, yearIndex - 3)
                queries.append(content[start...yearIndex].joined(separator: " "))
            }
            queries.append(content.prefix(4).joined(separator: " "))
            let longest = content.filter { $0.count >= 5 }.sorted { $0.count > $1.count }
            if longest.count >= 2 {
                queries.append(longest.prefix(2).joined(separator: " "))
            }
        }
        let readable = solid.filter { !isGarbled($0) }
        let cleaned = readable.joined(separator: " ")
        if cleaned.count >= 3, cleaned.caseInsensitiveCompare(normalized) != .orderedSame {
            queries.append(cleaned)
        }
        if solid.count >= 8 {
            queries.append(solid.suffix(6).joined(separator: " "))
        }
        if solid.count >= 5 {
            queries.append(solid.suffix(5).joined(separator: " "))
        }
        queries.append(normalized)
        let dated = words.filter { word in
            guard word.count == 4, let year = Int(word) else { return true }
            return (1950...2030).contains(year)
        }
        let withoutBadYear = dated.joined(separator: " ")
        if withoutBadYear.caseInsensitiveCompare(normalized) != .orderedSame {
            queries.append(withoutBadYear)
        }
        var seen = Set<String>()
        return queries.filter { seen.insert($0.lowercased()).inserted }
    }

    /// An audiobook "Part 1 of 3" loses to the same book without the part label.
    private func rank(_ match: CatalogueMatch) -> Double {
        match.title.lowercased().contains(" part ") ? match.score - 0.25 : match.score
    }

    /// "John Man" on the spine picks John Man's Genghis Khan, not the other book of the same name.
    private func authorOnSpine(_ author: String, spine: String) -> Bool {
        let spineTokens = MeasureMath.tokens(spine)
        return MeasureMath.tokens(author).contains { word in
            word.count >= 4 && spineTokens.contains { MeasureMath.sameWord($0, word) }
        }
    }

    /// "27TA" and "FORTET" are not words. "Seamus" and "Espada" are, and they have to stay in the search.
    private func isGarbled(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        if word.contains(where: \.isNumber), !letters.isEmpty { return true }
        guard letters.count >= 5 else { return false }
        var run = 0
        for character in letters.lowercased() {
            if "aeiou".contains(character) {
                run = 0
            } else {
                run += 1
                if run >= 4 { return true }
            }
        }
        return !letters.lowercased().contains(where: { "aeiou".contains($0) })
    }

    private func openLibrary(_ query: String, spine: String) async -> [CatalogueMatch] {
        guard let url = URL(string: "https://openlibrary.org/search.json?limit=8&q=\(percent(query))") else { return [] }
        guard let data = try? await session.data(from: url).0 else { return [] }
        guard let response = try? JSONDecoder().decode(OpenLibraryResponse.self, from: data) else { return [] }
        return (response.docs ?? []).compactMap { doc -> CatalogueMatch? in
            guard let title = doc.title, !title.isEmpty else { return nil }
            let score = MeasureMath.jaccard(spine, title)
            let note = BindingHint.edition(in: title)
            return CatalogueMatch(
                title: title,
                author: doc.authorName?.first ?? "",
                isbn: doc.isbn?.first ?? "",
                publisher: "",
                firstPublishYear: doc.firstPublishYear,
                score: score,
                format: BindingHint.format(in: title),
                editionNote: note
            )
        }
    }

    private func googleBooks(_ query: String) async -> CatalogueMatch? {
        var parts = ["https://www.googleapis.com/books/v1/volumes?maxResults=5&q=\(percent(query))"]
        if !AppSecrets.googleBooksAPIKey.isEmpty {
            parts.append("key=\(AppSecrets.googleBooksAPIKey)")
        }
        guard let url = URL(string: parts.joined(separator: "&")) else { return nil }
        guard let data = try? await session.data(from: url).0 else { return nil }
        guard let response = try? JSONDecoder().decode(GoogleBooksResponse.self, from: data) else { return nil }
        let ranked = (response.items ?? []).compactMap { item -> CatalogueMatch? in
            guard let title = item.volumeInfo?.title else { return nil }
            let score = MeasureMath.jaccard(query, title)
            guard score > 0 else { return nil }
            let isbn = item.volumeInfo?.industryIdentifiers?.first { $0.type?.contains("ISBN") == true }?.identifier ?? ""
            let subtitle = item.volumeInfo?.subtitle ?? ""
            let described = "\(title) \(subtitle)"
            return CatalogueMatch(
                title: title,
                author: item.volumeInfo?.authors?.first ?? "",
                isbn: isbn,
                publisher: item.volumeInfo?.publisher ?? "",
                firstPublishYear: nil,
                score: score,
                format: BindingHint.format(in: described),
                editionNote: BindingHint.edition(in: described)
            )
        }
        return ranked.max { $0.score < $1.score }
    }

    private func percent(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
    }
}

private struct OpenLibraryResponse: Decodable {
    var docs: [Doc]?
    struct Doc: Decodable {
        var title: String?
        var authorName: [String]?
        var isbn: [String]?
        var firstPublishYear: Int?
        enum CodingKeys: String, CodingKey {
            case title
            case authorName = "author_name"
            case isbn
            case firstPublishYear = "first_publish_year"
        }
    }
}

struct GoogleBooksResponse: Decodable {
    var items: [Item]?
    struct Item: Decodable {
        var volumeInfo: Volume?
        var saleInfo: Sale?
        var selfLink: String?
    }
    struct Volume: Decodable {
        var title: String?
        var subtitle: String?
        var authors: [String]?
        var publisher: String?
        var industryIdentifiers: [Identifier]?
    }
    struct Identifier: Decodable {
        var type: String?
        var identifier: String?
    }
    struct Sale: Decodable {
        var listPrice: Price?
        var retailPrice: Price?
        var buyLink: String?
    }
    struct Price: Decodable {
        var amount: Double?
        var currencyCode: String?
    }
}
