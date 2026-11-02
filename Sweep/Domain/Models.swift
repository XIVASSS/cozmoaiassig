import Foundation

enum LineStatus: String, Codable {
    case identified
    case unidentified
    case needsAppraisal = "needs_appraisal"
}

enum ItemStatus: String, Codable {
    case priced
    case range
    case needsAppraisal = "needs_appraisal"
}

struct SourcedMoney: Equatable, Codable {
    var amount: Double?
    var source: String
    var url: String
    var retrievedAt: String
    var converted: Bool
    var conditionAssumed: String

    static func empty() -> SourcedMoney {
        SourcedMoney(amount: nil, source: "", url: "", retrievedAt: "", converted: false, conditionAssumed: "")
    }

    var hasAmount: Bool { amount != nil && !source.isEmpty && !url.isEmpty && !retrievedAt.isEmpty }

    enum CodingKeys: String, CodingKey {
        case amount, source, url
        case retrievedAt = "retrieved_at"
        case converted
        case conditionAssumed = "condition_assumed"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let amount {
            try container.encode(amount, forKey: .amount)
        } else {
            try container.encodeNil(forKey: .amount)
        }
        try container.encode(source, forKey: .source)
        try container.encode(url, forKey: .url)
        try container.encode(retrievedAt, forKey: .retrievedAt)
        try container.encode(converted, forKey: .converted)
        try container.encode(conditionAssumed, forKey: .conditionAssumed)
    }
}

struct WalkSettings: Equatable, Codable {
    var country: String
    var currency: String
    var comparisonCountry: String
    var comparisonCurrency: String
    var appraisalThreshold: Double
    var disagreementThreshold: Double
    /// Set from the device location. The walk does not stop to ask.
    var claimConfirmed: Bool

    static let unitedStates = WalkSettings(
        country: "US",
        currency: "USD",
        comparisonCountry: "DE",
        comparisonCurrency: "EUR",
        appraisalThreshold: 75,
        disagreementThreshold: 0.08,
        claimConfirmed: false
    )

    private static let key = "sweep.settings"

    static func load() -> WalkSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(WalkSettings.self, from: data) else {
            return .unitedStates
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: WalkSettings.key)
        }
    }
}

struct ScaleState: Equatable, Codable {
    var locked: Bool = false
    var millimetresPerPixel: Double?
    var referenceDistanceM: Double?
    var correction: Double = 1
    var disagreement: Double = 0
    var flagged: Bool = false

    func millimetresPerPixel(at distanceM: Double) -> Double? {
        guard let millimetresPerPixel, let referenceDistanceM else { return nil }
        return MeasureMath.millimetresPerPixel(
            referenceMMPerPixel: millimetresPerPixel,
            referenceDistanceM: referenceDistanceM,
            distanceM: distanceM
        )
    }
}

struct RoomObservation: Equatable, Codable {
    var floorWidthM: Double?
    var floorDepthM: Double?
    var floorAreaM2: Double?
    var wallAreaM2: Double?
    var ceilingHeightM: Double?
    var shelfFaceAreaM2: Double?
    var shapeNote: String = ""
    var planeCount: Int = 0
}

struct BookDraft: Equatable, Identifiable, Codable {
    var id: String
    var shelf: String
    var position: Int
    var frameRef: String
    var status: LineStatus
    var title: String
    var author: String
    var edition: String
    var isbn: String
    var publisher: String
    var candidateTitle: String
    var candidateAuthor: String
    var spineHeightCm: Double?
    var spineThicknessCm: Double?
    var idConfidence: Double
    var voiceConfirmed: Bool
    var excluded: Bool
    var excludeReason: String
    var firstPublishYear: Int?
    var replacement: SourcedMoney?
    var used: SourcedMoney?
    var euroReplacement: SourcedMoney?
    var euroUsed: SourcedMoney?
    var midX: Double
    var observations: Int
    var bindingHint: String = ""
}

struct ItemDraft: Equatable, Identifiable, Codable {
    var id: String
    var category: String
    var description: String
    var brandModel: String
    var frameRef: String
    var widthCm: Double?
    var heightCm: Double?
    var depthCm: Double?
    var status: ItemStatus
    var replacementLow: Double?
    var replacementHigh: Double?
    var source: String
    var url: String
    var retrievedAt: String
    var confidence: Double
    var midX: Double
    var midY: Double
}

