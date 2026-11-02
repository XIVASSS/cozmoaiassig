import Foundation

enum PacketBuilder {
    static func build(from engine: WalkEngine, version: Int) -> ClaimPacket {
        let snapshot = engine.snapshot(version: version)
        return assemble(snapshot)
    }

    static func recompute(_ packet: ClaimPacket) -> ClaimPacket {
        var next = packet
        next.totals = totals(books: next.books, items: next.items)
        var derived = queue(books: next.books, items: next.items, room: next.room)
        let kept = packet.reviewQueue.filter { line in
            line.refId == "room" && (line.reason.contains("disagreed") || line.reason.contains("never locked"))
        }
        for line in kept where !derived.contains(where: { $0.reason == line.reason }) {
            derived.append(line)
        }
        next.reviewQueue = derived
        return next
    }

    static func assemble(_ snapshot: WalkSnapshot) -> ClaimPacket {
        let books = bookLines(snapshot.books)
        let items = itemLines(snapshot.items)
        let room = roomRecord(snapshot)
        var packet = ClaimPacket(
            sweep: SweepMeta(
                id: snapshot.sessionID,
                capturedAt: iso(snapshot.startedAt),
                device: snapshot.device,
                durationS: max(0, Int((snapshot.endedAt ?? snapshot.startedAt).timeIntervalSince(snapshot.startedAt))),
                country: snapshot.settings.country,
                currency: snapshot.settings.currency,
                packetVersion: snapshot.version
            ),
            room: room,
            books: books,
            items: items,
            totals: totals(books: books, items: items),
            reviewQueue: [],
            euroComparison: euroComparisons(snapshot.books),
            timings: snapshot.timings,
            practice: snapshot.practice
        )
        packet.reviewQueue = queue(books: packet.books, items: packet.items, room: packet.room)
        if snapshot.scale.flagged {
            packet.reviewQueue.append(ReviewLine(
                refId: "room",
                reason: "Card and tracking disagreed by \(percent(snapshot.scale.disagreement)). Books use the card. The figures were not averaged."
            ))
        }
        if !snapshot.scale.locked {
            packet.reviewQueue.append(ReviewLine(refId: "room", reason: "The bank card never locked a scale."))
        }
        return packet
    }

    static func bookLines(_ drafts: [BookDraft]) -> [BookLine] {
        let grouped = Dictionary(grouping: drafts, by: \.shelf)
        var lines: [BookLine] = []
        for shelf in grouped.keys.sorted() {
            let ordered = grouped[shelf, default: []].sorted { $0.midX < $1.midX }
            for (index, draft) in ordered.enumerated() {
                lines.append(BookLine(
                    id: draft.id,
                    shelf: draft.shelf,
                    position: index + 1,
                    frameRef: draft.frameRef,
                    status: draft.status,
                    title: draft.status == .identified || draft.status == .needsAppraisal ? draft.title : "",
                    author: draft.status == .identified || draft.status == .needsAppraisal ? draft.author : "",
                    edition: draft.edition,
                    isbn: draft.status == .identified ? draft.isbn : "",
                    publisher: draft.publisher,
                    candidateTitle: draft.candidateTitle,
                    spineHeightCm: rounded(draft.spineHeightCm, places: 1),
                    spineThicknessCm: rounded(draft.spineThicknessCm, places: 1),
                    idConfidence: (draft.idConfidence * 100).rounded() / 100,
                    voiceConfirmed: draft.voiceConfirmed,
                    excluded: draft.excluded,
                    replacementCost: money(draft.replacement, condition: ""),
                    usedValue: money(draft.used, condition: draft.used?.conditionAssumed ?? "")
                ))
            }
        }
        return lines
    }

    static func totals(books: [BookLine], items: [ItemLine]) -> PacketTotals {
        let claimed = books.filter { !$0.excluded }
        let identified = claimed.filter { $0.status == .identified }
        let unidentified = claimed.filter { $0.status == .unidentified }
        let shelfCM = claimed.compactMap(\.spineThicknessCm).reduce(0, +)
        let replacement = identified.compactMap { $0.replacementCost.hasAmount ? $0.replacementCost.amount : nil }.reduce(0, +)
        let used = identified.compactMap { $0.usedValue.hasAmount ? $0.usedValue.amount : nil }.reduce(0, +)
        let pricedItems = items.filter { $0.status != .needsAppraisal && $0.replacementCost.low != nil }
        var excluded = books.filter(isExcludedFromMoney).count
        excluded += items.filter { $0.replacementCost.low == nil }.count
        return PacketTotals(
            bookCount: claimed.count,
            booksIdentified: identified.count,
            booksUnidentified: unidentified.count,
            shelfRunM: (shelfCM / 100 * 1000).rounded() / 1000,
            booksReplacementCost: roundMoney(replacement),
            booksUsedValue: roundMoney(used),
            itemsReplacementCostLow: roundMoney(pricedItems.compactMap(\.replacementCost.low).reduce(0, +)),
            itemsReplacementCostHigh: roundMoney(pricedItems.compactMap(\.replacementCost.high).reduce(0, +)),
            excludedFromTotals: excluded
        )
    }

    static func isExcludedFromMoney(_ book: BookLine) -> Bool {
        if book.excluded { return true }
        if book.status != .identified { return true }
        return !book.replacementCost.hasAmount && !book.usedValue.hasAmount
    }

    static func summary(for packet: ClaimPacket) -> String {
        let books = packet.totals.bookCount
        let identified = packet.totals.booksIdentified
        let unidentified = packet.totals.booksUnidentified
        let queue = packet.reviewQueue.count
        let money: String
        if packet.books.contains(where: { $0.replacementCost.hasAmount && !$0.excluded && $0.status == .identified }) {
            money = "Sourced replacement total is \(format(packet.totals.booksReplacementCost, currency: packet.sweep.currency))."
        } else {
            money = "I do not have a sourced replacement total."
        }
        return "I counted \(books) books. \(identified) identified. \(unidentified) unidentified. \(money) \(queue) lines need a person."
    }

