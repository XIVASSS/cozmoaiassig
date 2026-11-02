import Foundation

struct PricingService {
    var session: URLSession = .shared
    var catalogue = CatalogueClient()

    func lookupIdentities(engine: WalkEngine) async -> [(String, CatalogueMatch?)] {
        var results: [(String, CatalogueMatch?)] = []
        for track in engine.tracksNeedingLookup().prefix(4) {
            let binding = BindingHint.from(thicknessCm: track.thicknessCm)
            let match = await catalogue.search(text: track.text, binding: binding)
            results.append((track.id, match))
        }
        return results
    }

    func price(books: [BookDraft], settings: WalkSettings) async -> [PriceUpdate] {
        let eligible = books.filter { $0.status == .identified && !$0.excluded }
        let euroIDs = Set(eligible.prefix(10).map(\.id))
        var updates: [PriceUpdate] = []
        for book in eligible.prefix(40) {
            let local = await quote(title: book.title, author: book.author, isbn: book.isbn, currency: settings.currency, country: settings.country, binding: book.bindingHint)
            var update = PriceUpdate(bookID: book.id, replacement: local.replacement, used: local.used, euroReplacement: nil, euroUsed: nil)
            if euroIDs.contains(book.id) {
                let euro = await quote(title: book.title, author: book.author, isbn: book.isbn, currency: settings.comparisonCurrency, country: settings.comparisonCountry, binding: book.bindingHint)
                update.euroReplacement = euro.replacement
                update.euroUsed = euro.used
            }
            updates.append(update)
        }
        return updates
    }

    func quote(title: String, author: String, isbn: String, currency: String, country: String, binding: String = "") async -> (replacement: SourcedMoney?, used: SourcedMoney?) {
        let destination = Self.destinationCountry(country)
        var used = await abeBooks(isbn: isbn, title: title, author: author, currency: currency, destination: destination, condition: "usedonly", assumed: "used, good", binding: binding)
        var replacement = await abeBooks(isbn: isbn, title: title, author: author, currency: currency, destination: destination, condition: "newonly", assumed: "new", binding: binding)
        if used == nil || replacement == nil {
            let site = await abeSite(title: title, author: author, currency: currency)
            if used == nil { used = site.used }
            if replacement == nil { replacement = site.replacement }
        }
        if replacement == nil {
            replacement = await googleListPrice(title: title, isbn: isbn, currency: currency, binding: binding)?.money
        }
        if replacement == nil, let foreign = await googleListPrice(title: title, isbn: isbn, currency: nil, binding: binding), foreign.currency != currency {
            replacement = await convert(foreign.money, from: foreign.currency, to: currency)
        }
        return (replacement, used)
    }

    private func abeBooks(isbn: String, title: String, author: String, currency: String, destination: String, condition: String, assumed: String, binding: String) async -> SourcedMoney? {
        let key = AppSecrets.abeBooksClientKey
        guard !key.isEmpty else { return nil }
        var query = [
            "clientkey=\(percent(key))",
            "currency=\(currency)",
            "destinationcountry=\(destination)",
            "bookcondition=\(condition)"
        ]
        if !isbn.isEmpty {
            query.append("isbn=\(percent(isbn))")
        } else if !title.isEmpty {
            let titled = binding.isEmpty ? title : "\(title) \(binding)"
            query.append("title=\(percent(titled))")
            if !author.isEmpty { query.append("author=\(percent(author))") }
        } else {
            return nil
        }
        guard let url = URL(string: "https://search2.abebooks.com/search?\(query.joined(separator: "&"))") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        guard let data = try? await session.data(for: request).0, let xml = String(data: data, encoding: .utf8) else { return nil }
        let prices = xml.captureAll("listingPrice").compactMap(Double.init)
        let urls = xml.captureAll("listingUrl")
        let titles = xml.captureAll("title")
        let opposite = binding == "hardcover" ? "paperback" : binding == "paperback" ? "hardcover" : ""
        var chosen: (amount: Double, url: String)?
        let count = min(prices.count, urls.count)
        for index in 0..<count {
            let listingTitle = index < titles.count ? titles[index].lowercased() : ""
            if !opposite.isEmpty, listingTitle.contains(opposite) { continue }
            if chosen == nil || prices[index] < chosen!.amount {
                chosen = (prices[index], urls[index])
            }
        }
        guard let chosen, !chosen.url.isEmpty else { return nil }
        let note = binding.isEmpty ? assumed : "\(assumed), \(binding) hint"
        return SourcedMoney(
            amount: chosen.amount,
            source: "AbeBooks",
            url: chosen.url,
            retrievedAt: ISO8601DateFormatter().string(from: Date()),
            converted: false,
            conditionAssumed: note
        )
    }

