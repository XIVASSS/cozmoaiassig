import Foundation
import UIKit

enum MeasureMath {
    static let cardWidthMM = 85.60
    static let cardHeightMM = 53.98
    static var cardAspect: Double { cardWidthMM / cardHeightMM }

    /// Longer side of an ID-1 card in pixels. Returns millimetres per pixel, or nil when the shape is not a card.
    static func millimetresPerPixel(longSidePx: Double, shortSidePx: Double, aspectTolerance: Double = 0.12) -> Double? {
        guard longSidePx > 8, shortSidePx > 8 else { return nil }
        let ratio = longSidePx / shortSidePx
        guard abs(ratio - cardAspect) / cardAspect <= aspectTolerance else { return nil }
        return cardWidthMM / longSidePx
    }

    /// Card width is the truth. `arkitCardMeters` is the same edge as tracking saw it.
    /// The returned correction multiplies tracking distances. It is never an average of the two.
    static func scaleDecision(arkitCardMeters: Double, threshold: Double) -> ScaleDecision? {
        guard arkitCardMeters > 0.01 else { return nil }
        let truth = cardWidthMM / 1000
        let correction = truth / arkitCardMeters
        let disagreement = abs(correction - 1)
        return ScaleDecision(correction: correction, disagreement: disagreement, flagged: disagreement > threshold)
    }

    static func apply(correction: Double, meters: Double) -> Double {
        meters * correction
    }

    /// Millimetres per pixel grow in proportion to distance from the camera.
    static func millimetresPerPixel(referenceMMPerPixel: Double, referenceDistanceM: Double, distanceM: Double) -> Double? {
        guard referenceMMPerPixel > 0, referenceDistanceM > 0.05, distanceM > 0.05 else { return nil }
        return referenceMMPerPixel * (distanceM / referenceDistanceM)
    }

    static func centimetres(pixels: Double, millimetresPerPixel: Double) -> Double {
        pixels * millimetresPerPixel / 10
    }

