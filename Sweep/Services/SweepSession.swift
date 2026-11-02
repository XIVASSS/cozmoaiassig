import ARKit
import Foundation
import UIKit

private enum ShelfAim {
    case finding
    case confirm
    case reading
    case done
}

@MainActor
final class SweepSession: ObservableObject, Identifiable {
    let id = UUID()
    let practice: Bool
    @Published var engine = WalkEngine()
    @Published var packet: ClaimPacket?
    @Published var cameraReady = false
    @Published var cue: ScanCue = .none
    @Published var spineMarks: [NormBox] = []
    @Published var focusMark: NormBox?
    @Published var ringProgress = 0.2
    @Published var showRings = false
    @Published var reading = false
    private var cursor = SpineCursor()
    private var aim: ShelfAim = .finding
    private var goodSince: Date?
    private var reveal: Task<Void, Never>?
    private var shelfQueue: [SpineHit] = []
    private var shelfIndex = 0
    private var aimSpokenAt = Date.distantPast
    private var smoothedColumns = 0.0
    private var lowSince: Date?
    private var expectedShelves: Int?
    private var expectedBooks: Int?
    private var guessedShelves = 1
    private var countConfirmed = false
    private var closerPasses = 0
    private var directed = false
    private var showedShelf = 0
    private var speechReadyAt = Date.distantPast
    private var heldLine: String?
    private var reporting = false
    private var scanID = 0
    let capture = SweepCapture()
    private let voice = VoiceBridge()
    private let store: SessionStore
    private let pricing = PricingService()
    private var lastSpoken = ""
    private var questionsSpoken = 0
    private var locator: PlaceLocator?
    private var lookedUp = Set<String>()
    private var savedFrames = 0
    private var lookupTask: Task<Void, Never>?
    private var finishingWalk = false

    init(settings: WalkSettings, store: SessionStore, practice: Bool) {
        self.practice = practice
        self.store = store
        let sessionID = practice ? "practice-\(UUID().uuidString.prefix(8))" : UUID().uuidString
        store.makeSession(id: sessionID)
        engine.begin(sessionID: sessionID, settings: settings, device: practice ? "practice-replay" : Self.deviceName, practice: practice)
        if !practice {
            engine.enterDirectedSweep()
        }
        store.save(summary: summary(phase: practice ? "practice" : "walking"), logs: [])
    }

    func start() {
        if !practice {
            engine.enterDirectedSweep()
            listenForPlace()
        }
        speakIfNeeded()
        guard !practice else { return }
        cameraReady = ARWorldTrackingConfiguration.isSupported
        guard cameraReady else { return }
        capture.onTick = { [weak self] tick in
            Task { @MainActor in self?.apply(tick) }
        }
        capture.start()
        guard !engine.quiet else { return }
        voice.start { [weak self] text in
            Task { @MainActor in await self?.heard(text) }
        }
    }

    func runPractice() async {
        let settings = engine.settings
        engine = PracticeWalk.make(sessionID: engine.sessionID, settings: settings)
        writePracticeFrame()
        engine.beginFinishing()
        let started = Date()
        let updates = await pricing.price(books: engine.books, settings: engine.settings)
        engine.applyPrices(updates)
        engine.addTiming(StageTiming(stage: "pricing", milliseconds: milliseconds(since: started)))
        let built = engine.finishSummary(version: 1)
        packet = built
        try? store.savePacket(built, logs: engine.logs)
        speakIfNeeded()
    }

    func confirmCountry() {
        engine.confirmCountry()
        speakIfNeeded()
    }

    func confirmHunch() {
        engine.confirmLatestHunch()
        speakIfNeeded()
    }

    func firstEdition() {
        engine.markLatestFirstEdition()
        speakIfNeeded()
    }

    func skipShelf() {
        engine.skipCurrentShelf()
        speakIfNeeded()
    }

    func markPrint() {
        engine.markLatestArt(isPrint: true)
        speakIfNeeded()
    }

