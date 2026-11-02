import XCTest
@testable import Sweep

final class SweepRulesTests: XCTestCase {
    func testCardRejectsASquareAndMeasuresAnID1Card() {
        XCTAssertNil(MeasureMath.millimetresPerPixel(longSidePx: 100, shortSidePx: 100))
        let mm = MeasureMath.millimetresPerPixel(longSidePx: 856, shortSidePx: 539.8)
        XCTAssertEqual(mm ?? 0, 0.1, accuracy: 0.001)
    }

    func testCardCorrectionIsNotAnAverage() {
        let decision = MeasureMath.scaleDecision(arkitCardMeters: 0.1, threshold: 0.08)
        XCTAssertNotNil(decision)
        XCTAssertEqual(decision?.correction ?? 0, 0.856, accuracy: 0.001)
        XCTAssertTrue(decision?.flagged ?? false)
        let corrected = MeasureMath.apply(correction: decision?.correction ?? 1, meters: 4)
        let average = (4 + 4 * 0.856) / 2
        XCTAssertEqual(corrected, 3.424, accuracy: 0.01)
        XCTAssertNotEqual(corrected, average, accuracy: 0.05)
    }

    func testSharpImageScoresHigherThanAFlatOne() {
        let flat = [UInt8](repeating: 40, count: 40 * 40)
        var sharp = [UInt8](repeating: 10, count: 40 * 40)
        for y in 0..<40 {
            sharp[y * 40 + 20] = 250
        }
        XCTAssertGreaterThan(
            MeasureMath.blurScore(luma: sharp, width: 40, height: 40),
            MeasureMath.blurScore(luma: flat, width: 40, height: 40)
        )
    }

    func testIdentityStaysAHunchWithoutCatalogueAgreement() {
        XCTAssertEqual(MeasureMath.decideIdentity(text: "", ocrConfidence: 0.9, match: nil), .unidentified)
        XCTAssertEqual(
            MeasureMath.decideIdentity(text: "Moby", ocrConfidence: 0.9, match: nil),
            .hunch("Moby")
        )
        let match = CatalogueMatch(title: "The Odyssey", author: "Homer", isbn: "9780140268867", publisher: "Penguin", firstPublishYear: nil, score: 0.2)
        if case .hunch = MeasureMath.decideIdentity(text: "The Odyssey", ocrConfidence: 0.9, match: match) {
        } else {
            XCTFail("A weak catalogue score must stay a hunch")
        }
    }

    func testCatalogueAgreementCanIdentify() {
        let match = CatalogueMatch(title: "The Odyssey", author: "Homer", isbn: "9780140268867", publisher: "Penguin", firstPublishYear: nil, score: 0.9)
        guard case .identified(let found) = MeasureMath.decideIdentity(text: "The Odyssey", ocrConfidence: 0.8, match: match) else {
            return XCTFail("Expected an identified work")
        }
        XCTAssertEqual(found.title, "The Odyssey")
    }

    func testParser() {
        XCTAssertEqual(CorrectionParser.parse("United States, dollars"), .countryUSD)
        XCTAssertEqual(CorrectionParser.parse("yes, that one"), .confirmHunch)
        XCTAssertEqual(CorrectionParser.parse("that is a first edition"), .firstEdition)
        XCTAssertEqual(CorrectionParser.parse("skip that shelf, those are not mine"), .skipShelf)
        XCTAssertEqual(CorrectionParser.parse("it is a print"), .isPrint)
        XCTAssertEqual(CorrectionParser.parse("what time is it"), .none)
    }