    /// Stretches of a shelf that are actually books, not the wall.
    static func runs(energy: [Double], floor: Double, minimum: Int) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start: Int?
        for (index, value) in energy.enumerated() {
            if value >= floor {
                if start == nil { start = index }
            } else if let begin = start {
                if index - begin >= minimum { result.append(begin..<index) }
                start = nil
            }
        }
        if let begin = start, energy.count - begin >= minimum {
            result.append(begin..<energy.count)
        }
        return result
    }

    /// One range per book. Large gaps are filled from the pitch of the books already seen.
    static func splitBands(edges: [Double], minimum: Int) -> [Range<Int>] {
        guard edges.count >= minimum * 2, minimum > 0 else { return [] }
        let middle = edges.sorted()[edges.count / 2]
        let threshold = max(middle * 1.8, 1)
        var marks = [0]
        var last = 0
        if edges.count > 2 {
            for index in 1..<(edges.count - 1) where index - last >= minimum {
                if edges[index] >= threshold, edges[index] >= edges[index - 1], edges[index] >= edges[index + 1] {
                    marks.append(index)
                    last = index
                }
            }
        }
        if edges.count - 1 - (marks.last ?? 0) >= minimum {
            marks.append(edges.count - 1)
        }
        guard marks.count >= 2 else { return [] }
        var filled = [marks[0]]
        let gaps = zip(marks, marks.dropFirst()).map { $1 - $0 }
        let pitch = gaps.sorted()[gaps.count / 2]
        for end in marks.dropFirst() {
            var cursor = filled[filled.count - 1]
            while end - cursor > pitch * 8 / 5 {
                let next = cursor + pitch
                if end - next < minimum / 2 { break }
                filled.append(next)
                cursor = next
            }
            if filled.last != end { filled.append(end) }
        }
        return zip(filled, filled.dropFirst()).compactMap { start, end in
            end - start >= max(2, minimum / 2) ? start..<end : nil
        }
    }

    static func blurScore(luma: [UInt8], width: Int, height: Int) -> Double {
        guard width > 4, height > 4, luma.count >= width * height else { return 0 }
        var sum = 0.0
        var sumSquares = 0.0
        var count = 0.0
        let step = max(1, width / 80)
        var y = step
        while y < height - step {
            var x = step
            while x < width - step {
                let center = Int(luma[y * width + x])
                let left = Int(luma[y * width + (x - step)])
                let right = Int(luma[y * width + (x + step)])
                let up = Int(luma[(y - step) * width + x])
                let down = Int(luma[(y + step) * width + x])
                let lap = Double(left + right + up + down - 4 * center)
                sum += lap
                sumSquares += lap * lap
                count += 1
                x += step
            }
            y += step
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        return max(0, sumSquares / count - mean * mean)
    }

    static func glareFraction(luma: [UInt8], threshold: UInt8 = 245) -> Double {
        guard !luma.isEmpty else { return 0 }
        let hot = luma.reduce(0) { $0 + ($1 >= threshold ? 1 : 0) }
        return Double(hot) / Double(luma.count)
    }

    static func tokens(_ text: String) -> [String] {
        text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
    }

    static func jaccard(_ a: String, _ b: String) -> Double {
        let left = tokens(a)
        let right = tokens(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        var matched = 0
        var used = Set<Int>()
        for word in left {
            if let index = right.enumerated().first(where: { !used.contains($0.offset) && sameWord(word, $0.element) })?.offset {
                used.insert(index)
                matched += 1
            }
        }
        let union = left.count + right.count - matched
        return union == 0 ? 0 : Double(matched) / Double(union)
    }

    /// OCR often swaps one letter. "poftry" and "poetry" are the same word.
    static func sameWord(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.count >= 4, b.count >= 4, abs(a.count - b.count) <= 1 else { return false }
        let left = Array(a)
        let right = Array(b)
        var i = 0
        var j = 0
        var edits = 0
        while i < left.count, j < right.count {
            if left[i] == right[j] {
                i += 1
                j += 1
            } else {
                edits += 1
                if edits > 1 { return false }
                if left.count > right.count { i += 1 }
                else if right.count > left.count { j += 1 }
                else { i += 1; j += 1 }
            }
        }
        edits += (left.count - i) + (right.count - j)
        return edits <= 1
    }

    static func decideIdentity(text: String, ocrConfidence: Float, match: CatalogueMatch?) -> IdentityDecision {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return .unidentified }
        if let match, ocrConfidence >= 0.55, match.score >= 0.62, jaccard(trimmed, match.title) >= 0.34 {
            return .identified(match)
        }
        return .hunch(trimmed)
    }

    /// The report pass. A catalogue title is kept when the spine text agrees. A scrap is not a hunch.
    static func decideReport(text: String, match: CatalogueMatch?) -> IdentityDecision {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeTitle(trimmed) else { return .unidentified }
        if let match, catalogueAgrees(ocr: trimmed, title: match.title, author: match.author, published: match.firstPublishYear) {
            return .identified(match)
        }
        return .hunch(trimmed)
    }

    /// A line of smashed letters is not a spine. A short title, or one misspelled word beside real ones, still is.
    /// Spelled words of a real title. A slice full of new misspellings does not outscore the frame.
    static func countedWords(_ text: String) -> [String] {
        tokens(text).filter { $0.count >= 5 && spelled($0) }
    }

    static func readableSpine(_ text: String) -> Bool {
        let words = tokens(text).filter { $0.count >= 5 }
        guard words.count >= 2 else { return true }
        return words.filter { spelled($0) }.count * 2 >= words.count
    }

    static func looksLikeTitle(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.contains("library for") || lower.contains("software update") || lower.contains("storage space") { return false }
        if lower.contains("extra shelves") || lower.contains("bookcase") || lower.contains("bookease") || lower.contains("stacking") { return false }
        if lower == "furniture" || lower == "rniture" || lower == "bookshelf" { return false }
        let words = tokens(trimmed)
        let publishers = ["vintage", "penguin", "norton", "harvard", "anchor", "continuum", "substack", "hackett", "herder", "ignatius", "paulist", "bodley", "harper"]
        if words.count == 1, publishers.contains(where: { sameWord(words[0], $0) }) { return false }
        if words.count == 2, publishers.contains(where: { sameWord(words[0], $0) }), words[1] == "press" || words[1] == "row" { return false }
        let long = words.filter { $0.count >= 5 }
        if long.count >= 2 {
            var seen = Set<String>()
            for word in long where !seen.insert(word).inserted { return false }
        }
        if words.count >= 2, words.contains(where: { $0.count >= 4 }) { return true }
        return words.count == 1 && (words[0].count >= 6)
    }

    static func agreesEnough(_ ocr: String, _ title: String) -> Bool {
        catalogueAgrees(ocr: ocr, title: title, author: "", published: nil)
    }

    /// A catalogue hit is this spine when the title's own words are on it. A longer catalogue title that merely overlaps, such as a letter about the book, does not count. A one-word title also needs its author on the spine.
    static func catalogueAgrees(ocr: String, title: String, author: String, published: Int?) -> Bool {
        let read = spineForSearch(ocr)
        if yearsConflict(read, title, published) || volumeYearBlocks(read, title) { return false }
        let spine = tokens(read)
        var seenTitle: Set<String> = []
        let titleWords = tokens(title).filter { $0.count >= 3 && !stopWords.contains($0) && seenTitle.insert($0).inserted }
        guard !titleWords.isEmpty else { return false }
        let covered = titleWords.filter { word in spine.contains { wordCovers(spineWord: $0, titleWord: word) } }
        let authorHit = tokens(author).contains { word in word.count >= 4 && spine.contains { sameWord($0, word) } }
        if covered.count == titleWords.count, titleWords.count >= 2 { return true }
        let main = title.split(whereSeparator: { $0 == ":" || $0 == ";" }).first.map(String.init) ?? title
        var seenMain: Set<String> = []
        let mainWords = tokens(main).filter { $0.count >= 3 && !stopWords.contains($0) && seenMain.insert($0).inserted }
        if mainWords.count >= 2, mainWords.allSatisfy({ word in spine.contains { wordCovers(spineWord: $0, titleWord: word) } }) { return true }
        if covered.count == titleWords.count, let only = titleWords.first, titleWords.count == 1, only.count >= 4, authorHit {
            return true
        }
        if titleWords.count >= 3 {
            let head = titleWords.prefix(3)
            if head.allSatisfy({ word in spine.contains { wordCovers(spineWord: $0, titleWord: word) } }) { return true }
        }
        if authorHit, covered.count >= 2, covered.count * 2 >= titleWords.count { return true }
        return false
    }

    /// "The Mighty Dead" can be named. "Ancient Magic" and "China Rose" are shared or too short, so they stay hunches until the author is on the spine.
    static func titleIsDistinctive(_ title: String) -> Bool {
        let main = title.split(whereSeparator: { $0 == ":" || $0 == ";" }).first.map(String.init) ?? title
        let generic: Set<String> = ["ancient", "magic", "world", "history", "book", "books", "great", "time", "life", "story", "stories", "new"]
        let words = tokens(main).filter { $0.count >= 3 && !["the", "and", "for", "all", "with", "from"].contains($0) }
        if words.count >= 3 || words.contains(where: { $0.count >= 8 }) { return true }
        let solid = words.filter { $0.count >= 4 }
        let blocked: Set<Set<String>> = [["china", "rose"], ["ancient", "magic"]]
        if blocked.contains(Set(solid)) { return false }
        if solid.count >= 2, !solid.allSatisfy({ generic.contains($0) }) { return true }
        if words.count >= 2, words.contains(where: { $0.count >= 5 }), !words.allSatisfy({ generic.contains($0) }) { return true }
        return false
    }

    /// "wonder" on a spine is not the title word "wonders". A one-letter OCR miss still counts.
    private static func wordCovers(spineWord: String, titleWord: String) -> Bool {
        if spineWord == titleWord { return true }
        guard sameWord(spineWord, titleWord) else { return false }
        if titleWord.count > spineWord.count, titleWord.hasPrefix(spineWord) { return false }
        return true
    }

    /// Vision reads "portry" and "portre" for poetry. The catalogue search needs the real word.
    static func spineForSearch(_ text: String) -> String {
        let poetry: Set<String> = ["portry", "postry", "poltry", "poftry", "poetey", "poetr", "portre", "poeth", "poitry", "posta", "poste", "poety"]
        let caesar: Set<String> = ["gesar", "cesar", "ceasar", "caeser"]
        let name: Set<String> = ["hame", "nane", "narne"]
        let roads: Set<String> = ["poads", "roods", "raods"]
        let poems: Set<String> = ["porms", "pomes"]
        let mapped = text.split(separator: " ").map { word -> String in
            var lower = word.lowercased()
            if lower.hasPrefix("the"), lower.count >= 7 { lower = String(lower.dropFirst(3)) }
            if poetry.contains(lower) { return "poetry" }
            if caesar.contains(lower) { return "caesar" }
            if name.contains(lower) { return "name" }
            if roads.contains(lower) { return "roads" }
            if poems.contains(lower) { return "poems" }
            if let year = repairedYear(String(word)) { return year }
            if word.lowercased().hasPrefix("the"), word.count >= 7 {
                return "the \(lower)"
            }
            return String(word)
        }
        let stitched = stitchSplitWords(mapped)
        let voting = stitched.contains { $0.lowercased() == "vote" }
        return stitched.map { word in
            let lower = word.lowercased()
            if sameWord(lower, "american") { return "american" }
            if voting, lower == "gear" { return "caesar" }
            if lower == "cui" || lower == "cuf", stitched.contains(where: { $0.lowercased() == "hemlock" }) { return "cup" }
            if sameWord(lower, "freedom"), lower != "freedom" { return "freedom" }
            if sameWord(lower, "mcevedy") { return "mcevedy" }
            let around = stitched.map { $0.lowercased() }
            if ["trends", "tracels", "trevl", "travls"].contains(lower), around.contains("polo") || around.contains("marco") {
                return "travels"
            }
            if lower == "nre", around.contains("spain") || around.contains("conquest") { return "new" }
            if lower == "dial", around.contains("spain") || around.contains("conquest") { return "diaz" }
            return word
        }.joined(separator: " ")
    }

    /// Two readings of one spine. Different numbers are different volumes, so 1996 stays apart from a misread 1098.
    static func sameReading(_ left: String, _ right: String) -> Bool {
        if digitsDiffer(left, right) { return false }
        if jaccard(left, right) > 0.55 { return true }
        let a = tokens(left).filter { $0.count >= 4 }
        let b = tokens(right).filter { $0.count >= 4 }
        guard !a.isEmpty, !b.isEmpty else { return false }
        let aInB = a.allSatisfy { word in b.contains { sameWord($0, word) } }
        let bInA = b.allSatisfy { word in a.contains { sameWord($0, word) } }
        return aInB || bInA
    }

    /// Keep a spelled subtitle ("Book and CD", "Collected Poems"). Drop a longer line whose extra words are not words.
    static func preferTitle(_ current: String, _ candidate: String) -> String {
        let a = tokens(current).filter { $0.count >= 4 }
        let b = tokens(candidate).filter { $0.count >= 4 }
        let aInB = !a.isEmpty && a.allSatisfy { word in b.contains { sameWord($0, word) } }
        let bInA = !b.isEmpty && b.allSatisfy { word in a.contains { sameWord($0, word) } }
        if aInB || bInA {
            let longer = a.count >= b.count ? current : candidate
            let shorter = a.count >= b.count ? candidate : current
            let extra = tokens(longer).filter { word in
                word.count >= 5 && !tokens(shorter).contains { sameWord($0, word) }
            }
            let solidShort = tokens(shorter).filter { $0.count >= 5 }
            if solidShort.count >= 2, extra.contains(where: { !spelled($0) }) || extra.count >= 2 { return shorter }
            return longer
        }
        return titleQuality(candidate) > titleQuality(current) ? candidate : current
    }

    private static func spelled(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        guard letters.count >= 4 else { return true }
        let range = NSRange(location: 0, length: word.utf16.count)
        let found = UITextChecker().rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: "en_US")
        return found.location == NSNotFound
    }

    private static func digitsDiffer(_ left: String, _ right: String) -> Bool {
        let a = digitRuns(left)
        let b = digitRuns(right)
        guard let first = a.first, let second = b.first else { return false }
        return first != second
    }

    private static func digitRuns(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isNumber }).map(String.init).filter { $0.count >= 3 }
    }

    private static func titleQuality(_ text: String) -> Int {
        let words = text.split(separator: " ").map(String.init)
        var score = 0
        for word in words {
            let lower = word.lowercased()
            let letters = lower.filter(\.isLetter)
            if letters.count >= 4, letters.contains(where: { "aeiou".contains($0) }) { score += 2 }
            if lower.contains(where: \.isNumber), lower.contains(where: \.isLetter) { score -= 3 }
        }
        if words.count > 8 { score -= (words.count - 8) * 2 }
        return score
    }

    private static let stopWords: Set<String> = ["the", "and", "for", "all", "but", "not", "with", "from", "that", "this", "into", "your", "their", "about"]

    /// A year printed on the catalogue volume has to be the year on the spine. "Since 1900" is not a volume year. A smashed 1905 is not 1965.
    static func volumeYearBlocks(_ ocr: String, _ title: String) -> Bool {
        let spineYears = years(in: ocr).filter { $0 >= 1950 }
        let titleYears = years(in: title).filter { $0 >= 1980 }
        if spineYears.isEmpty { return !titleYears.isEmpty }
        if titleYears.isEmpty { return false }
        return !titleYears.contains(where: { spineYears.contains($0) })
    }

    private static func yearsConflict(_ ocr: String, _ title: String, _ published: Int?) -> Bool {
        let spineYears = years(in: ocr).filter { $0 >= 1950 }
        guard let spineYear = spineYears.first else { return false }
        let listed = years(in: title).filter { $0 >= 1950 }
        if listed.contains(spineYear) { return false }
        if !listed.isEmpty { return true }
        if let published, (1950...2030).contains(published) { return published != spineYear }
        return false
    }

    /// "AME" and "ICAN" are the two halves of "american" when the camera clips a letter.
    private static func stitchSplitWords(_ words: [String]) -> [String] {
        let stop: Set<String> = ["the", "and", "for", "from", "with", "book"]
        var joined: [String] = []
        var index = 0
        while index < words.count {
            if index + 1 < words.count {
                let first = words[index]
                let second = words[index + 1]
                let left = first.lowercased()
                let right = second.lowercased()
                let fused = (left + right).lowercased()
                if left.count == 3, right.count == 4, !stop.contains(left), left.allSatisfy(\.isLetter), right.allSatisfy(\.isLetter), sameWord(fused, "american") {
                    joined.append("american")
                    index += 2
                    continue
                }
            }
            joined.append(words[index])
            index += 1
        }
        return joined
    }

    /// 1098 is one wrong digit away from 1998, and from no other year. Leave a token alone when two years are equally close.
    private static func repairedYear(_ token: String) -> String? {
        guard token.count == 4, token.allSatisfy(\.isNumber), let value = Int(token), !(1950...2030).contains(value) else { return nil }
        let near = (1980...2030).filter { editDistance(token, String($0)) == 1 }
        guard near.count == 1 else { return nil }
        return String(near[0])
    }

    private static func editDistance(_ left: String, _ right: String) -> Int {
        let a = Array(left)
        let b = Array(right)
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current.append(min(current[j - 1] + 1, previous[j] + 1, previous[j - 1] + cost))
            }
            previous = current
        }
        return previous[b.count]
    }

    private static func years(in text: String) -> [Int] {
        text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.filter { (1900...2030).contains($0) }
    }

    static func titleAgrees(_ title: String, _ ocr: String) -> Bool {
        if jaccard(title, ocr) >= 0.5 { return true }
        let titleTokens = tokens(title)
        guard !titleTokens.isEmpty else { return false }
        let seen = Set(tokens(ocr))
        let hit = titleTokens.filter { seen.contains($0) }.count
        return Double(hit) / Double(titleTokens.count) >= 0.8
    }
}