    func endWalk() async {
        reveal?.cancel()
        guard !finishingWalk else { return }
        guard engine.phase != .summary, engine.phase != .finishing else { return }
        finishingWalk = true
        reading = true
        if !engine.quiet {
            engine.say("Reading the saved frames.")
            speakIfNeeded()
        }
        capture.stop()
        voice.stop()
        let images = savedFrameImages()
        if !images.isEmpty {
            let hits = await capture.readImages(images, shelves: expectedShelves ?? 2, books: max(expectedBooks ?? 50, 50))
            if hits.count >= 4 {
                engine.replaceSpines(hits)
            }
        }
        reporting = true
        engine.beginFinishing()
        await finishLookups()
        engine.dropWeakHunches()
        reporting = false
        let started = Date()
        let updates = await pricing.price(books: engine.books, settings: engine.settings)
        engine.applyPrices(updates)
        engine.addTiming(StageTiming(stage: "pricing", milliseconds: milliseconds(since: started)))
        let version = store.packetVersions(id: engine.sessionID).count + 1
        let built = engine.finishSummary(version: version)
        packet = built
        try? store.savePacket(built, logs: engine.logs)
        speakIfNeeded()
    }

    func closeOpenWalk() {
        guard packet == nil else { return }
        capture.stop()
        voice.stop()
        store.save(summary: summary(phase: "open"), logs: engine.logs)
    }

    private func updateAim(columns: Int, sharp: Bool, moving: Bool) {
        switch aim {
        case .finding:
            showRings = true
            if engine.quiet {
                if sharp, !moving {
                    ringProgress = min(1, ringProgress + 0.08)
                } else if moving {
                    ringProgress = 0.35
                }
                return
            }
            smoothedColumns = smoothedColumns == 0 ? Double(columns) : smoothedColumns * 0.82 + Double(columns) * 0.18
            var progress = 0.18
            if smoothedColumns >= 7, sharp { progress = 1 }
            else if smoothedColumns >= 4, sharp { progress = 0.7 }
            else if smoothedColumns >= 2 { progress = 0.4 }
            if moving { progress = min(progress, 0.45) }
            if progress >= ringProgress {
                ringProgress = progress
            }
            if progress >= 0.95 {
                lowSince = nil
                if goodSince == nil {
                    goodSince = Date()
                    aimSay("Hold there.")
                }
                if let goodSince, Date().timeIntervalSince(goodSince) > 1.2 {
                    lockShelf()
                }
            } else if progress < 0.45 {
                if lowSince == nil { lowSince = Date() }
                if let lowSince, Date().timeIntervalSince(lowSince) > 1.6 {
                    goodSince = nil
                    ringProgress = progress
                    aimSay("Step closer.")
                }
            } else {
                lowSince = nil
            }
        case .confirm, .reading, .done:
            showRings = false
        }
    }

    private func aimSay(_ line: String, force: Bool = false) {
        guard !engine.quiet else { return }
        guard engine.instruction != line else { return }
        if !force, Date().timeIntervalSince(aimSpokenAt) < 5 { return }
        aimSpokenAt = Date()
        engine.say(line)
    }

    private func lockShelf() {
        showRings = false
        goodSince = nil
        focusMark = nil
        spineMarks = []
        startScan()
    }

    private func startScan() {
        scanID += 1
        let id = scanID
        aim = .reading
        showRings = false
        let shelves = expectedShelves ?? guessedShelves
        let books = expectedBooks ?? max(shelves * 12, 16)
        Task { [weak self] in
            guard let self else { return }
            let hits = await self.capture.readLockedShelf(shelves: shelves, books: books)
            await MainActor.run {
                guard self.scanID == id, self.aim == .reading else { return }
                self.beginReading(hits)
            }
        }
    }

