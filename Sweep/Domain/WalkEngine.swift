import Foundation

struct WalkEngine {
    private(set) var phase: WalkPhase = .idle
    private(set) var instruction: String = ""
    private(set) var baseInstruction: String = ""
    private(set) var scale = ScaleState()
    private(set) var books: [BookDraft] = []
    private(set) var items: [ItemDraft] = []
    private(set) var room = RoomObservation()
    private(set) var logs: [WalkLog] = []
    private(set) var timings: [StageTiming] = []
    private(set) var settings = WalkSettings.unitedStates
    private(set) var sessionID = ""
    private(set) var startedAt = Date()
    private(set) var endedAt: Date?
    private(set) var device = ""
    private(set) var practice = false
    private(set) var countryConfirmed = false
    private var tracks: [SpineTrack] = []
    private var lastIssue: String = ""
    private var lastIssueAt: Date?
    private var shelfSeenAt: [String: Date] = [:]
    private var lookedAway = false
    private var lastCueAt: Date?
    private var said: Set<String> = []
    var quiet = false

    static let opening = "We are going to walk this room once. First, country and currency. Then the card on the shelf, flat, for two seconds."
    static let softFrame = "Stop. Step closer to the left of that shelf and hold still."
    static let tooFast = "Back half a step. Hold the card flat on that shelf again."
    static let passedShelf = "You passed a shelf. Pan back to it and hold."
    static let cardAsk = "Hold a bank card flat on the first shelf, for two seconds."
    static let walkAsk = "Scale is locked. Walk this room once. I read the spines as you pass them."
    static let showSpine = "Keep walking. I read spines on the shelf, not one book at a time."
    static let straighten = "Stop. Step closer to the left of that shelf and hold still."
    static let readSpine = "I can read that spine. Keep walking the shelf."

    mutating func begin(sessionID: String, settings: WalkSettings, device: String, practice: Bool) {
        self.sessionID = sessionID
        self.settings = settings
        self.device = device
        self.practice = practice
        startedAt = Date()
        endedAt = nil
        phase = .greet
        countryConfirmed = false
        setBase(Self.opening)
        log("phase", Self.opening)
    }

    mutating func apply(transcript: String) -> Bool {
        let correction = CorrectionParser.parse(transcript)
        guard correction != .none else { return false }
        switch correction {
        case .countryUSD:
            confirmCountry()
        case .confirmHunch:
            confirmLatestHunch()
        case .firstEdition:
            markLatestFirstEdition()
        case .skipShelf:
            skipCurrentShelf()
        case .isPrint:
            markLatestArt(isPrint: true)
        case .isOriginal:
            markLatestArt(isPrint: false)
        case .moreBooks, .closer, .none:
            break
        }
        return true
    }

    mutating func confirmCountry() {
        let changed = settings.country != "US" || settings.currency != "USD"
        settings.country = "US"
        settings.currency = "USD"
        if phase == .sweeping, countryConfirmed { return }
        if changed { log("country", "US USD") }
        acceptPlace()
    }

    /// Location already chose the country. The walk starts. The person shows the shelves.
    mutating func enterDirectedSweep() {
        quiet = false
        countryConfirmed = true
        phase = .sweeping
        baseInstruction = ""
        instruction = ""
    }

    /// The phone read this from the device location. It does not ask.
    mutating func adoptPlace(country: String, currency: String) {
        settings.country = country
        settings.currency = currency
        settings.claimConfirmed = true
        countryConfirmed = true
        log("country", "\(country) \(currency) from location")
    }

    mutating func acceptPlace() {
        countryConfirmed = true
        log("country", "\(settings.country) \(settings.currency)")
        if scale.locked {
            phase = .sweeping
            setBase(Self.walkAsk)
        } else {
            phase = .awaitCard
            setBase(Self.cardAsk)
        }
    }

    mutating func noteCard(millimetresPerPixel: Double, distanceM: Double, arkitCardMeters: Double) {
        guard let decision = MeasureMath.scaleDecision(arkitCardMeters: arkitCardMeters, threshold: settings.disagreementThreshold) else { return }
        scale.locked = true
        scale.millimetresPerPixel = millimetresPerPixel
        scale.referenceDistanceM = distanceM
        scale.correction = decision.correction
        scale.disagreement = decision.disagreement
        scale.flagged = decision.flagged
        log("scale", "correction \(decision.correction) disagreement \(decision.disagreement)")
        if countryConfirmed {
            phase = .sweeping
            if !quiet {
                if decision.flagged {
                    setBase("Scale is locked from the card. Tracking disagreed by \(Int((decision.disagreement * 100).rounded())) percent. Books use the card.")
                } else {
                    setBase(Self.walkAsk)
                }
            }
        } else if phase == .greet || phase == .idle {
            setBase("Scale is locked. I still need the country and currency.")
        }
    }