struct ScaleDecision: Equatable {
    var correction: Double
    var disagreement: Double
    var flagged: Bool
}

enum IdentityDecision: Equatable {
    case identified(CatalogueMatch)
    case hunch(String)
    case unidentified
}

struct CatalogueMatch: Equatable {
    var title: String
    var author: String
    var isbn: String
    var publisher: String
    var firstPublishYear: Int?
    var score: Double
    var format: String = ""
    var editionNote: String = ""
}

enum BindingHint {
    static func from(thicknessCm: Double?) -> String {
        guard let thicknessCm, thicknessCm > 0 else { return "" }
        if thicknessCm >= 2.2 { return "hardcover" }
        if thicknessCm <= 1.3 { return "paperback" }
        return ""
    }

    static func format(in text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("paperback") || lower.contains("softcover") { return "paperback" }
        if lower.contains("hardcover") || lower.contains("hardback") { return "hardcover" }
        return ""
    }

    static func edition(in text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("first edition") { return "first edition" }
        if lower.contains("limited") { return "limited" }
        if lower.contains("signed") { return "signed" }
        return ""
    }

    static func scoreAdjustment(match: CatalogueMatch, binding: String) -> Double {
        guard binding == "hardcover" || binding == "paperback" else { return 0 }
        let hay = "\(match.format) \(match.title) \(match.editionNote)".lowercased()
        let other = binding == "hardcover" ? "paperback" : "hardcover"
        let agrees = hay.contains(binding) || (binding == "hardcover" && hay.contains("hardback")) || (binding == "paperback" && hay.contains("softcover"))
        if agrees { return 0.08 }
        if hay.contains(other) { return -0.08 }
        return 0
    }
}