    private static func roomRecord(_ snapshot: WalkSnapshot) -> RoomRecord {
        let correction = snapshot.scale.locked ? snapshot.scale.correction : 1
        let raw = snapshot.room
        let floor = raw.floorAreaM2.map { MeasureMath.apply(correction: correction, meters: $0) }
        let walls = raw.wallAreaM2.map { MeasureMath.apply(correction: correction, meters: $0) }
        let length = raw.floorWidthM.map { MeasureMath.apply(correction: correction, meters: $0) }
        let width = raw.floorDepthM.map { MeasureMath.apply(correction: correction, meters: $0) }
        let height = raw.ceilingHeightM.map { MeasureMath.apply(correction: correction, meters: $0) }
        let shelves = raw.shelfFaceAreaM2
        var method = "Bank card, ISO ID-1, correcting ARKit tracking."
        if snapshot.practice { method = "Practice replay. Not a measured room." }
        if !snapshot.scale.locked { method = "No card lock. Room figures are unscaled tracking and are not a measurement." }
        var confidence = 0.0
        if snapshot.scale.locked && floor != nil {
            confidence = snapshot.scale.flagged ? 0.35 : 0.8
        }
        return RoomRecord(
            lengthM: rounded(length, places: 2),
            widthM: rounded(width, places: 2),
            heightM: rounded(height, places: 2),
            floorAreaM2: snapshot.scale.locked ? rounded(floor, places: 2) : nil,
            wallAreaM2: snapshot.scale.locked ? rounded(walls, places: 2) : nil,
            shelvedWallAreaM2: snapshot.scale.locked ? rounded(shelves, places: 2) : nil,
            scaleMethod: method,
            confidence: confidence,
            arkitFloorAreaM2: rounded(raw.floorAreaM2, places: 2),
            shapeNote: raw.shapeNote
        )
    }

    private static func itemLines(_ drafts: [ItemDraft]) -> [ItemLine] {
        drafts.map { draft in
            ItemLine(
                id: draft.id,
                category: draft.category,
                description: draft.description,
                brandModel: draft.brandModel,
                frameRef: draft.frameRef,
                dimensionsCm: DimensionsCM(
                    w: rounded(draft.widthCm, places: 1),
                    h: rounded(draft.heightCm, places: 1),
                    d: rounded(draft.depthCm, places: 1)
                ),
                status: draft.status,
                replacementCost: ItemCost(
                    low: draft.replacementLow,
                    high: draft.replacementHigh,
                    source: draft.source,
                    url: draft.url,
                    retrievedAt: draft.retrievedAt
                ),
                confidence: draft.confidence
            )
        }
    }

    private static func euroComparisons(_ drafts: [BookDraft]) -> [EuroComparison] {
        drafts.filter { $0.status == .identified && !$0.excluded }.prefix(10).map { draft in
            EuroComparison(
                bookID: draft.id,
                title: draft.title,
                replacement: draft.euroReplacement ?? .empty(),
                used: draft.euroUsed ?? .empty()
            )
        }
    }

    private static func queue(books: [BookLine], items: [ItemLine], room: RoomRecord) -> [ReviewLine] {
        var lines: [ReviewLine] = []
        for book in books where !book.excluded {
            var reasons: [String] = []
            if book.status == .unidentified, !book.candidateTitle.isEmpty {
                reasons.append("Hunch only. Not identified and not priced.")
            } else if book.status == .unidentified {
                reasons.append("Spine unread. No title filed.")
            }
            if book.status == .needsAppraisal {
                reasons.append("Needs a person before any price.")
            }
            if book.status == .identified, !book.replacementCost.hasAmount, !book.usedValue.hasAmount {
                reasons.append("No sourced price.")
            }
            if book.spineHeightCm == nil, book.status == .identified {
                reasons.append("No card scale for this spine.")
            }
            if let reason = reasons.first {
                lines.append(ReviewLine(refId: book.id, reason: reasons.joined(separator: " ")))
            }
        }
        for book in books where book.excluded {
            lines.append(ReviewLine(refId: book.id, reason: "Left out of the totals."))
        }
        for item in items {
            if item.status == .needsAppraisal {
                lines.append(ReviewLine(refId: item.id, reason: item.category == "framed art" ? "Art stays unpriced until they say it is a print, and then only with a listing." : "No sourced price."))
            }
        }
        if room.floorAreaM2 == nil {
            lines.append(ReviewLine(refId: "room", reason: "Floor area is empty."))
        }
        return lines
    }

    private static func money(_ value: SourcedMoney?, condition: String) -> SourcedMoney {
        guard var value, value.hasAmount else { return .empty() }
        if !condition.isEmpty { value.conditionAssumed = condition }
        if let amount = value.amount { value.amount = roundMoney(amount) }
        return value
    }

    private static func roundMoney(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func rounded(_ value: Double?, places: Int) -> Double? {
        guard let value else { return nil }
        let factor = pow(10, Double(places))
        return (value * factor).rounded() / factor
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded())) percent"
    }

    private static func format(_ amount: Double, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: NSNumber(value: amount)) ?? "\(amount) \(currency)"
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

struct WalkSnapshot {
    var sessionID: String
    var startedAt: Date
    var endedAt: Date?
    var device: String
    var settings: WalkSettings
    var scale: ScaleState
    var books: [BookDraft]
    var items: [ItemDraft]
    var room: RoomObservation
    var timings: [StageTiming]
    var practice: Bool
    var version: Int
}