    private func googleListPrice(title: String, isbn: String, currency: String?, binding: String = "") async -> (money: SourcedMoney, currency: String)? {
        let words = isbn.isEmpty ? [title, binding].filter { !$0.isEmpty }.joined(separator: " ") : "isbn:\(isbn)"
        let q = words
        var urlString = "https://www.googleapis.com/books/v1/volumes?maxResults=3&q=\(percent(q))"
        if !AppSecrets.googleBooksAPIKey.isEmpty {
            urlString += "&key=\(AppSecrets.googleBooksAPIKey)"
        }
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        guard let data = try? await session.data(for: request).0,
              let response = try? JSONDecoder().decode(GoogleBooksResponse.self, from: data) else { return nil }
        let opposite = binding == "hardcover" ? "paperback" : binding == "paperback" ? "hardcover" : ""
        for item in response.items ?? [] {
            let described = "\(item.volumeInfo?.title ?? "") \(item.volumeInfo?.subtitle ?? "")".lowercased()
            if !opposite.isEmpty, described.contains(opposite) { continue }
            let listed = item.saleInfo?.listPrice ?? item.saleInfo?.retailPrice
            guard let amount = listed?.amount, let code = listed?.currencyCode else { continue }
            if let currency, code != currency { continue }
            let link = item.saleInfo?.buyLink ?? item.selfLink ?? ""
            guard !link.isEmpty else { continue }
            let note = binding.isEmpty ? "list price" : "list price, \(binding) hint"
            return (SourcedMoney(
                amount: amount,
                source: "Google Books",
                url: link,
                retrievedAt: ISO8601DateFormatter().string(from: Date()),
                converted: false,
                conditionAssumed: note
            ), code)
        }
        return nil
    }

    private func convert(_ money: SourcedMoney, from: String, to currency: String) async -> SourcedMoney? {
        guard let amount = money.amount, !money.source.isEmpty, from != currency else { return nil }
        guard let url = URL(string: "https://api.frankfurter.app/latest?from=\(from)&to=\(currency)") else { return nil }
        guard let data = try? await session.data(from: url).0,
              let fx = try? JSONDecoder().decode(Frankfurter.self, from: data),
              let rate = fx.rates[currency] else { return nil }
        return SourcedMoney(
            amount: (amount * rate * 100).rounded() / 100,
            source: "\(money.source) via Frankfurter \(fx.date)",
            url: money.url,
            retrievedAt: ISO8601DateFormatter().string(from: Date()),
            converted: true,
            conditionAssumed: money.conditionAssumed
        )
    }

