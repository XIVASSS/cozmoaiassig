import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: WalkSettings
    @Published var sessions: [SessionSummary]
    let store: SessionStore

    init() {
        settings = WalkSettings.load()
        let store = SessionStore()
        self.store = store
        sessions = store.summaries()
    }

    func reload() {
        sessions = store.summaries()
    }

    func updateSettings(_ settings: WalkSettings) {
        self.settings = settings
        settings.save()
    }

    func delete(_ id: String) {
        store.delete(id: id)
        reload()
    }

    func reviewEntries() -> [ReviewEntry] {
        sessions.flatMap { summary in
            guard let packet = store.latestPacket(id: summary.id) else { return [ReviewEntry]() }
            return packet.reviewQueue.map { line in
                let book = packet.books.first { $0.id == line.refId }
                let hunch = book.map(Self.isHunch) ?? false
                return ReviewEntry(
                    id: "\(summary.id)-\(line.refId)-\(line.reason)",
                    sessionID: summary.id,
                    refID: line.refId,
                    reason: line.reason,
                    when: summary.capturedAt,
                    packetVersion: packet.sweep.packetVersion,
                    isHunch: hunch,
                    hunchTitle: book?.candidateTitle ?? ""
                )
            }
        }
    }

    static func isHunch(_ book: BookLine) -> Bool {
        book.status == .unidentified && !book.candidateTitle.isEmpty && !book.excluded
    }

    /// The person kept this hunch. Search it again, then price whatever comes back.
    func acceptHunch(sessionID: String, version: Int, bookID: String) async -> Int? {
        guard let packet = store.packet(id: sessionID, version: version),
              let book = packet.books.first(where: { $0.id == bookID }),
              Self.isHunch(book) else { return nil }
        let spine = book.candidateTitle
        let match = await CatalogueClient().search(text: spine)
        return await revise(sessionID: sessionID, version: version) { draft in
            guard let index = draft.books.firstIndex(where: { $0.id == bookID }) else { return }
            draft.books[index].voiceConfirmed = true
            draft.books[index].idConfidence = max(draft.books[index].idConfidence, 0.9)
            if let match, case .identified(let found) = MeasureMath.decideReport(text: spine, match: match) {
                draft.books[index].title = found.title
                if !found.author.isEmpty { draft.books[index].author = found.author }
                if !found.isbn.isEmpty { draft.books[index].isbn = found.isbn }
                if !found.publisher.isEmpty { draft.books[index].publisher = found.publisher }
            } else {
                draft.books[index].title = spine
            }
            draft.books[index].status = .identified
            draft.books[index].candidateTitle = ""
        }
    }

    func dropHunch(sessionID: String, version: Int, bookID: String) async -> Int? {
        guard let packet = store.packet(id: sessionID, version: version),
              packet.books.contains(where: { $0.id == bookID && Self.isHunch($0) }) else { return nil }
        return await revise(sessionID: sessionID, version: version) { draft in
            guard let index = draft.books.firstIndex(where: { $0.id == bookID }) else { return }
            draft.books[index].excluded = true
        }
    }

    @discardableResult
    func revise(sessionID: String, version: Int, edit: (inout ClaimPacket) -> Void) async -> Int? {
        guard var packet = store.packet(id: sessionID, version: version) else { return nil }
        edit(&packet)
        let priced = await priceMissing(packet)
        packet.books = priced.books
        packet.euroComparison = priced.euros
        packet = PacketBuilder.recompute(packet)
        let next = (store.packetVersions(id: sessionID).last ?? version) + 1
        packet.sweep.packetVersion = next
        try? store.savePacket(packet, logs: [])
        reload()
        return next
    }

    private func priceMissing(_ packet: ClaimPacket) async -> (books: [BookLine], euros: [EuroComparison]) {
        var books = packet.books
        var euros = packet.euroComparison
        let service = PricingService()
        for index in books.indices {
            let book = books[index]
            guard book.status == .identified, !book.excluded, !book.replacementCost.hasAmount, !book.usedValue.hasAmount else { continue }
            let quote = await service.quote(title: book.title, author: book.author, isbn: book.isbn, currency: packet.sweep.currency, country: packet.sweep.country)
            if let replacement = quote.replacement, (replacement.amount ?? 0) < settings.appraisalThreshold {
                books[index].replacementCost = replacement
            } else if (quote.replacement?.amount ?? 0) >= settings.appraisalThreshold, quote.replacement?.amount != nil {
                books[index].status = .needsAppraisal
                books[index].replacementCost = .empty()
                books[index].usedValue = .empty()
                continue
            }
            if let used = quote.used, (used.amount ?? 0) < settings.appraisalThreshold {
                books[index].usedValue = used
            }
            let ranked = books.filter { $0.status == .identified && !$0.excluded }.prefix(10)
            guard ranked.contains(where: { $0.id == book.id }) else { continue }
            let euro = await service.quote(
                title: books[index].title,
                author: books[index].author,
                isbn: books[index].isbn,
                currency: settings.comparisonCurrency,
                country: settings.comparisonCountry
            )
            let row = EuroComparison(
                bookID: book.id,
                title: books[index].title,
                replacement: euro.replacement ?? .empty(),
                used: euro.used ?? .empty()
            )
            if let existing = euros.firstIndex(where: { $0.bookID == book.id }) {
                euros[existing] = row
            } else {
                euros.append(row)
            }
        }
        return (books, euros)
    }
}

struct ReviewEntry: Identifiable {
    var id: String
    var sessionID: String
    var refID: String
    var reason: String
    var when: Date
    var packetVersion: Int
    var isHunch: Bool
    var hunchTitle: String
}