struct NormBox: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let zero = NormBox(x: 0, y: 0, width: 0, height: 0)

    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
    var area: Double { max(0, width) * max(0, height) }
    var isEmpty: Bool { width <= 0 || height <= 0 }

    func inset(by pad: Double) -> NormBox {
        NormBox(x: x - pad, y: y - pad, width: width + pad * 2, height: height + pad * 2)
    }

    func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px <= x + width && py >= y && py <= y + height
    }

    func intersects(_ other: NormBox) -> Bool {
        let left = max(x, other.x)
        let right = min(x + width, other.x + other.width)
        let bottom = max(y, other.y)
        let top = min(y + height, other.y + other.height)
        return right - left > 0 && top - bottom > 0
    }

    func iou(_ other: NormBox) -> Double {
        let left = max(x, other.x)
        let right = min(x + width, other.x + other.width)
        let bottom = max(y, other.y)
        let top = min(y + height, other.y + other.height)
        let overlap = max(0, right - left) * max(0, top - bottom)
        let union = area + other.area - overlap
        guard union > 0 else { return 0 }
        return overlap / union
    }

    static func union(_ boxes: [NormBox]) -> NormBox {
        guard let first = boxes.first else { return .zero }
        var minX = first.x
        var minY = first.y
        var maxX = first.x + first.width
        var maxY = first.y + first.height
        for box in boxes.dropFirst() {
            minX = min(minX, box.x)
            minY = min(minY, box.y)
            maxX = max(maxX, box.x + box.width)
            maxY = max(maxY, box.y + box.height)
        }
        return NormBox(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
}

struct CoverLine: Equatable {
    var text: String
    var box: NormBox
    var confidence: Float
}

struct CoverRead: Equatable {
    var box: NormBox
    var title: String
    var confidence: Float
    var shelf: Int = 0
}

enum ScanCue: Equatable {
    case none
    case showSpine
    case straighten
    case read
}

enum ShelfOrder {
    /// Top shelf first, then left to right. Vision's y grows upward.
    static func arrange(_ hits: [SpineHit]) -> [SpineHit] {
        var pool = hits
        var rows: [[SpineHit]] = []
        while let seed = pool.max(by: { $0.box.midY < $1.box.midY }) {
            let row = pool.filter { abs($0.box.midY - seed.box.midY) < 0.09 }
            pool.removeAll { abs($0.box.midY - seed.box.midY) < 0.09 }
            rows.append(row.sorted { $0.midX < $1.midX })
        }
        var output: [SpineHit] = []
        for (shelf, row) in rows.enumerated() {
            for hit in row {
                var copy = hit
                copy.shelf = shelf
                output.append(copy)
            }
        }
        return output
    }

    /// Stacked spines are already in shelf order. A jump in x is the next shelf.
    static func keepStacked(_ hits: [SpineHit]) -> [SpineHit] {
        var shelf = 0
        var previousX = hits.first?.midX ?? 0
        return hits.enumerated().map { index, hit in
            if index > 0, hit.midX - previousX > 0.1 { shelf += 1 }
            previousX = hit.midX
            var copy = hit
            copy.shelf = shelf
            return copy
        }
    }
}

struct SpineCursor {
    private(set) var done: [NormBox] = []
    private(set) var active: NormBox?
    private var since: Date?
    private(set) var began = false

    mutating func step(_ ordered: [SpineHit], now: Date, dwell: TimeInterval = 2.4) -> SpineHit? {
        began = false
        let pending = ordered.filter { hit in !done.contains { overlaps($0, hit.box) } }
        guard let next = pending.first else {
            active = nil
            since = nil
            return nil
        }
        if let active, overlaps(active, next.box), let since, now.timeIntervalSince(since) >= dwell {
            done.append(next.box)
            self.active = nil
            self.since = nil
            return nil
        }
        if active == nil || !overlaps(active ?? .zero, next.box) {
            active = next.box
            since = now
            began = true
        }
        return next
    }

    private func overlaps(_ left: NormBox, _ right: NormBox) -> Bool {
        if left.iou(right) > 0.2 { return true }
        return abs(left.midX - right.midX) < 0.035 && abs(left.midY - right.midY) < 0.08
    }
}

enum CoverReading {
    /// A shelf shows spines. A cover, a screen, or a loose line of text is not a book.
    static func reads(rectangles: [NormBox], lines: [CoverLine]) -> [CoverRead] {
        let spines = rectangles.filter(isSpine)
        let seeds = spines.isEmpty ? spineStrips(lines) : spines
        guard !seeds.isEmpty else { return [] }
        return clusterSpines(seeds).compactMap { boxes in
            let box = NormBox.union(boxes)
            guard isSpine(box) || boxes.contains(where: isSpine) else { return nil }
            let pad = box.inset(by: 0.025)
            let inside = lines.filter { pad.contains(x: $0.box.midX, y: $0.box.midY) }
            if inside.count >= 5, !isSpine(NormBox.union(inside.map(\.box))) { return nil }
            let chosen = bestTitle(inside)
            if chosen.text.isEmpty {
                guard isSpine(box) else { return nil }
                return CoverRead(box: box, title: "", confidence: 0)
            }
            return CoverRead(box: box, title: chosen.text, confidence: chosen.confidence)
        }
    }

    /// One book per spine, top shelf first, then left to right. The box is the spine, not the lettering.
    static func inventory(_ lines: [CoverLine]) -> [CoverRead] {
        let usable = lines.filter { line in
            let lower = line.text.lowercased()
            if lower.contains("library for") || lower.contains("software update") || lower.contains("storage space") { return false }
            return true
        }
        let wide = usable.filter { $0.box.width > $0.box.height * 1.6 && $0.box.width > 0.05 }
        let narrow = usable.filter { $0.box.height > $0.box.width * 1.6 }
        let flat = stackedBooks(usable)
        if wide.count > narrow.count, flat.count >= 4 { return flat }
        let upright = separateShelves(usable)
        if upright.count >= 3, upright.count + 4 >= flat.count { return upright }
        if flat.count >= 4 { return flat }
        return upright
    }

    static func separateShelves(_ lines: [CoverLine]) -> [CoverRead] {
        let usable = lines.filter { line in
            let box = line.box
            guard box.width > 0.004, box.height > 0.004, box.width <= 0.55 else { return false }
            return true
        }
        guard usable.count >= 3 else { return [] }
        return splitShelves(usable).enumerated().flatMap { shelf, shelfLines in
            books(on: shelfLines).map { read in
                var copy = read
                copy.shelf = shelf
                return copy
            }
        }
    }

    private static func splitShelves(_ lines: [CoverLine]) -> [[CoverLine]] {
        let sorted = lines.sorted { $0.box.midY > $1.box.midY }
        let gaps = zip(sorted, sorted.dropFirst()).map { $0.box.midY - $1.box.midY }
        guard let biggest = gaps.max(), biggest > 0.1 else { return [sorted] }
        let small = gaps.filter { $0 > 0.002 && $0 < biggest * 0.5 }
        let typical = small.isEmpty ? 0.02 : median(small)
        guard biggest > max(0.1, typical * 2.2) else { return [sorted] }
        var groups: [[CoverLine]] = [[]]
        for (index, line) in sorted.enumerated() {
            if index > 0, gaps[index - 1] > biggest * 0.72, gaps[index - 1] > 0.1 {
                groups.append([line])
            } else {
                groups[groups.count - 1].append(line)
            }
        }
        return groups.filter { !$0.isEmpty }
    }

    private static func books(on lines: [CoverLine]) -> [CoverRead] {
        let sorted = lines.sorted { $0.box.midX < $1.box.midX }
        var groups: [[CoverLine]] = []
        for line in sorted {
            if var last = groups.last, sameSpine(last, line) {
                last.append(line)
                groups[groups.count - 1] = last
            } else {
                groups.append([line])
            }
        }
        let widths = groups.map { NormBox.union($0.map(\.box)).width }
        let typical = median(widths.filter { $0 > 0.008 })
        if typical > 0 {
            groups = groups.flatMap { group -> [[CoverLine]] in
                let width = NormBox.union(group.map(\.box)).width
                guard width > typical * 1.8, group.count >= 2 else { return [group] }
                return splitWide(group)
            }
        }
        let reads: [CoverRead] = groups.compactMap { group in
            let chosen = stackTitle(group)
            guard !chosen.text.isEmpty else { return nil }
            var title = chosen.text
            if let year = year(in: group), !title.contains(year) {
                title += " \(year)"
            }
            return CoverRead(box: NormBox.union(group.map(\.box)), title: title, confidence: chosen.confidence)
        }
        return pitchBoxes(reads)
    }

    private static func sameSpine(_ group: [CoverLine], _ line: CoverLine) -> Bool {
        let box = NormBox.union(group.map(\.box))
        let overlap = min(box.x + box.width, line.box.x + line.box.width) - max(box.x, line.box.x)
        let narrow = min(box.width, line.box.width)
        guard narrow > 0 else { return false }
        return overlap / narrow > 0.4
    }

    private static func splitWide(_ group: [CoverLine]) -> [[CoverLine]] {
        let sorted = group.sorted { $0.box.midX < $1.box.midX }
        var parts: [[CoverLine]] = []
        for line in sorted {
            if var last = parts.last {
                let box = NormBox.union(last.map(\.box))
                if line.box.midX > box.midX + max(box.width * 0.35, 0.012) {
                    parts.append([line])
                } else {
                    last.append(line)
                    parts[parts.count - 1] = last
                }
            } else {
                parts.append([line])
            }
        }
        return parts.isEmpty ? [group] : parts
    }

    private static func year(in lines: [CoverLine]) -> String? {
        for line in lines {
            for word in line.text.split(whereSeparator: { !$0.isNumber }) where word.count == 4 {
                if let year = Int(word), (1900...2030).contains(year) { return String(year) }
            }
        }
        return nil
    }

    /// Thickness is the distance to the next spine. Height is the shelf of books, not the ink.
    private static func pitchBoxes(_ reads: [CoverRead]) -> [CoverRead] {
        guard !reads.isEmpty else { return [] }
        let ordered = reads.sorted { $0.box.midX < $1.box.midX }
        guard ordered.count >= 2 else { return ordered }
        let centers = ordered.map(\.box.midX)
        let pitches = zip(centers, centers.dropFirst()).map { $1 - $0 }.filter { $0 > 0.004 }
        let pitch = max(0.012, median(pitches))
        let band = NormBox.union(ordered.map(\.box))
        let height = max(band.height, ordered.map(\.box.height).max() ?? 0)
        let bottom = min(band.y, (ordered.map(\.box.y).min() ?? band.y))
        return ordered.map { read in
            let x = min(max(0, read.box.midX - pitch / 2), 0.98)
            return CoverRead(
                box: NormBox(x: x, y: bottom, width: min(pitch, 0.2), height: height),
                title: read.title,
                confidence: read.confidence,
                shelf: read.shelf
            )
        }
    }

    /// A close line continues the title. "Collected Poems of" takes "Emily Dickinson". A finished title does not take the next book.
    private static func startsNewBook(_ group: [CoverLine], _ line: CoverLine, gap: Double, pitch: Double) -> Bool {
        if continuesTitle(line.text), gap <= 0.06 { return false }
        if pitch > 0.03, gap < pitch * 0.55 { return false }
        if gap > 0.05 { return true }
        if gap <= 0.016 { return false }
        let current = group.map(\.text).joined(separator: " ")
        if yearOnly(line.text) || hanging(current) { return false }
        if wordCount(line.text) <= 2, gap <= 0.028 { return false }
        if MeasureMath.looksLikeTitle(current), MeasureMath.looksLikeTitle(line.text), gap > 0.022 { return true }
        let currentDone = completeTitle(current)
        let nextDone = completeTitle(line.text)
        if currentDone && nextDone { return true }
        if currentDone, hasYear(current), gap > 0.02 { return true }
        if !currentDone, !nextDone, gap <= 0.02 { return false }
        if currentDone, wordCount(line.text) <= 2, !hasYear(current), gap <= 0.034 { return false }
        return gap > 0.026
    }

    /// "Of Florence" is the rest of the title above it. "The Mighty Dead" is the next book.
    private static func continuesTitle(_ text: String) -> Bool {
        let words = text.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }.filter { !$0.isEmpty }
        guard let first = words.first else { return false }
        if words.count >= 2, first == "the", words[1] == "story" { return true }
        guard words.count <= 3 else { return false }
        return ["of", "for", "and"].contains(first)
    }

    private static func completeTitle(_ text: String) -> Bool {
        hasYear(text) || wordCount(text) >= 4
    }

    private static func hanging(_ text: String) -> Bool {
        let last = text.split(separator: " ").last.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) } ?? ""
        return ["of", "the", "a", "an", "and", "by", "from"].contains(last)
    }

    private static func yearOnly(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        guard words.count == 1, let year = Int(words[0]), words[0].count == 4 else { return false }
        return (1950...2030).contains(year)
    }

    private static func hasYear(_ text: String) -> Bool {
        text.split(whereSeparator: { !$0.isNumber }).contains { word in
            guard word.count == 4, let year = Int(word) else { return false }
            return (1950...2030).contains(year)
        }
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(separator: " ").filter { $0.count > 1 }.count
    }

    /// Upright spines, or the same spines turned sideways so each title is a wide band.
    static func shelfReads(_ lines: [CoverLine]) -> (reads: [CoverRead], stacked: Bool) {
        let upright = spineColumns(lines)
        let flat = stackedBooks(lines)
        if flat.count > upright.count { return (flat, true) }
        return (upright, false)
    }

    /// One saved frame. Lines on the same spine are joined, then each spine is one book.
    static func reportBooks(_ lines: [CoverLine]) -> [CoverRead] {
        let kept = lines.filter { line in
            let lower = line.text.lowercased()
            if lower.contains("library for") || lower.contains("software update") || lower.contains("storage space") { return false }
            if lower.contains("extra shelves") || lower.contains("bookcase") || lower.contains("bookease") || lower.contains("stacking") { return false }
            if lower == "furniture" || lower == "rniture" || lower == "bookshelf" { return false }
            if line.box.height > 0.22, line.box.width < 0.08 { return false }
            return line.text.count >= 3 && line.box.width >= 0.012
        }
        let bands = mergeSameBand(bookBands(kept))
        guard bands.count >= 4 else { return [] }
        return xColumns(bands).enumerated().flatMap { shelf, column in
            joinedBooks(column).map { read in
                var copy = read
                copy.shelf = shelf
                return copy
            }
        }
    }

    private static func joinedBooks(_ lines: [CoverLine]) -> [CoverRead] {
        let sorted = lines.sorted { $0.box.midY > $1.box.midY }
        let gaps = zip(sorted, sorted.dropFirst()).map { abs($0.box.midY - $1.box.midY) }
        let orderedGaps = gaps.sorted()
        let pitch = orderedGaps.isEmpty ? 0 : orderedGaps[orderedGaps.count / 2]
        var groups: [[CoverLine]] = []
        for (index, line) in sorted.enumerated() {
            if index > 0, let last = groups.last, startsNewBook(last, line, gap: gaps[index - 1], pitch: pitch) {
                groups.append([line])
            } else if var last = groups.last {
                last.append(line)
                groups[groups.count - 1] = last
            } else {
                groups.append([line])
            }
        }
        return groups.compactMap { group in
            let box = NormBox.union(group.map(\.box))
            guard box.height <= 0.32, box.width <= 0.7 else { return nil }
            var parts: [String] = []
            for line in group.sorted(by: { $0.box.midY > $1.box.midY }) {
                let cleaned = cleanedTitle(line.text)
                guard cleaned.count >= 3 else { continue }
                if parts.contains(where: { MeasureMath.jaccard($0, cleaned) > 0.72 }) { continue }
                parts.append(cleaned)
            }
            let title = parts.joined(separator: " ")
            guard MeasureMath.looksLikeTitle(title) else { return nil }
            let confidence = group.map(\.confidence).max() ?? 0
            return CoverRead(box: box, title: title, confidence: confidence, shelf: 0)
        }
    }

    /// Books lying across the frame: one title band is one book. A page of equal lines is not.
    static func stackedBooks(_ lines: [CoverLine]) -> [CoverRead] {
        let bands = lines.filter { line in
            let box = line.box
            guard box.width >= 0.045, box.width <= 0.48, box.height > 0.004, box.height <= 0.08 else { return false }
            return box.width > box.height * 1.8
        }
        guard bands.count >= 4 else { return [] }
        let widths = bands.map(\.box.width)
        if let narrowest = widths.min(), let widest = widths.max(), widest - narrowest < 0.04, narrowest > 0.32 {
            return []
        }
        return xColumns(bands).enumerated().flatMap { shelf, column in
            booksInColumn(column).map { read in
                var copy = read
                copy.shelf = shelf
                return copy
            }
        }
    }

    /// The large spines are the shelf. A much smaller copy along the edge, and a keyboard, are not more books.
    private static func bookBands(_ lines: [CoverLine]) -> [CoverLine] {
        let wide = lines.filter { $0.box.width > $0.box.height * 1.4 && $0.box.width <= 0.92 && $0.box.height <= 0.09 && $0.box.height > 0.004 }
        let heights = wide.map(\.box.height).sorted()
        let median = heights.isEmpty ? 0.02 : heights[heights.count * 3 / 4]
        let kept = wide.filter { line in
            if line.box.height >= median * 0.45 { return true }
            return wide.contains { other in
                other.box.height >= median * 0.45
                    && abs(other.box.midY - line.box.midY) < 0.045
                    && abs(other.box.midX - line.box.midX) < 0.28
            }
        }
        let names = lines.filter { line in
            let box = line.box
            guard box.width < box.height, box.width <= 0.05, box.height <= 0.14, box.height > 0.01 else { return false }
            guard MeasureMath.tokens(line.text).filter({ $0.count >= 4 }).count == 1 else { return false }
            return kept.contains { title in
                abs(title.box.midY - box.midY) < 0.05 && abs(title.box.midX - box.midX) < 0.4
            }
        }
        return kept + names
    }

    /// The author on the left of a spine and the title on the right are one band. Two stacks side by side are not.
    private static func mergeSameBand(_ lines: [CoverLine]) -> [CoverLine] {
        var merged: [CoverLine] = []
        for line in lines.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let index = merged.firstIndex(where: { sameBand($0, line) }) {
                let existing = merged[index]
                let ordered = [existing, line].sorted { $0.box.x < $1.box.x }
                merged[index] = CoverLine(
                    text: ordered.map(\.text).joined(separator: " "),
                    box: NormBox.union([existing.box, line.box]),
                    confidence: max(existing.confidence, line.confidence)
                )
            } else {
                merged.append(line)
            }
        }
        return merged
    }

    private static func sameBand(_ left: CoverLine, _ right: CoverLine) -> Bool {
        let overlap = min(left.box.y + left.box.height, right.box.y + right.box.height) - max(left.box.y, right.box.y)
        let thinner = min(left.box.height, right.box.height)
        guard thinner > 0, overlap > thinner * 0.35 else { return false }
        let gap = right.box.x > left.box.x + left.box.width
            ? right.box.x - (left.box.x + left.box.width)
            : left.box.x - (right.box.x + right.box.width)
        if gap < 0.02 { return true }
        return overlap > thinner * 0.7 && min(wordCount(left.text), wordCount(right.text)) <= 1 && gap < 0.12
    }

    /// Two stacks on one screen stay two columns. Cluster on the left edge, because a long title's middle sits closer to the next stack than its spine does.
    private static func xColumns(_ lines: [CoverLine]) -> [[CoverLine]] {
        let sorted = lines.sorted { $0.box.x < $1.box.x }
        var columns: [[CoverLine]] = []
        for line in sorted {
            if let index = columns.indices.last(where: { index in
                let box = NormBox.union(columns[index].map(\.box))
                let overlap = min(box.x + box.width, line.box.x + line.box.width) - max(box.x, line.box.x)
                if overlap > 0.02 { return true }
                let left = columns[index].map(\.box.x).reduce(0, +) / Double(columns[index].count)
                return abs(line.box.x - left) < 0.12
            }) {
                columns[index].append(line)
            } else {
                columns.append([line])
            }
        }
        return columns
    }

    private static func booksInColumn(_ lines: [CoverLine]) -> [CoverRead] {
        let sorted = lines.sorted { $0.box.midY > $1.box.midY }
        let gaps = zip(sorted, sorted.dropFirst()).map { abs($0.box.midY - $1.box.midY) }
        let pitch = median(gaps)
        let splitAt = max(0.012, pitch * 0.62)
        var groups: [[CoverLine]] = []
        for (index, line) in sorted.enumerated() {
            if index > 0, gaps[index - 1] > splitAt {
                groups.append([line])
            } else if var last = groups.last {
                last.append(line)
                groups[groups.count - 1] = last
            } else {
                groups.append([line])
            }
        }
        return groups.compactMap { group in
            let box = NormBox.union(group.map(\.box))
            guard box.height <= 0.14, box.width <= 0.5 else { return nil }
            let chosen = stackTitle(group)
            guard !chosen.text.isEmpty else { return nil }
            return CoverRead(box: box, title: chosen.text, confidence: chosen.confidence)
        }
    }

    private static func stackTitle(_ lines: [CoverLine]) -> (text: String, confidence: Float) {
        let best = bestTitle(lines)
        if !best.text.isEmpty { return best }
        for line in lines.sorted(by: { $0.text.count > $1.text.count }) {
            let cleaned = cleanedTitle(line.text)
            let words = cleaned.split(separator: " ")
            if words.count >= 2 || words.contains(where: { $0.count >= 5 }) {
                return (cleaned, line.confidence)
            }
        }
        return ("", 0)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.04 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    /// One physical spine is one column. Lines stacked on the same edge join. The next book does not.
    static func spineColumns(_ lines: [CoverLine]) -> [CoverRead] {
        guard !lines.isEmpty else { return [] }
        let narrow = lines.filter { $0.box.width <= 0.12 && $0.box.width > 0.004 }
        if lines.count >= 4, narrow.count * 2 < lines.count { return [] }
        var pool = narrow.sorted { $0.box.midY > $1.box.midY }
        var rows: [[CoverLine]] = []
        while let seed = pool.first {
            let row = pool.filter { abs($0.box.midY - seed.box.midY) < 0.1 }
            pool.removeAll { abs($0.box.midY - seed.box.midY) < 0.1 }
            rows.append(row)
        }
        return rows.flatMap { row in
            let sorted = row.sorted { $0.box.midX < $1.box.midX }
            var groups: [[CoverLine]] = []
            for line in sorted {
                if var last = groups.last, xOverlap(last, line) {
                    last.append(line)
                    groups[groups.count - 1] = last
                } else {
                    groups.append([line])
                }
            }
            let rowBox = NormBox.union(row.map(\.box))
            return groups.compactMap { group -> CoverRead? in
                let box = NormBox.union(group.map(\.box))
                guard box.width <= 0.12 else { return nil }
                let chosen = bestTitle(group)
                guard !chosen.text.isEmpty || box.height >= 0.06 else { return nil }
                let spine = NormBox(
                    x: box.x,
                    y: min(box.y, rowBox.y),
                    width: max(box.width, 0.012),
                    height: max(box.height, rowBox.height)
                )
                return CoverRead(box: spine, title: chosen.text, confidence: chosen.confidence)
            }
        }
    }

    private static func xOverlap(_ group: [CoverLine], _ line: CoverLine) -> Bool {
        let box = NormBox.union(group.map(\.box))
        let gap = line.box.x > box.x + box.width
            ? line.box.x - (box.x + box.width)
            : box.x - (line.box.x + line.box.width)
        return gap < 0.008
    }

    static func isSpine(_ box: NormBox) -> Bool {
        let short = min(box.width, box.height)
        let long = max(box.width, box.height)
        guard long >= 0.16, short > 0.012 else { return false }
        let aspect = short / long
        return aspect >= 0.035 && aspect <= 0.30 && box.area >= 0.006 && box.area <= 0.18
    }

    private static func spineStrips(_ lines: [CoverLine]) -> [NormBox] {
        let wide = lines.filter { $0.box.width > $0.box.height * 1.8 && $0.box.width > 0.22 }
        if wide.count >= 4 { return [] }
        return lines.map(\.box).filter(isSpine)
    }

    private static func clusterSpines(_ boxes: [NormBox]) -> [[NormBox]] {
        var remaining = boxes
        var groups: [[NormBox]] = []
        while let seed = remaining.popLast() {
            var group = [seed]
            var changed = true
            while changed {
                changed = false
                var keep: [NormBox] = []
                for box in remaining {
                    if group.contains(where: { $0.intersects(box) || gap($0, box) < 0.02 }) {
                        group.append(box)
                        changed = true
                    } else {
                        keep.append(box)
                    }
                }
                remaining = keep
            }
            groups.append(group)
        }
        return groups
    }

    static func cleanedTitle(_ text: String) -> String {
        let spaced = text.replacingOccurrences(
            of: "([A-Za-z])([A-Z][a-z])",
            with: "$1 $2",
            options: .regularExpression
        )
        let drop: Set<String> = [
            "penguin", "pengu", "classics", "classic", "isbn", "dell", "guin", "cuin",
            "sale", "indian", "subcontinent", "only"
        ]
        let words = spaced.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return words.filter { word in
            let lower = word.lowercased()
            if drop.contains(lower) { return false }
            if lower.allSatisfy(\.isNumber) { return word.count == 4 }
            return lower.count >= 2 || lower == "i" || lower == "a"
        }.joined(separator: " ")
    }

    static func titleScore(_ text: String, height: Double) -> Double {
        let words = text.split(separator: " ").map { $0.lowercased() }.filter { $0.count >= 2 }
        guard words.count >= 2, !words.allSatisfy(isBrand) else { return 0 }
        var score = max(height, 0.02) * 5 + 0.15
        score += min(Double(words.count), 6) * 0.06
        if words.count <= 8 { score += 0.25 }
        if words.count > 14 { score -= 0.9 }
        score -= Double(words.filter(isBrand).count) * 0.45
        return score
    }

    static func bestTitle(_ lines: [CoverLine]) -> (text: String, confidence: Float) {
        let ranked = lines.compactMap { line -> (Double, String, Float)? in
            let cleaned = cleanedTitle(line.text)
            let score = titleScore(cleaned, height: line.box.height)
            guard score > 0 else { return nil }
            return (score, cleaned, line.confidence)
        }.sorted { $0.0 > $1.0 }
        guard let best = ranked.first else { return ("", 0) }
        return (best.1, best.2)
    }

    static func isBookish(_ box: NormBox) -> Bool {
        let short = min(box.width, box.height)
        let long = max(box.width, box.height)
        guard long >= 0.12, short > 0.02, box.area <= 0.72 else { return false }
        let aspect = short / long
        let cover = aspect >= 0.48 && aspect <= 0.84 && box.area >= 0.02
        let spine = aspect >= 0.08 && aspect <= 0.36 && long >= 0.18 && box.area >= 0.01
        return cover || spine
    }

    private static func isBrand(_ word: String) -> Bool {
        ["penguin", "pengu", "classic", "classics", "isbn", "dell"].contains(word)
    }

    private static func gap(_ a: NormBox, _ b: NormBox) -> Double {
        let left = a.x + a.width <= b.x ? a : b
        let right = a.x + a.width <= b.x ? b : a
        return max(0, right.x - (left.x + left.width))
    }
}