struct StageTiming: Equatable, Codable {
    var stage: String
    var milliseconds: Int
}

struct WalkLog: Equatable, Codable {
    var at: Date
    var kind: String
    var detail: String
}

enum WalkPhase: String, Codable {
    case idle
    case greet
    case awaitCard
    case sweeping
    case finishing
    case summary
}

struct EuroComparison: Equatable, Codable {
    var bookID: String
    var title: String
    var replacement: SourcedMoney
    var used: SourcedMoney

    enum CodingKeys: String, CodingKey {
        case bookID = "book_id"
        case title
        case replacement
        case used
    }
}

struct ClaimPacket: Equatable, Codable {
    var sweep: SweepMeta
    var room: RoomRecord
    var books: [BookLine]
    var items: [ItemLine]
    var totals: PacketTotals
    var reviewQueue: [ReviewLine]
    var euroComparison: [EuroComparison]
    var timings: [StageTiming]
    var practice: Bool

    enum CodingKeys: String, CodingKey {
        case sweep, room, books, items, totals
        case reviewQueue = "review_queue"
        case euroComparison = "euro_comparison"
        case timings, practice
    }
}

struct SweepMeta: Equatable, Codable {
    var id: String
    var capturedAt: String
    var device: String
    var durationS: Int
    var country: String
    var currency: String
    var packetVersion: Int

    enum CodingKeys: String, CodingKey {
        case id
        case capturedAt = "captured_at"
        case device
        case durationS = "duration_s"
        case country, currency
        case packetVersion = "packet_version"
    }
}

struct RoomRecord: Equatable, Codable {
    var lengthM: Double?
    var widthM: Double?
    var heightM: Double?
    var floorAreaM2: Double?
    var wallAreaM2: Double?
    var shelvedWallAreaM2: Double?
    var scaleMethod: String
    var confidence: Double
    var arkitFloorAreaM2: Double?
    var shapeNote: String

    enum CodingKeys: String, CodingKey {
        case lengthM = "length_m"
        case widthM = "width_m"
        case heightM = "height_m"
        case floorAreaM2 = "floor_area_m2"
        case wallAreaM2 = "wall_area_m2"
        case shelvedWallAreaM2 = "shelved_wall_area_m2"
        case scaleMethod = "scale_method"
        case confidence
        case arkitFloorAreaM2 = "arkit_floor_area_m2"
        case shapeNote = "shape_note"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodeOptional(lengthM, forKey: .lengthM, in: &container)
        try encodeOptional(widthM, forKey: .widthM, in: &container)
        try encodeOptional(heightM, forKey: .heightM, in: &container)
        try encodeOptional(floorAreaM2, forKey: .floorAreaM2, in: &container)
        try encodeOptional(wallAreaM2, forKey: .wallAreaM2, in: &container)
        try encodeOptional(shelvedWallAreaM2, forKey: .shelvedWallAreaM2, in: &container)
        try container.encode(scaleMethod, forKey: .scaleMethod)
        try container.encode(confidence, forKey: .confidence)
        try encodeOptional(arkitFloorAreaM2, forKey: .arkitFloorAreaM2, in: &container)
        try container.encode(shapeNote, forKey: .shapeNote)
    }
}

struct BookLine: Equatable, Codable, Identifiable {
    var id: String
    var shelf: String
    var position: Int
    var frameRef: String
    var status: LineStatus
    var title: String
    var author: String
    var edition: String
    var isbn: String
    var publisher: String
    var candidateTitle: String
    var spineHeightCm: Double?
    var spineThicknessCm: Double?
    var idConfidence: Double
    var voiceConfirmed: Bool
    var excluded: Bool
    var replacementCost: SourcedMoney
    var usedValue: SourcedMoney