    private func beginReading(_ hits: [SpineHit]) {
        guard aim == .reading else { return }
        let budget = min(36, expectedBooks ?? 30)
        let limited = Array(hits.prefix(budget + 2))
        let blanks = limited.filter { $0.text.isEmpty }
        let keepBlanks = blanks.count <= 8
        let fresh = limited.filter { hit in
            if hit.text.isEmpty { return keepBlanks && engine.books.isEmpty }
            let title = hit.text.lowercased()
            return !engine.books.contains { book in
                let known = (book.title.isEmpty ? book.candidateTitle : book.title).lowercased()
                return !known.isEmpty && MeasureMath.jaccard(known, title) > 0.55
            }
        }
        let readable = fresh.filter { $0.text.count >= 4 }
        let alreadyNamed = engine.books.contains { !$0.title.isEmpty || !$0.candidateTitle.isEmpty }
        guard readable.count >= 3 || alreadyNamed else {
            aim = .finding
            showRings = true
            goodSince = nil
            ringProgress = 0.2
            engine.say(WalkEngine.softFrame)
            speakIfNeeded()
            return
        }
        for hit in fresh where !hit.text.isEmpty || keepBlanks {
            engine.noteSpines([hit])
        }
        focusMark = nil
        aim = .finding
        showRings = true
        goodSince = nil
        ringProgress = 0.2
        engine.say("Logged. Keep walking.")
        speakIfNeeded()
        Task { await self.finishLookups() }
    }

    private func askForAnotherLook(shelf: Int, names: String, book: Int? = nil) {
        closerPasses += 1
        if closerPasses > 1 {
            aim = .done
            showRings = false
            let detail = book.map { " Shelf \(shelf), book \($0) is still blank." } ?? ""
            engine.say("\(shelfWords(expectedShelves ?? guessedShelves)). I can read \(names).\(detail)")
            return
        }
        aim = .finding
        showRings = true
        smoothedColumns = 0
        goodSince = nil
        ringProgress = 0.2
        capture.releaseShelfStill()
        let lead = names.isEmpty ? shelfWords(expectedShelves ?? guessedShelves) : "\(shelfWords(expectedShelves ?? guessedShelves)). I can read \(names)."
        if let book {
            engine.say("\(lead) Shelf \(shelf), book \(book). Unidentified spine.")
        } else {
            engine.say("\(lead) \(WalkEngine.softFrame)")
        }
    }

    private func spokenNames(from titles: [String]) -> String {
        var unique: [String] = []
        for title in titles where title.count >= 4 {
            if unique.contains(where: { MeasureMath.jaccard($0, title) > 0.55 }) { continue }
            unique.append(title)
        }
        if unique.count <= 3 { return unique.joined(separator: ", ") }
        return unique.prefix(2).joined(separator: ", ") + ", and \(unique.count - 2) more"
    }

    private func firstGap(in hits: [SpineHit]) -> (shelf: Int, number: Int)? {
        let groups = Dictionary(grouping: hits, by: \.shelf)
        for shelf in groups.keys.sorted() {
            let row = groups[shelf, default: []].sorted { $0.midX < $1.midX }
            if let index = row.firstIndex(where: { $0.text.isEmpty }) {
                return (shelf + 1, index + 1)
            }
        }
        return nil
    }

    private func weakestShelf(in hits: [SpineHit]) -> Int {
        let groups = Dictionary(grouping: hits, by: \.shelf)
        let weak = groups.min { $0.value.count < $1.value.count }
        return (weak?.key ?? 0) + 1
    }

    private func shelfWords(_ count: Int) -> String {
        switch count {
        case 1: return "One shelf"
        case 2: return "Two shelves"
        default: return "\(count) shelves"
        }
    }