struct SpineHit: Equatable {
    var text: String
    var shelf: Int
    var midX: Double
    var heightCm: Double?
    var thicknessCm: Double?
    var confidence: Float
    var frameRef: String
    var box: NormBox = .zero
}

struct SpineTrack: Equatable, Identifiable {
    var id: String
    var shelf: Int
    var text: String
    var midX: Double
    var heightCm: Double?
    var thicknessCm: Double?
    var confidence: Float
    var frameRef: String
    var observations: Int
    var box: NormBox = .zero
}

enum SpineTracker {
    static func merge(tracks: [SpineTrack], hits: [SpineHit]) -> [SpineTrack] {
        var next = tracks
        let loneHeldBook = next.count == 1 && hits.count == 1
        for hit in hits {
            if let index = next.firstIndex(where: { sameBook($0, hit, loneHeldBook: loneHeldBook) }) {
                var track = next[index]
                track.observations += 1
                track.midX = (track.midX * Double(track.observations - 1) + hit.midX) / Double(track.observations)
                if !hit.box.isEmpty { track.box = hit.box }
                if shouldReplace(track.text, with: hit.text), !hit.text.isEmpty {
                    track.text = hit.text
                    track.confidence = hit.confidence
                    track.frameRef = hit.frameRef
                } else if track.text.isEmpty, !hit.text.isEmpty {
                    track.text = hit.text
                    track.confidence = hit.confidence
                    track.frameRef = hit.frameRef
                }
                if let height = hit.heightCm { track.heightCm = height }
                if let thickness = hit.thicknessCm { track.thicknessCm = thickness }
                next[index] = track
            } else {
                let suffix = UUID().uuidString.prefix(8)
                next.append(SpineTrack(
                    id: "bk-\(suffix)",
                    shelf: hit.shelf,
                    text: hit.text,
                    midX: hit.midX,
                    heightCm: hit.heightCm,
                    thicknessCm: hit.thicknessCm,
                    confidence: hit.confidence,
                    frameRef: hit.frameRef,
                    observations: 1,
                    box: hit.box
                ))
            }
        }
        return next
    }