    /// The search API needs a key. The public results page does not, and it carries a listing URL.
    private func abeSite(title: String, author: String, currency: String) async -> (replacement: SourcedMoney?, used: SourcedMoney?) {
        let query = [title, author].filter { !$0.isEmpty }.joined(separator: " ")
        guard query.count >= 3,
              let url = URL(string: "https://www.abebooks.com/servlet/SearchResults?sts=t&kn=\(percent(query))") else {
            return (nil, nil)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let data = try? await session.data(for: request).0, let html = String(data: data, encoding: .utf8) else {
            return (nil, nil)
        }
        var replacement: SourcedMoney?
        var used: SourcedMoney?
        for listing in Self.abeListings(html) {
            guard MeasureMath.jaccard(title, listing.title) >= 0.34 else { continue }
            guard let money = await money(listing, currency: currency) else { continue }
            if listing.isNew {
                if replacement == nil || (money.amount ?? .greatestFiniteMagnitude) < (replacement?.amount ?? .greatestFiniteMagnitude) {
                    replacement = money
                }
            } else if used == nil || (money.amount ?? .greatestFiniteMagnitude) < (used?.amount ?? .greatestFiniteMagnitude) {
                used = money
            }
        }
        return (replacement, used)
    }

    private func money(_ listing: AbeListing, currency: String) async -> SourcedMoney? {
        let note = listing.isNew ? "new" : "used, good"
        let money = SourcedMoney(
            amount: listing.amount,
            source: "AbeBooks",
            url: listing.url,
            retrievedAt: ISO8601DateFormatter().string(from: Date()),
            converted: false,
            conditionAssumed: note
        )
        guard listing.currency != currency.uppercased() else { return money }
        return await convert(money, from: listing.currency, to: currency.uppercased())
    }

    private static func abeListings(_ html: String) -> [AbeListing] {
        var listings: [AbeListing] = []
        let parts = html.components(separatedBy: "data-test-id=\"listing-item-")
        for part in parts.dropFirst() {
            guard let title = part.slice(from: "image for ", to: " for sale"),
                  let priceText = part.slice(from: "data-test-id=\"listing-price\">", to: "</span>"),
                  let parsed = parsePrice(priceText),
                  let path = part.bookPath else { continue }
            let condition = part.slice(from: "data-test-id=\"listing-condition\">", to: "</span>") ?? ""
            let urlPath = path.hasPrefix("/") ? path : "/\(path)"
            listings.append(AbeListing(
                title: title.replacingOccurrences(of: "&amp;", with: "&"),
                amount: parsed.amount,
                currency: parsed.currency,
                isNew: condition.lowercased().contains("new"),
                url: "https://www.abebooks.com\(urlPath)/bd"
            ))
        }
        return listings
    }

    private static func parsePrice(_ text: String) -> (amount: Double, currency: String)? {
        let cleaned = text.replacingOccurrences(of: "\u{00a0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let currency: String
        if cleaned.contains("US$") || cleaned.contains("$") { currency = "USD" }
        else if cleaned.contains("£") || cleaned.contains("GBP") { currency = "GBP" }
        else if cleaned.contains("€") || cleaned.contains("EUR") { currency = "EUR" }
        else if cleaned.contains("₹") || cleaned.contains("INR") { currency = "INR" }
        else { return nil }
        let digits = cleaned.filter { $0.isNumber || $0 == "." }
        guard let amount = Double(digits), amount > 0 else { return nil }
        return (amount, currency)
    }

    private static func destinationCountry(_ country: String) -> String {
        let code = country.uppercased()
        let alpha3 = [
            "US": "USA", "DE": "DEU", "GB": "GBR", "IN": "IND", "FR": "FRA", "IT": "ITA",
            "ES": "ESP", "CA": "CAN", "AU": "AUS", "NL": "NLD", "JP": "JPN", "CN": "CHN",
            "BR": "BRA", "MX": "MEX", "SG": "SGP", "AE": "ARE", "IE": "IRL", "NZ": "NZL",
            "SE": "SWE", "CH": "CHE", "AT": "AUT", "BE": "BEL", "PL": "POL", "KR": "KOR"
        ]
        if code.count == 3 { return code }
        return alpha3[code] ?? "USA"
    }

    private func percent(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
    }
}

private struct Frankfurter: Decodable {
    var date: String
    var rates: [String: Double]
}

private struct AbeListing {
    var title: String
    var amount: Double
    var currency: String
    var isNew: Bool
    var url: String
}

private extension String {
    func slice(from start: String, to end: String) -> String? {
        guard let from = range(of: start), let to = range(of: end, range: from.upperBound..<self.endIndex) else { return nil }
        return String(self[from.upperBound..<to.lowerBound])
    }

    var bookPath: String? {
        guard let regex = try? NSRegularExpression(pattern: "href=\"(/[^\"?]*/bd)\"") else { return nil }
        let range = NSRange(startIndex..., in: self)
        guard let match = regex.firstMatch(in: self, range: range), let slice = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[slice])
    }

    func captureAll(_ tag: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "<\(tag)>([^<]+)</\(tag)>", options: [.caseInsensitive]) else { return [] }
        let range = NSRange(startIndex..., in: self)
        return regex.matches(in: self, range: range).compactMap { match in
            guard let slice = Range(match.range(at: 1), in: self) else { return nil }
            return String(self[slice])
        }
    }
}