    mutating func noteQuality(_ issue: QualityIssue, at date: Date = Date()) {
        guard !quiet else { return }
        guard phase == .sweeping || phase == .awaitCard else { return }
        let line: String
        switch issue {
        case .blur, .glare: line = Self.softFrame
        case .movingTooFast: line = Self.tooFast
        case .passedShelf: line = Self.passedShelf
        }
        if line == lastIssue, let lastIssueAt, date.timeIntervalSince(lastIssueAt) < 5 { return }
        lastIssue = line
        lastIssueAt = date
        instruction = line
        log("quality", line)
    }

    mutating func noteCue(_ cue: ScanCue, at date: Date = Date()) {
        guard !quiet else { return }
        guard phase == .sweeping else { return }
        if let lastIssueAt, date.timeIntervalSince(lastIssueAt) < 4 { return }
        switch cue {
        case .none:
            guard instruction != baseInstruction else { return }
            guard lastCueAt.map({ date.timeIntervalSince($0) > 4 }) ?? true else { return }
            instruction = baseInstruction
        case .showSpine, .straighten, .read:
            let line: String
            switch cue {
            case .showSpine: line = Self.showSpine
            case .straighten: line = Self.straighten
            case .read: line = Self.readSpine
            case .none: return
            }
            guard line != instruction else { return }
            if let lastCueAt, date.timeIntervalSince(lastCueAt) < 5 { return }
            lastCueAt = date
            instruction = line
        }
    }

    mutating func noteHeard(_ text: String) {
        log("heard", text)
    }

    mutating func say(_ line: String) {
        guard instruction != line else { return }
        instruction = line
    }

    mutating func noteFocus(shelf: Int) {
        guard !quiet else { return }
        guard phase == .sweeping else { return }
        let line = "Shelf \(shelf + 1). Stop. Step closer to the left of that shelf and hold still."
        guard instruction != line else { return }
        instruction = line
    }

    mutating func replaceSpines(_ hits: [SpineHit]) {
        guard phase == .sweeping || phase == .awaitCard || practice else { return }
        tracks = []
        books = []
        noteSpines(hits)
    }

    mutating func noteSpines(_ hits: [SpineHit]) {
        guard phase == .sweeping || phase == .awaitCard || practice else { return }
        if hits.isEmpty {
            if !tracks.isEmpty { lookedAway = true }
            return
        }
        if lookedAway, let last = shelfSeenAt.keys.sorted().last, !hits.contains(where: { "shelf-\($0.shelf)" == last }) {
            noteQuality(.passedShelf)
        }
        lookedAway = false
        tracks = SpineTracker.merge(tracks: tracks, hits: hits)
        for hit in hits {
            shelfSeenAt["shelf-\(hit.shelf)"] = Date()
        }
        rebuildBooks()
    }