    func testDedupKeepsOneBook() {
        let first = SpineHit(text: "The Odyssey", shelf: 1, midX: 0.20, heightCm: 20, thicknessCm: 3, confidence: 0.8, frameRef: "frames/a.jpg")
        let second = SpineHit(text: "The Odyssey", shelf: 1, midX: 0.22, heightCm: 20.4, thicknessCm: 3.1, confidence: 0.9, frameRef: "frames/b.jpg")
        let other = SpineHit(text: "Bleak House", shelf: 1, midX: 0.70, heightCm: 19, thicknessCm: 4, confidence: 0.8, frameRef: "frames/b.jpg")
        var tracks = SpineTracker.merge(tracks: [], hits: [first])
        tracks = SpineTracker.merge(tracks: tracks, hits: [second, other])
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks.first { $0.text == "The Odyssey" }?.observations, 2)
    }

    func testACoverAndAScreenAreNotBooks() {
        let cover = NormBox(x: 0.18, y: 0.22, width: 0.52, height: 0.48)
        let coverLines = [
            CoverLine(text: "Why I Am so Clever", box: NormBox(x: 0.40, y: 0.36, width: 0.16, height: 0.14), confidence: 0.8)
        ]
        XCTAssertEqual(CoverReading.reads(rectangles: [cover], lines: coverLines).count, 0)
        var screenLines: [CoverLine] = []
        for index in 0..<8 {
            screenLines.append(CoverLine(
                text: "Make both home cards smaller and rounder",
                box: NormBox(x: 0.1, y: 0.2 + Double(index) * 0.04, width: 0.55, height: 0.03),
                confidence: 0.9
            ))
        }
        let screen = NormBox(x: 0.05, y: 0.15, width: 0.7, height: 0.45)
        XCTAssertEqual(CoverReading.reads(rectangles: [screen], lines: screenLines).count, 0)
    }

    func testASpineKeepsTheTitleAndDropsTheAuthor() {
        let spine = NormBox(x: 0.42, y: 0.12, width: 0.07, height: 0.64)
        let lines = [
            CoverLine(text: "Friedrich Nietzsche", box: NormBox(x: 0.43, y: 0.22, width: 0.05, height: 0.12), confidence: 0.9),
            CoverLine(text: "Why I Am so Clever", box: NormBox(x: 0.43, y: 0.42, width: 0.05, height: 0.18), confidence: 0.8)
        ]
        let reads = CoverReading.reads(rectangles: [spine], lines: lines)
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(reads.first?.title, "Why I Am so Clever")
    }

    func testSeparatedSpinesStaySeparateBooks() {
        let left = NormBox(x: 0.08, y: 0.2, width: 0.07, height: 0.5)
        let right = NormBox(x: 0.62, y: 0.2, width: 0.07, height: 0.5)
        let lines = [
            CoverLine(text: "The Odyssey", box: NormBox(x: 0.08, y: 0.4, width: 0.06, height: 0.2), confidence: 0.8),
            CoverLine(text: "Bleak House", box: NormBox(x: 0.62, y: 0.4, width: 0.06, height: 0.2), confidence: 0.8)
        ]
        let reads = CoverReading.reads(rectangles: [left, right], lines: lines)
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(Set(reads.map(\.title)), ["The Odyssey", "Bleak House"])
    }

    func testABlankSpineIsOneUnknownBook() {
        let spine = NormBox(x: 0.4, y: 0.15, width: 0.06, height: 0.55)
        let reads = CoverReading.reads(rectangles: [spine], lines: [])
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(reads.first?.title, "")
    }

    func testShelfGoesTopToBottomThenLeftToRight() {
        func hit(_ text: String, _ x: Double, _ y: Double) -> SpineHit {
            SpineHit(text: text, shelf: 0, midX: x, heightCm: 20, thicknessCm: 3, confidence: 0.8, frameRef: "f", box: NormBox(x: x - 0.02, y: y - 0.08, width: 0.04, height: 0.16))
        }
        let ordered = ShelfOrder.arrange([
            hit("bottom-right", 0.70, 0.25),
            hit("top-right", 0.62, 0.78),
            hit("bottom-left", 0.20, 0.22),
            hit("top-left", 0.18, 0.80)
        ])
        XCTAssertEqual(ordered.map(\.text), ["top-left", "top-right", "bottom-left", "bottom-right"])
        XCTAssertEqual(ordered.map(\.shelf), [0, 0, 1, 1])
    }

    func testCursorReadsOneSpineThenTheNext() {
        func hit(_ text: String, _ x: Double) -> SpineHit {
            SpineHit(text: text, shelf: 0, midX: x, heightCm: 20, thicknessCm: 3, confidence: 0.8, frameRef: "f", box: NormBox(x: x - 0.02, y: 0.4, width: 0.04, height: 0.2))
        }
        let ordered = [hit("First", 0.2), hit("Second", 0.5)]
        var cursor = SpineCursor()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(cursor.step(ordered, now: start)?.text, "First")
        XCTAssertTrue(cursor.began)
        XCTAssertEqual(cursor.step(ordered, now: start.addingTimeInterval(1))?.text, "First")
        XCTAssertFalse(cursor.began)
        XCTAssertNil(cursor.step(ordered, now: start.addingTimeInterval(2.5)))
        XCTAssertEqual(cursor.step(ordered, now: start.addingTimeInterval(2.6))?.text, "Second")
        XCTAssertTrue(cursor.began)
    }

    func testOneSpineJoinsItsLinesAndTheNextBookStaysSeparate() {
        let lines = [
            CoverLine(text: "The Best American Poetry", box: NormBox(x: 0.20, y: 0.55, width: 0.03, height: 0.10), confidence: 0.8),
            CoverLine(text: "1998", box: NormBox(x: 0.205, y: 0.50, width: 0.02, height: 0.04), confidence: 0.7),
            CoverLine(text: "No More Masks", box: NormBox(x: 0.40, y: 0.54, width: 0.035, height: 0.1), confidence: 0.9)
        ]
        let columns = CoverReading.spineColumns(lines)
        XCTAssertEqual(columns.count, 2)
        XCTAssertTrue(columns.contains { $0.title.contains("Poetry") })
        XCTAssertTrue(columns.contains { $0.title.contains("Masks") })
    }

    func testSpeechCanAskForTheShelfThatWasMissed() {
        XCTAssertEqual(CorrectionParser.parse("there are more books"), .moreBooks)
        XCTAssertEqual(CorrectionParser.parse("you only identified one shelf there are two shelves"), .moreBooks)
        XCTAssertEqual(CorrectionParser.parse("go a little closer"), .closer)
        XCTAssertEqual(CorrectionParser.parse("The Best American Poetry"), .none)
        let plan = CorrectionParser.expectation("there are two shelves and 15 to 20 books")
        XCTAssertEqual(plan.shelves, 2, "\(String(describing: plan))")
        XCTAssertEqual(plan.books, 20, "\(String(describing: plan))")
        let pointed = CorrectionParser.expectation("I have pointed you to shelf one book one")
        XCTAssertNil(pointed.books, "\(String(describing: pointed))")
        XCTAssertEqual(CorrectionParser.shownShelf("I have pointed you to shelf one book one"), 1)
        XCTAssertEqual(CorrectionParser.expectation("there are two elves").shelves, 2)
    }

    func testEachBestAmericanVolumeStaysItsOwnBook() {
        var lines: [CoverLine] = []
        for index in 0..<8 {
            lines.append(CoverLine(
                text: "The Best American Poetry \(1993 + index)",
                box: NormBox(x: 0.2, y: 0.8 - Double(index) * 0.03, width: 0.2, height: 0.015),
                confidence: 0.8
            ))
        }
        XCTAssertEqual(CoverReading.reportBooks(lines).count, 8)
    }

    func testATitleStaysTogetherAndTheNextSpineDoesNot() {
        let lines = [
            CoverLine(text: "Collected Poems of", box: NormBox(x: 0.2, y: 0.50, width: 0.2, height: 0.012), confidence: 0.9),
            CoverLine(text: "EMILY DICKINSON", box: NormBox(x: 0.2, y: 0.482, width: 0.2, height: 0.012), confidence: 0.9),
            CoverLine(text: "Robert Duncan Bending the Bow", box: NormBox(x: 0.2, y: 0.42, width: 0.24, height: 0.014), confidence: 0.9),
            CoverLine(text: "Alabanza Martin Espada", box: NormBox(x: 0.2, y: 0.36, width: 0.22, height: 0.014), confidence: 0.9),
            CoverLine(text: "Beowulf Seamus Heaney", box: NormBox(x: 0.2, y: 0.30, width: 0.22, height: 0.014), confidence: 0.9)
        ]
        let books = CoverReading.reportBooks(lines)
        XCTAssertEqual(books.count, 4)
        XCTAssertTrue(books.contains { $0.title.localizedCaseInsensitiveContains("Collected") && $0.title.localizedCaseInsensitiveContains("Dickinson") })
        XCTAssertTrue(books.contains { $0.title.localizedCaseInsensitiveContains("Bending") })
        let named = [
            CoverLine(text: "Pandora's Jar", box: NormBox(x: 0.2, y: 0.50, width: 0.2, height: 0.012), confidence: 0.9),
            CoverLine(text: "Natalie Haynes", box: NormBox(x: 0.2, y: 0.475, width: 0.2, height: 0.012), confidence: 0.9),
            CoverLine(text: "THE SPARTANS", box: NormBox(x: 0.2, y: 0.43, width: 0.2, height: 0.012), confidence: 0.9),
            CoverLine(text: "THE AMAZONS", box: NormBox(x: 0.2, y: 0.39, width: 0.2, height: 0.012), confidence: 0.9),
            CoverLine(text: "PAX ROMANA", box: NormBox(x: 0.2, y: 0.35, width: 0.2, height: 0.012), confidence: 0.9)
        ]
        let shelf = CoverReading.reportBooks(named)
        XCTAssertEqual(shelf.count, 4)
        XCTAssertTrue(shelf.contains { $0.title.localizedCaseInsensitiveContains("Pandora") && $0.title.localizedCaseInsensitiveContains("Haynes") })
        XCTAssertFalse(shelf.contains { $0.title.localizedCaseInsensitiveContains("Spartans") && $0.title.localizedCaseInsensitiveContains("Amazons") })
    }

    func testTwoStacksOnOneScreenStayTwoColumns() {
        var lines: [CoverLine] = []
        let left = ["THE AMAZONS", "GODS AND ROBOTS", "THE SPARTANS", "Pandora's Jar Natalie Haynes"]
        let right = ["BLACK SPARTACUS", "BATTLE CRY OF FREEDOM", "GOVERNING THE WORLD", "THE NEW SILK ROADS"]
        for (index, title) in left.enumerated() {
            lines.append(CoverLine(text: title, box: NormBox(x: 0.20, y: 0.80 - Double(index) * 0.08, width: 0.24, height: 0.02), confidence: 0.9))
        }
        for (index, title) in right.enumerated() {
            lines.append(CoverLine(text: title, box: NormBox(x: 0.52, y: 0.78 - Double(index) * 0.08, width: 0.22, height: 0.02), confidence: 0.9))
        }
        let books = CoverReading.reportBooks(lines)
        XCTAssertEqual(books.count, 8)
        XCTAssertFalse(books.contains { $0.title.localizedCaseInsensitiveContains("Amazons") && $0.title.localizedCaseInsensitiveContains("Spartacus") })
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "PETER FRANKOPAN THE NEW SILK ROADS", title: "The New Silk Roads", author: "Peter Frankopan", published: 2018))
        var close = [CoverLine]()
        for (index, title) in ["THE AMAZONS", "GODS AND ROBOTS", "THE SPARTANS", "PAX ROMANA"].enumerated() {
            close.append(CoverLine(text: title, box: NormBox(x: 0.20, y: 0.80 - Double(index) * 0.035, width: 0.18, height: 0.016), confidence: 0.9))
        }
        for (index, title) in ["BLACK SPARTACUS", "BATTLE CRY OF FREEDOM", "Empireland", "THE NEW SILK ROADS"].enumerated() {
            close.append(CoverLine(text: title, box: NormBox(x: 0.42, y: 0.79 - Double(index) * 0.035, width: 0.16, height: 0.016), confidence: 0.9))
        }
        let split = CoverReading.reportBooks(close)
        XCTAssertEqual(split.count, 8)
        XCTAssertFalse(split.contains { $0.title.localizedCaseInsensitiveContains("Amazons") && $0.title.localizedCaseInsensitiveContains("Spartacus") })
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "MAYOR THE AMAZONS", title: "The Amazons", author: "Adrienne Mayor", published: 2014))
        XCTAssertFalse(MeasureMath.catalogueAgrees(ocr: "ROMANOVS", title: "Romanov", author: "Nadine Brandes", published: 2019))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "THE MIGHTY DEAD", title: "The Mighty Dead: Why Homer Matters", author: "Adam Nicolson", published: 2014))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "THE AGE OF WONDER", title: "The Age of Wonder", author: "Richard Holmes", published: 2008))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "FOR ALL THE TEA IN CHINA SARAH ROSE", title: "For All the Tea in China", author: "Sarah Rose", published: 2010))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "TH THE HAME OF ROME ADRIAN GOLDIWORTHY", title: "In the Name of Rome", author: "Adrian Goldsworthy", published: 2003))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "PETER JONES VOTE FOR GEAR", title: "Vote for Caesar", author: "Peter Jones", published: 2013))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "JAMES McPHERSON BATTLE CRY OF FRIEDOM", title: "Battle Cry of Freedom", author: "James M. McPherson", published: 1988))
        XCTAssertTrue(MeasureMath.titleIsDistinctive("The Mighty Dead"))
        XCTAssertTrue(MeasureMath.titleIsDistinctive("Who Rules the World"))
        XCTAssertFalse(MeasureMath.titleIsDistinctive("Ancient Magic"))
        XCTAssertFalse(MeasureMath.titleIsDistinctive("China Rose:(Renegades & Rogues)"))
        XCTAssertTrue(MeasureMath.titleIsDistinctive("In the Name of Rome"))
        XCTAssertTrue(MeasureMath.titleIsDistinctive("For All the Tea in China"))
        XCTAssertFalse(MeasureMath.catalogueAgrees(ocr: "THE AGE OF WONDER", title: "The age of wonders", author: "Aharon Appelfeld", published: 1981))
        XCTAssertTrue(MeasureMath.spineForSearch("COLIN MIEVEDY CITIES OF THE CLASSICAL WORLD").localizedCaseInsensitiveContains("mcevedy"))
        XCTAssertTrue(MeasureMath.spineForSearch("MARCO POLO The Trends").localizedCaseInsensitiveContains("travels"))
        let cities = CatalogueClient().queryAttempts("COLIN MIEVEDY DOUGLAS OLES CITIES OF THE CLASSICAL WORLD")
        XCTAssertTrue(cities.prefix(3).contains { $0.localizedCaseInsensitiveContains("mcevedy") && $0.localizedCaseInsensitiveContains("classical") })
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "PETER FRANKOPAN THE NEW SILK POADS", title: "The New Silk Roads", author: "Peter Frankopan", published: 2018))
    }

    func testASubtitleAndTheAuthorBesideItStayOneBook() {
        let lines = [
            CoverLine(text: "ROSS KING THE BOOKSELLER", box: NormBox(x: 0.30, y: 0.76, width: 0.32, height: 0.04), confidence: 0.9),
            CoverLine(text: "OF FLORENCE", box: NormBox(x: 0.50, y: 0.72, width: 0.16, height: 0.03), confidence: 0.9),
            CoverLine(text: "A GUIDE FOR THE PERPLEXED", box: NormBox(x: 0.30, y: 0.64, width: 0.32, height: 0.04), confidence: 0.9),
            CoverLine(text: "LIKE A FIERY ELEPHANT", box: NormBox(x: 0.30, y: 0.56, width: 0.32, height: 0.04), confidence: 0.9),
            CoverLine(text: "TOM", box: NormBox(x: 0.30, y: 0.48, width: 0.06, height: 0.02), confidence: 0.9),
            CoverLine(text: "THE ROAD TO MIDDLE-EARTH", box: NormBox(x: 0.42, y: 0.48, width: 0.20, height: 0.02), confidence: 0.9),
            CoverLine(text: "Alfie and Me", box: NormBox(x: 0.30, y: 0.40, width: 0.30, height: 0.04), confidence: 0.9)
        ]
        let books = CoverReading.reportBooks(lines)
        XCTAssertTrue(books.contains { $0.title.localizedCaseInsensitiveContains("Bookseller") && $0.title.localizedCaseInsensitiveContains("Florence") })
        XCTAssertTrue(books.contains { $0.title.localizedCaseInsensitiveContains("Road") && $0.title.localizedCaseInsensitiveContains("Tom") })
        XCTAssertTrue(books.contains { $0.title.localizedCaseInsensitiveContains("Perplexed") && !$0.title.localizedCaseInsensitiveContains("Florence") })
        XCTAssertFalse(MeasureMath.looksLikeTitle("Vintage"))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "Alfie & Me Carl Safina", title: "Alfie & Me", author: "Carl Safina", published: 2023))
        XCTAssertTrue(MeasureMath.spineForSearch("THE HEMLOCK CUI BETTANY HUGHES").localizedCaseInsensitiveContains("cup"))
        XCTAssertTrue(MeasureMath.spineForSearch("HEMLOCK CUF TANY HUGHES").localizedCaseInsensitiveContains("cup"))
        XCTAssertEqual(
            MeasureMath.preferTitle("Alfie & Me Carl Safina What Owls Know", "What Owls Know What Owls Know"),
            "Alfie & Me Carl Safina What Owls Know"
        )
        XCTAssertFalse(MeasureMath.readableSpine("WANPERING WIND VANPERINU MIND KREISEN"))
        let shelf = [
            CoverLine(text: "SCHOOLISHNESS SUSAN BLUM", box: NormBox(x: 0.35, y: 0.96, width: 0.23, height: 0.038), confidence: 0.9),
            CoverLine(text: "THE HEMLOCK CUP", box: NormBox(x: 0.39, y: 0.89, width: 0.16, height: 0.029), confidence: 0.9),
            CoverLine(text: "Socrates Athens and the Search for the Good Life", box: NormBox(x: 0.39, y: 0.87, width: 0.16, height: 0.021), confidence: 0.9),
            CoverLine(text: "BETTANY HUGHES", box: NormBox(x: 0.57, y: 0.87, width: 0.14, height: 0.029), confidence: 0.9),
            CoverLine(text: "ROSS KING THE BOOKSELLER", box: NormBox(x: 0.41, y: 0.80, width: 0.18, height: 0.033), confidence: 0.9),
            CoverLine(text: "OF FLORENCE", box: NormBox(x: 0.52, y: 0.77, width: 0.16, height: 0.033), confidence: 0.9),
            CoverLine(text: "EF Schumacher A GUIDE FOR THE PERPLEXED", box: NormBox(x: 0.39, y: 0.73, width: 0.27, height: 0.033), confidence: 0.9),
            CoverLine(text: "LELEPHANT", box: NormBox(x: 0.49, y: 0.69, width: 0.10, height: 0.021), confidence: 0.9),
            CoverLine(text: "The Story of B. S. Johnson JONATHAN COE", box: NormBox(x: 0.38, y: 0.65, width: 0.28, height: 0.030), confidence: 0.9),
            CoverLine(text: "SHIPPEY THE ROAD TO", box: NormBox(x: 0.46, y: 0.59, width: 0.16, height: 0.024), confidence: 0.9),
            CoverLine(text: "MIDDLE-EARTH", box: NormBox(x: 0.57, y: 0.57, width: 0.12, height: 0.025), confidence: 0.9),
            CoverLine(text: "Stylish Academic Writing", box: NormBox(x: 0.44, y: 0.51, width: 0.21, height: 0.039), confidence: 0.9),
            CoverLine(text: "SWORD Air and Light and Time and Space", box: NormBox(x: 0.35, y: 0.45, width: 0.32, height: 0.044), confidence: 0.9),
            CoverLine(text: "Alfie and Me Carl Safina", box: NormBox(x: 0.35, y: 0.37, width: 0.29, height: 0.060), confidence: 0.9)
        ]
        let read = CoverReading.reportBooks(shelf)
        XCTAssertEqual(read.count, 9)
        XCTAssertTrue(read.contains { $0.title.localizedCaseInsensitiveContains("Elephant") && $0.title.localizedCaseInsensitiveContains("Johnson") })
        XCTAssertTrue(read.contains { $0.title.localizedCaseInsensitiveContains("Perplexed") && !$0.title.localizedCaseInsensitiveContains("Johnson") })
        XCTAssertTrue(read.contains { $0.title.localizedCaseInsensitiveContains("Alfie") })
    }

    func testAnUprightShelfKeepsEachSpineAndTheAuthorBesideIt() {
        XCTAssertFalse(MeasureMath.looksLikeTitle("THE MONOPOLISTS THE MONOPOLISTS POLISTS SHELF SHELF"))
        let lines = [
            CoverLine(text: "CHRISTIAN JENNINGS MOUTHFUL OF ROCKS", box: NormBox(x: 0.21, y: 0.80, width: 0.35, height: 0.07), confidence: 0.9),
            CoverLine(text: "the end of AIRPORTS", box: NormBox(x: 0.31, y: 0.76, width: 0.22, height: 0.05), confidence: 0.9),
            CoverLine(text: "Christopher Schaberg", box: NormBox(x: 0.55, y: 0.75, width: 0.09, height: 0.03), confidence: 0.9),
            CoverLine(text: "Writing on", box: NormBox(x: 0.22, y: 0.71, width: 0.12, height: 0.05), confidence: 0.9),
            CoverLine(text: "the Wall", box: NormBox(x: 0.23, y: 0.69, width: 0.09, height: 0.03), confidence: 0.9),
            CoverLine(text: "Madeleine", box: NormBox(x: 0.48, y: 0.71, width: 0.09, height: 0.03), confidence: 0.9),
            CoverLine(text: "Pelling", box: NormBox(x: 0.47, y: 0.67, width: 0.08, height: 0.04), confidence: 0.9),
            CoverLine(text: "Vertical", box: NormBox(x: 0.25, y: 0.62, width: 0.07, height: 0.03), confidence: 0.9),
            CoverLine(text: "Stephen Graham", box: NormBox(x: 0.25, y: 0.605, width: 0.15, height: 0.03), confidence: 0.9),
            CoverLine(text: "JAMES NESTOR DEEP", box: NormBox(x: 0.23, y: 0.50, width: 0.41, height: 0.05), confidence: 0.9),
            CoverLine(text: "THE MONOPOLISTS", box: NormBox(x: 0.28, y: 0.42, width: 0.23, height: 0.04), confidence: 0.9),
            CoverLine(text: "MARY", box: NormBox(x: 0.23, y: 0.40, width: 0.015, height: 0.06), confidence: 0.8),
            CoverLine(text: "PILON", box: NormBox(x: 0.24, y: 0.40, width: 0.013, height: 0.07), confidence: 0.8),
            CoverLine(text: "SHELF", box: NormBox(x: 0.45, y: 0.36, width: 0.15, height: 0.04), confidence: 0.8)
        ]
        let books = CoverReading.reportBooks(lines)
        XCTAssertEqual(books.count, 6, books.map(\.title).joined(separator: " | "))
        XCTAssertTrue(books.contains { $0.title.localizedCaseInsensitiveContains("Mouthful") })
        XCTAssertTrue(books.contains { $0.title.localizedCaseInsensitiveContains("Airports") && $0.title.localizedCaseInsensitiveContains("Schaberg") })
        XCTAssertTrue(books.contains { $0.title.localizedCaseInsensitiveContains("Wall") && $0.title.localizedCaseInsensitiveContains("Pelling") })
        XCTAssertTrue(books.contains { $0.title.localizedCaseInsensitiveContains("Monopolists") && $0.title.localizedCaseInsensitiveContains("Pilon") })
        XCTAssertFalse(books.contains { $0.title.localizedCaseInsensitiveContains("Shelf") })
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "JAMES NESTOR DEEP", title: "Deep", author: "James Nestor", published: 2014))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "CHRISTIAN JENNINGS MOUTHFUL OF ROCKS", title: "Mouthful of Rocks", author: "Christian Jennings", published: 2010))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "MARY PILON THE MONOPOLISTS", title: "The Monopolists", author: "Mary Pilon", published: 2015))
        XCTAssertFalse(MeasureMath.catalogueAgrees(ocr: "FOREST Love Is The Measure", title: "Measure for Measure", author: "Canada. Dept. of Forestry and Rural Development. Forestry Branch.", published: 1968))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "FOREST Love Is The Measure", title: "Love Is the Measure", author: "Jim Forest", published: 1986))
        XCTAssertFalse(MeasureMath.looksLikeTitle("PAULIST PRESS"))
        XCTAssertTrue(MeasureMath.looksLikeTitle("Empireland"))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "Father Jean C. J. d'Elbee I Believe in LOVE", title: "I Believe in Love", author: "Jean d'Elbee", published: 1974))
    }

    func testNeighboringSpinesDoNotGlueIntoOneTitle() {
        let titles = ["SEEING THINGS SEAMUS HEANEY", "POEMS 1965-1975", "BEOWULF SEAMUS HEANEY", "SURE SHOT ERICA FUNKHOUSER", "AN INVITATION TO POETRY"]
        let lines = titles.enumerated().map { index, title in
            CoverLine(text: title, box: NormBox(x: 0.55, y: 0.70 - Double(index) * 0.04, width: 0.25, height: 0.014), confidence: 0.9)
        }
        let books = CoverReading.reportBooks(lines)
        XCTAssertEqual(books.count, 5)
        XCTAssertTrue(books.contains { $0.title.localizedCaseInsensitiveContains("Seeing") && !$0.title.localizedCaseInsensitiveContains("Beowulf") })
        XCTAssertTrue(books.contains { $0.title.localizedCaseInsensitiveContains("Invitation") })
    }

    func testAFrameKeepsEachSpineAndDropsTheBezel() {
        var lines: [CoverLine] = []
        let titles = ["No More Masks", "The Great Modern Poets", "The Best American Poetry 1998", "The Beat Book", "Joy Harjo"]
        for (index, title) in titles.enumerated() {
            lines.append(CoverLine(text: title, box: NormBox(x: 0.2, y: 0.7 - Double(index) * 0.08, width: 0.18, height: 0.02), confidence: 0.8))
        }
        lines.append(CoverLine(text: "BOOK AND CD", box: NormBox(x: 0.28, y: 0.61, width: 0.08, height: 0.012), confidence: 0.7))
        lines.append(CoverLine(text: "I really built a library for some of our books", box: NormBox(x: 0.8, y: 0.2, width: 0.04, height: 0.5), confidence: 0.9))
        let books = CoverReading.reportBooks(lines)
        XCTAssertGreaterThanOrEqual(books.count, 4)
        XCTAssertTrue(books.contains { $0.title.localizedCaseInsensitiveContains("Great Modern") && $0.title.localizedCaseInsensitiveContains("CD") })
        XCTAssertFalse(books.contains { $0.title.localizedCaseInsensitiveContains("library") })
    }

    func testAHorizontalStackIsOneBookPerTitle() {
        var lines: [CoverLine] = []
        for index in 0..<8 {
            lines.append(CoverLine(
                text: "The Best American Poetry \(1993 + index)",
                box: NormBox(x: 0.12, y: 0.80 - Double(index) * 0.06, width: 0.28, height: 0.02),
                confidence: 0.8
            ))
        }
        let books = CoverReading.inventory(lines)
        XCTAssertEqual(books.count, 8)
    }

    func testAStackOfBooksSplitsOnTheEdgesBetweenThem() {
        var edges = [Double](repeating: 1, count: 80)
        for index in [12, 24, 36, 48, 60] { edges[index] = 40 }
        let bands = MeasureMath.splitBands(edges: edges, minimum: 6)
        XCTAssertGreaterThanOrEqual(bands.count, 5)
    }

    func testOcrPoetryStillMatchesPoetry() {
        XCTAssertGreaterThan(MeasureMath.jaccard("The Best American Poftry", "The Best American Poetry"), 0.6)
    }

    func testTwoShelvesKeepEverySpineAndThePitch() {
        var lines: [CoverLine] = []
        for index in 0..<12 {
            lines.append(CoverLine(
                text: "The Best American Poetry",
                box: NormBox(x: 0.08 + Double(index) * 0.06, y: 0.62, width: 0.028, height: 0.18),
                confidence: 0.8
            ))
        }
        for index in 0..<10 {
            lines.append(CoverLine(
                text: "Seamus Heaney Opened Ground",
                box: NormBox(x: 0.10 + Double(index) * 0.06, y: 0.22, width: 0.03, height: 0.16),
                confidence: 0.8
            ))
        }
        let books = CoverReading.inventory(lines)
        XCTAssertEqual(books.count, 22)
        XCTAssertEqual(Set(books.map(\.shelf)).count, 2)
        XCTAssertEqual(books.filter { $0.shelf == 0 }.count, 12)
        XCTAssertGreaterThan(books[0].box.height, 0.15)
        XCTAssertGreaterThan(books[0].box.width, 0.04)
    }

    func testAShelfTurnedSidewaysIsOneBookPerSpine() {
        var lines: [CoverLine] = []
        for index in 0..<10 {
            lines.append(CoverLine(
                text: "Top Shelf \(index)",
                box: NormBox(x: 0.12, y: 0.82 - Double(index) * 0.05, width: 0.22, height: 0.018),
                confidence: 0.8
            ))
        }
        lines.append(CoverLine(
            text: "Harjo",
            box: NormBox(x: 0.12, y: 0.808, width: 0.08, height: 0.01),
            confidence: 0.7
        ))
        for index in 0..<8 {
            lines.append(CoverLine(
                text: "Bottom Shelf \(index)",
                box: NormBox(x: 0.55, y: 0.78 - Double(index) * 0.05, width: 0.2, height: 0.018),
                confidence: 0.8
            ))
        }
        let found = CoverReading.shelfReads(lines)
        XCTAssertTrue(found.stacked)
        XCTAssertEqual(found.reads.count, 18)
        XCTAssertEqual(found.reads.filter { $0.box.midX < 0.4 }.count, 10)
        XCTAssertEqual(found.reads.filter { $0.box.midX > 0.5 }.count, 8)
        XCTAssertTrue(found.reads.first?.title.contains("Top Shelf") == true)
    }

    func testAPageOfEqualLinesIsNotAStackOfBooks() {
        var lines: [CoverLine] = []
        for index in 0..<6 {
            lines.append(CoverLine(
                text: "Make both home cards smaller and rounder today",
                box: NormBox(x: 0.1, y: 0.2 + Double(index) * 0.05, width: 0.6, height: 0.03),
                confidence: 0.9
            ))
        }
        XCTAssertEqual(CoverReading.stackedBooks(lines).count, 0)
    }

    func testAScreenIsNotARowOfSpines() {
        var lines: [CoverLine] = []
        for index in 0..<6 {
            lines.append(CoverLine(text: "Make both home cards smaller and rounder today", box: NormBox(x: 0.1, y: 0.2 + Double(index) * 0.05, width: 0.6, height: 0.03), confidence: 0.9))
        }
        XCTAssertEqual(CoverReading.spineColumns(lines).count, 0)
    }

    func testHeldBookKeepsTheTitleAcrossFrames() {
        let cover = NormBox(x: 0.2, y: 0.25, width: 0.5, height: 0.45)
        let title = SpineHit(text: "Why I Am so Clever", shelf: 3, midX: 0.45, heightCm: 18, thicknessCm: 2, confidence: 0.7, frameRef: "frames/a.jpg", box: cover)
        let author = SpineHit(text: "Friedrich Nietzsche", shelf: 5, midX: 0.7, heightCm: 18, thicknessCm: 2, confidence: 0.95, frameRef: "frames/b.jpg", box: NormBox(x: 0.25, y: 0.3, width: 0.48, height: 0.4))
        var tracks = SpineTracker.merge(tracks: [], hits: [title])
        tracks = SpineTracker.merge(tracks: tracks, hits: [author])
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.text, "Why I Am so Clever")
    }

    func testHunchIsExcludedFromMoneyUntilConfirmed() throws {
        var engine = WalkEngine()
        engine.begin(sessionID: "s", settings: .unitedStates, device: "test", practice: false)
        engine.confirmCountry()
        engine.noteCard(millimetresPerPixel: 0.2, distanceM: 0.5, arkitCardMeters: 0.0856)
        engine.noteSpines([
            SpineHit(text: "Moby", shelf: 1, midX: 0.2, heightCm: 20, thicknessCm: 3, confidence: 0.8, frameRef: "frames/a.jpg"),
            SpineHit(text: "", shelf: 1, midX: 0.5, heightCm: 18, thicknessCm: 2, confidence: 0, frameRef: "frames/a.jpg")
        ])
        var packet = PacketBuilder.build(from: engine, version: 1)
        XCTAssertEqual(packet.totals.booksIdentified, 0)
        XCTAssertEqual(packet.totals.bookCount, 2)
        XCTAssertEqual(packet.totals.booksReplacementCost, 0)
        XCTAssertTrue(packet.reviewQueue.contains { $0.reason.contains("Hunch") })

        engine.confirmLatestHunch()
        engine.applyPrices([
            PriceUpdate(
                bookID: engine.books[0].id,
                replacement: SourcedMoney(amount: 12.5, source: "AbeBooks", url: "https://www.abebooks.com/example", retrievedAt: "2026-10-31T00:00:00Z", converted: false, conditionAssumed: "new"),
                used: SourcedMoney(amount: 6, source: "AbeBooks", url: "https://www.abebooks.com/used", retrievedAt: "2026-10-31T00:00:00Z", converted: false, conditionAssumed: "used, good"),
                euroReplacement: nil,
                euroUsed: nil
            )
        ])
        packet = PacketBuilder.build(from: engine, version: 2)
        XCTAssertEqual(packet.totals.booksIdentified, 1)
        XCTAssertEqual(packet.totals.booksReplacementCost, 12.5)
        XCTAssertEqual(packet.totals.booksUsedValue, 6)
        XCTAssertEqual(packet.totals.shelfRunM, 0.05, accuracy: 0.001)

        engine.markLatestFirstEdition()
        packet = PacketBuilder.build(from: engine, version: 3)
        XCTAssertEqual(packet.books.first { $0.edition == "first edition" }?.status, .needsAppraisal)
        XCTAssertFalse(packet.books.first { $0.edition == "first edition" }?.replacementCost.hasAmount ?? true)
        XCTAssertEqual(packet.totals.booksReplacementCost, 0)
    }

    func testSkipShelfLeavesTheLineAndDropsTheTotal() {
        var engine = WalkEngine()
        engine.begin(sessionID: "s", settings: .unitedStates, device: "test", practice: false)
        engine.confirmCountry()
        engine.noteCard(millimetresPerPixel: 0.2, distanceM: 0.5, arkitCardMeters: 0.0856)
        engine.noteSpines([
            SpineHit(text: "Moby", shelf: 3, midX: 0.2, heightCm: 20, thicknessCm: 4, confidence: 0.9, frameRef: "frames/a.jpg")
        ])
        engine.confirmLatestHunch()
        engine.applyPrices([
            PriceUpdate(bookID: engine.books[0].id, replacement: SourcedMoney(amount: 10, source: "AbeBooks", url: "https://www.abebooks.com/x", retrievedAt: "2026-10-31T00:00:00Z", converted: false, conditionAssumed: "new"), used: nil, euroReplacement: nil, euroUsed: nil)
        ])
        engine.skipCurrentShelf()
        let packet = PacketBuilder.build(from: engine, version: 1)
        XCTAssertEqual(packet.books.count, 1)
        XCTAssertEqual(packet.totals.bookCount, 0)
        XCTAssertEqual(packet.totals.booksReplacementCost, 0)
    }

    func testSummaryDoesNotInventATotal() {
        let engine = PracticeWalk.make(sessionID: "practice")
        var finished = engine
        finished.beginFinishing()
        let packet = finished.finishSummary(version: 1)
        XCTAssertTrue(packet.practice)
        XCTAssertFalse(packet.books.contains { $0.replacementCost.hasAmount })
        XCTAssertTrue(PacketBuilder.summary(for: packet).contains("do not have a sourced replacement total"))
        XCTAssertNotNil(packet.room.floorAreaM2)
        XCTAssertNotEqual(packet.room.floorAreaM2, packet.room.arkitFloorAreaM2)
    }

    func testASpineAgreesWhenTheAuthorIsOnIt() {
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "BEOWULF SEAMUS HEANEY", title: "Beowulf", author: "Seamus Heaney", published: 2000))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "BILLY COLLINS BALLISTICS", title: "Ballistics", author: "Billy Collins", published: 2008))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "Alabanza MARTIN ESPADA", title: "Alabanza", author: "Martin Espada", published: 2003))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "AN INVITATION TO POETRY", title: "An invitation to poetry", author: "Robert Pinsky", published: 2004))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "THE BEST AMERICAN POSTRY 1996", title: "The Best American Poetry 1996", author: "Adrienne Rich", published: 1996))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "THE GREAT MODERN POETS BOOK AND CD", title: "The Great Modern Poets", author: "Michael Schmidt", published: 2000))
        XCTAssertFalse(MeasureMath.catalogueAgrees(ocr: "THE BEST AMERICAN POSTRY 1996", title: "The Best American Erotica 1996", author: "Susie Bright", published: 1996))
        XCTAssertFalse(MeasureMath.catalogueAgrees(ocr: "THE BEST AMERICAN POETRY 1996", title: "The Best American Poetry 1998", author: "David Lehman", published: 1998))
        XCTAssertFalse(MeasureMath.catalogueAgrees(ocr: "AN INVITATION TO POETRY", title: "The crystal cabinet", author: "Horace Gregory", published: 1962))
        XCTAssertFalse(MeasureMath.catalogueAgrees(ocr: "The Best American Poetry", title: "The American", author: "Henry James", published: 1900))
        XCTAssertFalse(MeasureMath.catalogueAgrees(ocr: "Robert Duncan Bending the Bow", title: "Letter to Robert Duncan while bending the bow", author: "Paul Mariah", published: 1979))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "Robert Duncan Bending the Bow", title: "Bending the bow", author: "Robert Duncan", published: 1968))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "SURE SHOT ERICA YUNKHOUSEP", title: "Sure shot and other poems", author: "Erica Funkhouser", published: 1992))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "COLERIDGE SELECTED PORTRE", title: "Coleridge Select poetry and Prose", author: "Samuel Taylor Coleridge", published: nil))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "THE BEST AMERICAN POITRY 1996", title: "The Best American Poetry 1996", author: "Adrienne Rich", published: 1996))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "THE BEST AMERICAN POETRY 1998", title: "The Best American Poetry 1998", author: "David Lehman", published: 1998))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "THE BEST AMERICAN PORTRY 1098", title: "The Best American Poetry 1998", author: "David Lehman", published: 1998))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "THE BEST AME ICAN PORTRY 1998", title: "The Best American Poetry 1998", author: "David Lehman", published: 1998))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "THE GREAT MODERN POETS BOOK AND CD", title: "Great Modern Poets", author: "Michael Schmidt", published: nil))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "HEANEY SEEING THINGS SEAM SEAMUS HEANEY", title: "Seeing things", author: "Seamus Heaney", published: 1991))
        let seeing = CatalogueClient().queryAttempts("HEANEY SEEING THINGS SEAM SEAMUS HEANEY")
        XCTAssertEqual(seeing.first?.lowercased(), "heaney seeing things seamus")
        let modern = CatalogueClient().queryAttempts("THE GREAT MODERN POETS BOOK AND CD SCH")
        XCTAssertEqual(modern.first?.lowercased(), "great modern poets")
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "SEEING THINGS SEAMUS HEANES", title: "Seeing things", author: "Seamus Heaney", published: 1991))
        let alabanza = CatalogueClient().queryAttempts("UTN 27TA MARTIN ESPADA Alabanza")
        XCTAssertTrue(alabanza.contains { line in
            let lower = line.lowercased()
            return lower.contains("alabanza") && lower.contains("espada") && !lower.contains("27")
        })
        XCTAssertFalse(MeasureMath.catalogueAgrees(ocr: "The Best American Poetry", title: "The Best American Poetry 1998", author: "David Lehman", published: 1998))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "THEBEAT BOOK Writings from the Beal Generation", title: "The beat book", author: "Anne Waldman", published: 1992))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "COLERIDGE SELECTED POSTA", title: "Selected poetry", author: "Samuel Taylor Coleridge", published: nil))
        XCTAssertTrue(MeasureMath.catalogueAgrees(ocr: "SURE SHOT ERICA FUNKHOUSER", title: "Sure shot and other poems", author: "Erica Funkhouser", published: 1992))
        let beat = CatalogueClient().queryAttempts("THEBEAT BOOK Writings from The Beat Generation")
        XCTAssertTrue(beat.contains { $0.localizedCaseInsensitiveContains("beat generation") && !$0.localizedCaseInsensitiveContains("thebeat") })
    }

    func testACleanSpineBeatsTheLineThatGluedItsNeighbor() {
        let clean = "THE BEST AMERICAN POLTRY 1996"
        let glued = "Larioner Pegarkach Po THE BEST AMERICAN PORTRY 1996"
        XCTAssertEqual(MeasureMath.preferTitle(glued, clean), clean)
        XCTAssertEqual(MeasureMath.preferTitle("THE GREAT MODERN POETS", "THE GREAT MODERN POETS BOOK AND CD"), "THE GREAT MODERN POETS BOOK AND CD")
        XCTAssertFalse(MeasureMath.sameReading("THE BEST AMERICAN PORTRY 1098", "THE BEST AMERICAN POLTRY 1996"))
        let queries = CatalogueClient().queryAttempts("WHEN THE LIGHT OF THE WORLO WAS SUBDUED HE JOY HARJO AI OUR SONGS CAME THROUGH")
        XCTAssertTrue(queries.contains { line in
            let lower = line.lowercased()
            return lower.contains("harjo") && lower.contains("songs") && !lower.contains("worlo")
        })
    }

    func testAMisspelledSpineDropsTheBadWordFromTheQuery() {
        let queries = CatalogueClient().queryAttempts("THE BEST AMERICAN POSTRY 1996")
        XCTAssertTrue(queries.contains { $0.localizedCaseInsensitiveContains("poetry") && $0.contains("1996") })
    }

    func testPacketJSONRoundTripKeepsNulls() throws {
        var engine = WalkEngine()
        engine.begin(sessionID: "json", settings: .unitedStates, device: "test", practice: false)
        engine.confirmCountry()
        engine.noteSpines([
            SpineHit(text: "", shelf: 1, midX: 0.2, heightCm: nil, thicknessCm: nil, confidence: 0, frameRef: "frames/a.jpg")
        ])
        let packet = PacketBuilder.build(from: engine, version: 1)
        let data = try JSONEncoder().encode(packet)
        let raw = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(raw.contains("\"review_queue\""))
        XCTAssertTrue(raw.contains("\"spine_height_cm\":null") || raw.contains("\"spine_height_cm\" : null"))
        let decoded = try JSONDecoder().decode(ClaimPacket.self, from: data)
        XCTAssertEqual(decoded.totals.bookCount, packet.totals.bookCount)
        XCTAssertNil(decoded.books.first?.spineHeightCm)
        XCTAssertNil(decoded.room.floorAreaM2)
    }
}