    enum CodingKeys: String, CodingKey {
        case id, shelf, position
        case frameRef = "frame_ref"
        case status, title, author, edition, isbn, publisher
        case candidateTitle = "candidate_title"
        case spineHeightCm = "spine_height_cm"
        case spineThicknessCm = "spine_thickness_cm"
        case idConfidence = "id_confidence"
        case voiceConfirmed = "voice_confirmed"
        case excluded
        case replacementCost = "replacement_cost"
        case usedValue = "used_value"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(shelf, forKey: .shelf)
        try container.encode(position, forKey: .position)
        try container.encode(frameRef, forKey: .frameRef)
        try container.encode(status, forKey: .status)
        try container.encode(title, forKey: .title)
        try container.encode(author, forKey: .author)
        try container.encode(edition, forKey: .edition)
        try container.encode(isbn, forKey: .isbn)
        try container.encode(publisher, forKey: .publisher)
        try container.encode(candidateTitle, forKey: .candidateTitle)
        try encodeOptional(spineHeightCm, forKey: .spineHeightCm, in: &container)
        try encodeOptional(spineThicknessCm, forKey: .spineThicknessCm, in: &container)
        try container.encode(idConfidence, forKey: .idConfidence)
        try container.encode(voiceConfirmed, forKey: .voiceConfirmed)
        try container.encode(excluded, forKey: .excluded)
        try container.encode(replacementCost, forKey: .replacementCost)
        try container.encode(usedValue, forKey: .usedValue)
    }
}

struct ItemLine: Equatable, Codable, Identifiable {
    var id: String
    var category: String
    var description: String
    var brandModel: String
    var frameRef: String
    var dimensionsCm: DimensionsCM
    var status: ItemStatus
    var replacementCost: ItemCost
    var confidence: Double

    enum CodingKeys: String, CodingKey {
        case id, category, description
        case brandModel = "brand_model"
        case frameRef = "frame_ref"
        case dimensionsCm = "dimensions_cm"
        case status
        case replacementCost = "replacement_cost"
        case confidence
    }
}

struct DimensionsCM: Equatable, Codable {
    var w: Double?
    var h: Double?
    var d: Double?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodeOptional(w, forKey: .w, in: &container)
        try encodeOptional(h, forKey: .h, in: &container)
        try encodeOptional(d, forKey: .d, in: &container)
    }
}

struct ItemCost: Equatable, Codable {
    var low: Double?
    var high: Double?
    var source: String
    var url: String
    var retrievedAt: String

    enum CodingKeys: String, CodingKey {
        case low, high, source, url
        case retrievedAt = "retrieved_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodeOptional(low, forKey: .low, in: &container)
        try encodeOptional(high, forKey: .high, in: &container)
        try container.encode(source, forKey: .source)
        try container.encode(url, forKey: .url)
        try container.encode(retrievedAt, forKey: .retrievedAt)
    }
}

struct PacketTotals: Equatable, Codable {
    var bookCount: Int
    var booksIdentified: Int
    var booksUnidentified: Int
    var shelfRunM: Double
    var booksReplacementCost: Double
    var booksUsedValue: Double
    var itemsReplacementCostLow: Double
    var itemsReplacementCostHigh: Double
    var excludedFromTotals: Int

    enum CodingKeys: String, CodingKey {
        case bookCount = "book_count"
        case booksIdentified = "books_identified"
        case booksUnidentified = "books_unidentified"
        case shelfRunM = "shelf_run_m"
        case booksReplacementCost = "books_replacement_cost"
        case booksUsedValue = "books_used_value"
        case itemsReplacementCostLow = "items_replacement_cost_low"
        case itemsReplacementCostHigh = "items_replacement_cost_high"
        case excludedFromTotals = "excluded_from_totals"
    }
}

struct ReviewLine: Equatable, Codable, Identifiable {
    var id: String { refId + reason }
    var refId: String
    var reason: String

    enum CodingKeys: String, CodingKey {
        case refId = "ref_id"
        case reason
    }
}

struct SessionSummary: Equatable, Identifiable, Codable {
    var id: String
    var capturedAt: Date
    var practice: Bool
    var phase: String
    var bookCount: Int
    var floorAreaM2: Double?
    var reviewCount: Int
    var packetVersion: Int
    var country: String
    var currency: String
}

private func encodeOptional<K: CodingKey>(_ value: Double?, forKey key: K, in container: inout KeyedEncodingContainer<K>) throws {
    if let value {
        try container.encode(value, forKey: key)
    } else {
        try container.encodeNil(forKey: key)
    }
}