    mutating func dropWeakHunches() {
        let identified = books.filter { $0.status == .identified && !$0.title.isEmpty }
        var keepHunch: [String] = []
        var drop: [String] = []
        var seenTitles: [String] = []
        for book in books where book.status == .identified && !book.title.isEmpty {
            if seenTitles.contains(where: { MeasureMath.jaccard($0, book.title) > 0.82 && !yearsDiffer($0, book.title) }) {
                drop.append(book.id)
            } else {
                seenTitles.append(book.title)
            }
        }
        for book in books {
            guard book.status != .identified || book.title.isEmpty else { continue }
            let text = book.candidateTitle.isEmpty ? book.title : book.candidateTitle
            let duplicate = identified.contains { known in
                if MeasureMath.jaccard(known.title, text) > 0.45 { return true }
                let hunchWords = MeasureMath.tokens(text).filter { $0.count >= 4 }
                let knownWords = MeasureMath.tokens(known.title + " " + known.author)
                guard !hunchWords.isEmpty, hunchWords.count <= knownWords.count, !yearsDiffer(text, known.title) else { return false }
                return hunchWords.allSatisfy { word in knownWords.contains { MeasureMath.sameWord($0, word) } }
            }
            if !MeasureMath.looksLikeTitle(text) || !MeasureMath.readableSpine(text) || duplicate {
                drop.append(book.id)
            } else {
                keepHunch.append(book.id)
            }
        }
        var seen: [String] = []
        let ranked = keepHunch.sorted { left, right in
            let a = books.first { $0.id == left }?.candidateTitle.count ?? 0
            let b = books.first { $0.id == right }?.candidateTitle.count ?? 0
            return a > b
        }
        for id in ranked {
            let text = books.first { $0.id == id }?.candidateTitle ?? ""
            let fragment = seen.contains { other in
                guard MeasureMath.jaccard(other, text) > 0.55, !yearsDiffer(other, text) else { return false }
                return abs(other.count - text.count) > 12
            }
            if fragment {
                drop.append(id)
            } else {
                seen.append(text)
            }
        }
        for book in books where book.status == .identified && !book.title.isEmpty {
            let words = MeasureMath.tokens(book.title).filter { $0.count >= 4 }
            let author = MeasureMath.tokens(book.author).filter { $0.count >= 5 }
            let absorbed = books.contains { other in
                guard other.id != book.id, other.status == .identified else { return false }
                let sameAuthor = author.contains { name in
                    MeasureMath.tokens(other.author).contains { MeasureMath.sameWord($0, name) }
                }
                let otherWords = MeasureMath.tokens(other.title).filter { $0.count >= 4 }
                return sameAuthor && otherWords.count > words.count && words.allSatisfy { word in
                    otherWords.contains { MeasureMath.sameWord($0, word) }
                }
            }
            let storyLine = tracks.contains { track in
                track.id == book.id && track.text.lowercased().contains("story of")
            }
            let repeatsAuthor = books.contains { other in
                other.id != book.id && other.status == .identified && author.contains { name in
                    MeasureMath.tokens(other.author).contains { MeasureMath.sameWord($0, name) }
                }
            }
            if absorbed || (storyLine && repeatsAuthor) { drop.append(book.id) }
        }
        let gone = Set(drop)
        books.removeAll { gone.contains($0.id) }
        tracks.removeAll { gone.contains($0.id) }
    }

    private func yearsDiffer(_ left: String, _ right: String) -> Bool {
        func year(_ text: String) -> Int? {
            for word in text.split(whereSeparator: { !$0.isNumber }) {
                if let value = Int(word), (1900...2030).contains(value) { return value }
            }
            return nil
        }
        guard let a = year(left), let b = year(right) else { return false }
        return a != b
    }

    mutating func resolve(trackID: String, match: CatalogueMatch?, report: Bool = false) {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let track = tracks[index]
        let decision = report
            ? MeasureMath.decideReport(text: track.text, match: match)
            : MeasureMath.decideIdentity(text: track.text, ocrConfidence: track.confidence, match: match)
        guard let bookIndex = books.firstIndex(where: { $0.id == trackID }) else { return }
        switch decision {
        case .identified(let found):
            guard !found.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard !books[bookIndex].voiceConfirmed || books[bookIndex].status != .needsAppraisal else { return }
            let described = "\(found.title) \(found.editionNote)"
            books[bookIndex].status = appraisalStatus(year: found.firstPublishYear, title: described) ?? .identified
            books[bookIndex].title = found.title
            books[bookIndex].author = found.author
            books[bookIndex].isbn = found.isbn
            books[bookIndex].publisher = found.publisher
            books[bookIndex].firstPublishYear = found.firstPublishYear
            if !found.editionNote.isEmpty { books[bookIndex].edition = found.editionNote }
            let measured = BindingHint.from(thicknessCm: books[bookIndex].spineThicknessCm)
            books[bookIndex].bindingHint = measured.isEmpty ? found.format : measured
            books[bookIndex].candidateTitle = ""
            books[bookIndex].idConfidence = min(0.99, Double(track.confidence) * found.score)
            if books[bookIndex].status == .needsAppraisal {
                books[bookIndex].idConfidence = Double(track.confidence)
            }
            log("identity", "\(trackID) \(found.title)")
            sayWhatWasLogged(books[bookIndex])
        case .hunch(let text):
            guard books[bookIndex].status != .identified else { return }
            books[bookIndex].status = .unidentified
            books[bookIndex].candidateTitle = text
            books[bookIndex].title = ""
            books[bookIndex].idConfidence = Double(track.confidence) * 0.4
            sayWhatWasLogged(books[bookIndex])
        case .unidentified:
            guard books[bookIndex].status == .unidentified, books[bookIndex].candidateTitle.isEmpty else { return }
            books[bookIndex].idConfidence = 0
        }
    }

    mutating func noteObject(_ item: ItemDraft) {
        if let index = items.firstIndex(where: { $0.category == item.category && abs($0.midX - item.midX) < 0.18 && abs($0.midY - item.midY) < 0.18 }) {
            if item.confidence > items[index].confidence { items[index] = item }
            return
        }
        items.append(item)
        log("item", item.category)
        if item.category == "framed art" {
            instruction = "Is that portrait an original or a print?"
        }
    }