    private func revealNext() {
        guard aim == .reading else { return }
        guard shelfIndex < shelfQueue.count else {
            focusMark = nil
            let count = engine.books.filter { !$0.excluded }.count
            if count < 18 {
                aim = .finding
                showRings = true
                capture.releaseShelfStill()
                engine.say("I have \(count). There are more. Step closer and hold.")
            } else {
                aim = .done
                engine.say("Those shelves are read.")
            }
            speakIfNeeded()
            return
        }
        let hit = shelfQueue[shelfIndex]
        if shelfIndex > 0, hit.shelf != shelfQueue[shelfIndex - 1].shelf {
            engine.say("Shelf \(shelfQueue[shelfIndex - 1].shelf + 1) is done.")
            speakIfNeeded()
        }
        focusMark = hit.box
        let known = Set(engine.books.map(\.id))
        engine.noteSpines([hit])
        let bookID = engine.books.last(where: { !known.contains($0.id) })?.id
        let index = shelfIndex
        shelfIndex += 1
        reveal = Task { [weak self] in
            await self?.describe(hit, index: index, bookID: bookID)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.revealNext() }
        }
    }

    private func describe(_ hit: SpineHit, index: Int, bookID: String?) async {
        let shelf = hit.shelf + 1
        let position = shelfQueue.prefix(index + 1).filter { $0.shelf == hit.shelf }.count
        if let bookID, !hit.text.isEmpty {
            let binding = BindingHint.from(thicknessCm: hit.thicknessCm)
            let match = await CatalogueClient().search(text: hit.text, binding: binding)
            engine.resolve(trackID: bookID, match: match)
            if let book = engine.books.first(where: { $0.id == bookID }), book.status == .identified, !book.title.isEmpty {
                let quote = await pricing.quote(
                    title: book.title,
                    author: book.author,
                    isbn: book.isbn,
                    currency: engine.settings.currency,
                    country: engine.settings.country,
                    binding: book.bindingHint
                )
                engine.applyPrices([PriceUpdate(bookID: bookID, replacement: quote.replacement, used: quote.used, euroReplacement: nil, euroUsed: nil)])
            }
        }
        guard aim == .reading else { return }
        guard let book = bookID.flatMap({ id in engine.books.first(where: { $0.id == id }) }) else { return }
        let name: String
        if book.status == .identified, !book.title.isEmpty {
            name = book.title
        } else if !book.candidateTitle.isEmpty {
            name = book.candidateTitle
        } else if !hit.text.isEmpty {
            name = hit.text
        } else {
            name = "Unidentified"
        }
        var line = "Shelf \(shelf), book \(position). \(name)."
        if hit.text.isEmpty || name == "Unidentified" {
            line = "Shelf \(shelf), book \(position). Unidentified spine."
        } else if book.status == .unidentified, !book.candidateTitle.isEmpty {
            line = "Hunch. \(book.candidateTitle). Not priced until you confirm."
        } else if book.status == .identified, let amount = book.replacement?.amount {
            line += " \(Int(amount.rounded())) \(engine.settings.currency)."
        }
        engine.say(line)
        speakIfNeeded()
    }

    private func fileRemainingSpines() {
        let pending = shelfIndex < shelfQueue.count ? Array(shelfQueue.dropFirst(shelfIndex)) : []
        for hit in pending where !hit.text.isEmpty {
            engine.noteSpines([hit])
        }
    }

    private func finishLookups() async {
        for _ in 0..<4 {
            lookupNewSpines()
            for _ in 0..<500 {
                if lookupTask == nil { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            let pending = engine.tracksNeedingLookup().filter { !lookedUp.contains("\($0.id)|\($0.text)") }
            if pending.isEmpty { return }
        }
    }

    private func apply(_ tick: CaptureTick) {
        if let card = tick.card, !engine.scale.locked {
            engine.noteCard(millimetresPerPixel: card.millimetresPerPixel, distanceM: card.distanceM, arkitCardMeters: card.arkitCardMeters)
        }
        if let quality = tick.quality {
            engine.noteQuality(quality)
        }
        if engine.phase == .sweeping {
            updateAim(columns: tick.columns, sharp: tick.sharp, moving: tick.quality == .movingTooFast)
        }
        if let item = tick.item {
            engine.noteObject(item)
        }
        if var room = tick.room {
            room.shelfFaceAreaM2 = shelfFaceArea()
            engine.noteRoom(room)
        }
        if let data = tick.frameJPEG, let name = tick.frameName, savedFrames < 160 {
            _ = store.saveFrame(data, sessionID: engine.sessionID, name: name)
            savedFrames += 1
        }
        if aim == .finding { lookupNewSpines() }
        speakIfNeeded()
    }

    private func heard(_ text: String) async {
        guard !engine.quiet else { return }
        engine.noteHeard(text)
        let spoken = engine.instruction.lowercased()
        let plan = CorrectionParser.expectation(text)
        let statesCount = plan.shelves != nil || plan.books != nil
        let heardWords = MeasureMath.tokens(text)
        let spokenWords = Set(MeasureMath.tokens(spoken))
        if !statesCount, !heardWords.isEmpty, heardWords.allSatisfy({ spokenWords.contains($0) }) { return }
        if !statesCount, !spoken.isEmpty, MeasureMath.jaccard(spoken, text) > 0.45 { return }
        let line = text.lowercased()
        if line.contains("both"), line.contains("shelf") || line.contains("cell") || line.contains("elve") || line.contains("shell") {
            showedShelf = max(showedShelf, expectedShelves ?? 2)
            engine.say("I have both shelves.")
            speakIfNeeded()
            return
        }
        if line.contains("pointed") || line.contains("showing") {
            if let shelf = CorrectionParser.shownShelf(text), shelf > showedShelf { showedShelf = shelf }
            let want = expectedShelves ?? 2
            engine.say(showedShelf < want ? "Show me the other shelf." : "I have both shelves.")
            speakIfNeeded()
            return
        }
        if aim == .confirm {
            let agrees = line == "yes" || line == "yeah" || line == "yep" || line == "right" || line == "correct" || line.contains("that is right") || line.contains("thats right")
            if agrees {
                expectedShelves = expectedShelves ?? guessedShelves
                countConfirmed = true
                engine.say("\(shelfWords(expectedShelves ?? guessedShelves)).")
                speakIfNeeded()
                startScan()
                return
            }
        }
        if plan.shelves != nil || plan.books != nil {
            if let shelves = plan.shelves { expectedShelves = shelves }
            if let books = plan.books { expectedBooks = books }
            countConfirmed = true
            let shelves = expectedShelves ?? guessedShelves
            if let books = expectedBooks {
                engine.say("\(shelfWords(shelves)). About \(books) books.")
            } else {
                engine.say("\(shelfWords(shelves)).")
            }
            speakIfNeeded()
            if aim != .finding { startScan() }
            return
        }
        if aim == .confirm, line == "no" || line.hasPrefix("no ") {
            engine.say(WalkEngine.opening)
            speakIfNeeded()
            return
        }
        let correction = await IntentClassifier.classify(text)
        guard correction != .none else { return }
        switch correction {
        case .countryUSD: engine.confirmCountry()
        case .confirmHunch: engine.confirmLatestHunch()
        case .firstEdition: engine.markLatestFirstEdition()
        case .skipShelf: engine.skipCurrentShelf()
        case .isPrint: engine.markLatestArt(isPrint: true)
        case .isOriginal: engine.markLatestArt(isPrint: false)
        case .moreBooks: keepLooking(closer: false)
        case .closer: keepLooking(closer: true)
        case .none: break
        }
        speakIfNeeded()
    }

    private func keepLooking(closer: Bool) {
        reveal?.cancel()
        aim = .finding
        showRings = true
        goodSince = nil
        focusMark = nil
        capture.releaseShelfStill()
        smoothedColumns = 0
        engine.say(closer ? "Come closer, and hold." : "Hold there.")
    }

    private func lookupNewSpines() {
        guard lookupTask == nil else { return }
        let pending = engine.tracksNeedingLookup().filter { !lookedUp.contains("\($0.id)|\($0.text)") }
        guard !pending.isEmpty else { return }
        for track in pending { lookedUp.insert("\(track.id)|\(track.text)") }
        lookupTask = Task { [pending] in
            let client = CatalogueClient()
            let width = min(6, pending.count)
            await withTaskGroup(of: (String, CatalogueMatch?).self) { group in
                func search(_ index: Int) {
                    let track = pending[index]
                    group.addTask {
                        let match = await client.search(text: track.text, binding: BindingHint.from(thicknessCm: track.thicknessCm))
                        return (track.id, match)
                    }
                }
                for index in 0..<width { search(index) }
                var next = width
                while let found = await group.next() {
                    let report = await MainActor.run { self.reporting }
                    await MainActor.run { self.engine.resolve(trackID: found.0, match: found.1, report: report) }
                    if next < pending.count {
                        search(next)
                        next += 1
                    }
                }
            }
            await MainActor.run { self.lookupTask = nil }
        }
    }

    private func shelfFaceArea() -> Double? {
        let groups = Dictionary(grouping: engine.books.filter { !$0.excluded }, by: \.shelf)
        var area = 0.0
        var any = false
        for books in groups.values {
            let thickness = books.compactMap(\.spineThicknessCm).reduce(0, +) / 100
            let height = (books.compactMap(\.spineHeightCm).max() ?? 0) / 100
            if thickness > 0, height > 0 {
                area += thickness * height
                any = true
            }
        }
        return any ? area : nil
    }

    private func listenForPlace() {
        let locator = PlaceLocator()
        self.locator = locator
        locator.start()
        Task { [weak self] in
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                if locator.ready {
                    self.engine.adoptPlace(country: locator.country, currency: locator.currency)
                    return
                }
            }
        }
    }

    private func speakIfNeeded() {
        guard !engine.quiet else { return }
        let line = engine.instruction
        guard !line.isEmpty, line != lastSpoken, canSay(line) else { return }
        if Date() < speechReadyAt {
            if heldLine == nil { heldLine = line }
            let delay = speechReadyAt.timeIntervalSinceNow
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
                await MainActor.run { self?.releaseHeldLine() }
            }
            return
        }
        utter(line)
    }

    private func releaseHeldLine() {
        guard Date() >= speechReadyAt, let line = heldLine, line != lastSpoken else { return }
        heldLine = nil
        guard canSay(line) else { return }
        utter(line)
    }

    private func utter(_ line: String) {
        if asksSomething(line) { questionsSpoken += 1 }
        lastSpoken = line
        speechReadyAt = Date().addingTimeInterval(4)
        voice.speak(line)
    }

    /// A whole walk asks at most twice. Status lines still get said.
    private func canSay(_ line: String) -> Bool {
        !asksSomething(line) || questionsSpoken < 2
    }

    private func asksSomething(_ line: String) -> Bool {
        let text = line.lowercased()
        if text.hasPrefix("hold on") { return false }
        let prompts = [
            "hold there", "hold still", "step closer", "come closer", "show me",
            "country", "currency", "bank card", "pan back", "back half", "how many"
        ]
        return prompts.contains { text.contains($0) }
    }

    private func savedFrameImages() -> [CIImage] {
        let files = store.frameFiles(id: engine.sessionID)
        guard !files.isEmpty else { return [] }
        let sized = files.map { url -> (URL, Int) in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return (url, size)
        }
        let buckets = min(12, sized.count)
        let chunk = max(1, sized.count / buckets)
        var picked: [URL] = []
        for bucket in 0..<buckets {
            let start = bucket * chunk
            let end = bucket == buckets - 1 ? sized.count : min(sized.count, (bucket + 1) * chunk)
            guard start < end else { continue }
            if let best = sized[start..<end].max(by: { $0.1 < $1.1 }) {
                picked.append(best.0)
            }
        }
        var images: [CIImage] = []
        for url in picked {
            guard let data = try? Data(contentsOf: url),
                  let picture = UIImage(data: data),
                  let image = CIImage(image: picture) else { continue }
            images.append(image)
        }
        return images
    }

    private func summary(phase: String) -> SessionSummary {
        SessionSummary(
            id: engine.sessionID,
            capturedAt: engine.snapshot(version: 0).startedAt,
            practice: practice,
            phase: phase,
            bookCount: engine.books.filter { !$0.excluded }.count,
            floorAreaM2: nil,
            reviewCount: 0,
            packetVersion: 0,
            country: engine.settings.country,
            currency: engine.settings.currency
        )
    }

    private func writePracticeFrame() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32))
        let data = renderer.jpegData(withCompressionQuality: 0.8) { context in
            UIColor(red: 0.059, green: 0.063, blue: 0.067, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        _ = store.saveFrame(data, sessionID: engine.sessionID, name: "practice.jpg")
    }

    private func milliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    private static var deviceName: String {
        "\(UIDevice.current.model) \(UIDevice.current.systemVersion)"
    }
}