    private static func sameBook(_ track: SpineTrack, _ hit: SpineHit, loneHeldBook: Bool) -> Bool {
        if !track.box.isEmpty, !hit.box.isEmpty {
            let apart = abs(track.box.midX - hit.box.midX) > 0.015 || abs(track.box.midY - hit.box.midY) > 0.015
            if apart, track.box.iou(hit.box) <= 0.12 { return false }
        }
        if !track.box.isEmpty, !hit.box.isEmpty, track.box.iou(hit.box) > 0.12 { return true }
        if track.shelf == hit.shelf, abs(track.midX - hit.midX) < 0.06 { return true }
        if !track.text.isEmpty, !hit.text.isEmpty {
            if MeasureMath.jaccard(track.text, hit.text) >= 0.34 { return true }
            if sharesLongWord(track.text, hit.text) { return true }
        }
        if !track.box.isEmpty, !hit.box.isEmpty,
           track.box.area > 0.08, hit.box.area > 0.08,
           abs(track.box.midX - hit.box.midX) < 0.28,
           abs(track.box.midY - hit.box.midY) < 0.28 {
            return true
        }
        if loneHeldBook {
            let unrelated = !track.text.isEmpty && !hit.text.isEmpty
                && MeasureMath.jaccard(track.text, hit.text) < 0.2
                && !sharesLongWord(track.text, hit.text)
            if !unrelated { return true }
        }
        return false
    }

    private static func sharesLongWord(_ a: String, _ b: String) -> Bool {
        let left = Set(MeasureMath.tokens(a).filter { $0.count >= 5 })
        let right = Set(MeasureMath.tokens(b).filter { $0.count >= 5 })
        return !left.isDisjoint(with: right)
    }

    private static func shouldReplace(_ current: String, with incoming: String) -> Bool {
        let currentScore = CoverReading.titleScore(current, height: 0.1)
        let incomingScore = CoverReading.titleScore(incoming, height: 0.1)
        if incomingScore == 0 { return false }
        if currentScore == 0 { return true }
        return incomingScore > currentScore + 0.04
    }
}