    mutating func noteRoom(_ observation: RoomObservation) {
        room = observation
    }

    mutating func confirmLatestHunch() {
        guard let index = books.lastIndex(where: { $0.status == .unidentified && !$0.candidateTitle.isEmpty && !$0.excluded }) else { return }
        books[index].status = .identified
        books[index].title = books[index].candidateTitle
        books[index].author = books[index].candidateAuthor
        books[index].voiceConfirmed = true
        books[index].idConfidence = max(books[index].idConfidence, 0.9)
        log("confirm", books[index].id)
        setBase("Confirmed. \(books[index].title) is on the claim.")
    }

    mutating func markLatestFirstEdition() {
        guard let index = books.lastIndex(where: { !$0.excluded && ($0.status == .identified || !$0.candidateTitle.isEmpty) }) else { return }
        if books[index].title.isEmpty { books[index].title = books[index].candidateTitle }
        books[index].status = .needsAppraisal
        books[index].edition = "first edition"
        books[index].voiceConfirmed = true
        books[index].replacement = nil
        books[index].used = nil
        log("appraisal", books[index].id)
        setBase("First edition. I will not price it.")
    }

    mutating func skipCurrentShelf() {
        let shelf = books.max(by: { $0.observations < $1.observations })?.shelf ?? books.last?.shelf
        guard let shelf else { return }
        for index in books.indices where books[index].shelf == shelf {
            books[index].excluded = true
            books[index].excludeReason = "Policyholder skipped this shelf."
        }
        log("skip", shelf)
        setBase("That shelf is out of the totals.")
    }

    mutating func markLatestArt(isPrint: Bool) {
        guard let index = items.lastIndex(where: { $0.category == "framed art" }) else { return }
        if isPrint {
            items[index].description = "Print, confirmed by the policyholder. No listing yet."
            items[index].status = .needsAppraisal
            log("print", items[index].id)
            setBase("Print. It stays unpriced until there is a listing.")
        } else {
            items[index].status = .needsAppraisal
            items[index].description = "Original, confirmed by the policyholder."
            log("original", items[index].id)
            setBase("Original. It needs a person.")
        }
    }

    mutating func beginFinishing() {
        phase = .finishing
        endedAt = Date()
        setBase("Hold on. I am pricing what I could identify.")
        log("phase", "finishing")
    }

    mutating func applyPrices(_ updates: [PriceUpdate]) {
        for update in updates {
            guard let index = books.firstIndex(where: { $0.id == update.bookID }) else { continue }
            if books[index].status == .needsAppraisal || books[index].excluded { continue }
            if let replacement = update.replacement, isOverThreshold(replacement) {
                books[index].status = .needsAppraisal
                books[index].replacement = nil
                books[index].used = nil
                continue
            }
            if let used = update.used, isOverThreshold(used) {
                books[index].status = .needsAppraisal
                books[index].replacement = nil
                books[index].used = nil
                continue
            }
            books[index].replacement = update.replacement
            books[index].used = update.used
            books[index].euroReplacement = update.euroReplacement
            books[index].euroUsed = update.euroUsed
        }
    }

    mutating func finishSummary(version: Int) -> ClaimPacket {
        phase = .summary
        let packet = PacketBuilder.build(from: self, version: version)
        let line = PacketBuilder.summary(for: packet)
        setBase(line)
        log("summary", line)
        return packet
    }

    mutating func addTiming(_ timing: StageTiming) {
        timings.append(timing)
    }

    func snapshot(version: Int) -> WalkSnapshot {
        WalkSnapshot(
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: endedAt,
            device: device,
            settings: settings,
            scale: scale,
            books: books,
            items: items,
            room: room,
            timings: timings,
            practice: practice,
            version: version
        )
    }

    func tracksNeedingLookup() -> [SpineTrack] {
        tracks.filter { track in
            guard track.observations >= 1, !track.text.isEmpty else { return false }
            guard let book = books.first(where: { $0.id == track.id }) else { return true }
            return book.status == .unidentified && book.candidateTitle.isEmpty == false && book.title.isEmpty && book.observations < 8 && !book.voiceConfirmed
        }
    }

    private mutating func rebuildBooks() {
        for track in tracks {
            let shelf = "shelf-\(track.shelf)"
            if let index = books.firstIndex(where: { $0.id == track.id }) {
                books[index].shelf = shelf
                books[index].midX = track.midX
                books[index].spineHeightCm = track.heightCm
                books[index].spineThicknessCm = track.thicknessCm
                let hint = BindingHint.from(thicknessCm: track.thicknessCm)
                if !hint.isEmpty { books[index].bindingHint = hint }
                books[index].frameRef = track.frameRef
                books[index].observations = track.observations
                if books[index].status == .identified, !books[index].voiceConfirmed, !MeasureMath.titleAgrees(books[index].title, track.text) {
                    books[index].status = .unidentified
                    books[index].title = ""
                    books[index].author = ""
                    books[index].isbn = ""
                    books[index].publisher = ""
                    books[index].candidateTitle = track.text
                    books[index].idConfidence = Double(track.confidence) * 0.4
                }
                if books[index].status == .unidentified, books[index].title.isEmpty, !track.text.isEmpty, !books[index].voiceConfirmed {
                    let decision = MeasureMath.decideIdentity(text: track.text, ocrConfidence: track.confidence, match: nil)
                    if case .hunch(let text) = decision {
                        books[index].candidateTitle = text
                        books[index].idConfidence = Double(track.confidence) * 0.4
                    }
                }
            } else {
                let decision = MeasureMath.decideIdentity(text: track.text, ocrConfidence: track.confidence, match: nil)
                var draft = BookDraft(
                    id: track.id,
                    shelf: shelf,
                    position: 0,
                    frameRef: track.frameRef,
                    status: .unidentified,
                    title: "",
                    author: "",
                    edition: "",
                    isbn: "",
                    publisher: "",
                    candidateTitle: "",
                    candidateAuthor: "",
                    spineHeightCm: track.heightCm,
                    spineThicknessCm: track.thicknessCm,
                    idConfidence: 0,
                    voiceConfirmed: false,
                    excluded: false,
                    excludeReason: "",
                    firstPublishYear: nil,
                    replacement: nil,
                    used: nil,
                    euroReplacement: nil,
                    euroUsed: nil,
                    midX: track.midX,
                    observations: track.observations
                )
                if case .hunch(let text) = decision {
                    draft.candidateTitle = text
                    draft.idConfidence = Double(track.confidence) * 0.4
                }
                books.append(draft)
                sayWhatWasLogged(draft)
            }
        }
    }

    private mutating func sayWhatWasLogged(_ book: BookDraft) {
        guard !quiet else { return }
        guard phase == .sweeping || practice else { return }
        if let lastIssueAt, Date().timeIntervalSince(lastIssueAt) < 4 { return }
        let key: String
        let line: String
        if book.status == .identified, !book.title.isEmpty {
            key = "id:\(book.id):\(book.title)"
            line = "Logged \(book.title)."
        } else if !book.candidateTitle.isEmpty {
            key = "hunch:\(book.id):\(book.candidateTitle)"
            line = "Hunch. \(book.candidateTitle). Not priced until you confirm."
        } else {
            key = "unread:\(book.id)"
            let height = book.spineHeightCm.map { String(format: "%.0f", $0) } ?? "unknown"
            let thick = book.spineThicknessCm.map { String(format: "%.0f", $0) } ?? "unknown"
            line = "Unidentified spine, \(height) by \(thick) centimetres. Step closer and hold still."
        }
        let identified = book.status == .identified && !book.title.isEmpty
        if !identified, let lastCueAt, Date().timeIntervalSince(lastCueAt) < 3 { return }
        guard !said.contains(key) else { return }
        said.insert(key)
        lastCueAt = Date()
        instruction = line
    }

    private func appraisalStatus(year: Int?, title: String) -> LineStatus? {
        let lower = title.lowercased()
        if lower.contains("signed") || lower.contains("limited") || lower.contains("first edition") {
            return .needsAppraisal
        }
        if let year, year < 1850 { return .needsAppraisal }
        return nil
    }

    private func isOverThreshold(_ money: SourcedMoney) -> Bool {
        guard settings.currency.uppercased() == "USD" else { return false }
        guard let amount = money.amount, !money.converted else { return false }
        return amount >= settings.appraisalThreshold
    }

    private mutating func setBase(_ text: String) {
        baseInstruction = text
        instruction = text
    }

    private mutating func log(_ kind: String, _ detail: String) {
        logs.append(WalkLog(at: Date(), kind: kind, detail: detail))
    }
}

enum QualityIssue {
    case blur
    case glare
    case movingTooFast
    case passedShelf
}

struct PriceUpdate {
    var bookID: String
    var replacement: SourcedMoney?
    var used: SourcedMoney?
    var euroReplacement: SourcedMoney?
    var euroUsed: SourcedMoney?
}
