import Foundation

enum Correction: Equatable {
    case countryUSD
    case confirmHunch
    case firstEdition
    case skipShelf
    case isPrint
    case isOriginal
    case moreBooks
    case closer
    case none
}

enum CorrectionParser {
    static func parse(_ text: String) -> Correction {
        let line = text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mentionsShelf = line.contains("shelf") || line.contains("shelves")
        let wantsMore = line.contains("more") || line.contains("two") || line.contains("another") || line.contains("second") || line.contains("missed") || line.contains("only")
        if line.contains("more book") || line.contains("not done") || line.contains("keep going") || (mentionsShelf && wantsMore) {
            return .moreBooks
        }
        if line.contains("closer") || line.contains("come forward") || line.contains("up front") || line.contains("move in") || line.contains("step in") || line.contains("a little up") {
            return .closer
        }
        if line.contains("first edition") { return .firstEdition }
        if line.contains("not mine") || (line.contains("skip") && line.contains("shelf")) { return .skipShelf }
        if line.contains("print") { return .isPrint }
        if line.contains("original") { return .isOriginal }
        if line.contains("united states") || line.contains("us dollar") || line == "usd" || line == "dollars" {
            return .countryUSD
        }
        if line.contains("thats the one") || line.contains("that is the one") || line.contains("yes that") || line.contains("confirm") {
            return .confirmHunch
        }
        if line == "yes" || line == "yeah" || line == "yep" { return .confirmHunch }
        return .none
    }

    /// "two shelves, 15 to 20 books" is a count, not a new command to restart.
    static func expectation(_ text: String) -> (shelves: Int?, books: Int?) {
        let raw = text.lowercased()
        let line = raw.replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
        let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30]
        func value(_ word: String) -> Int? { Int(word) ?? words[word] }
        var shelves: Int?
        var books: Int?
        let tokens = line.split(separator: " ").map(String.init)
        for (index, token) in tokens.enumerated() where index > 0 {
            if token == "shelf" || token == "shelves" || token == "selves" || token == "elves" || token == "shells" || token == "cells", let number = value(tokens[index - 1]) { shelves = number }
            if token == "books", let number = value(tokens[index - 1]) { books = max(books ?? 0, number) }
            if token == "book", let number = value(tokens[index - 1]) {
                let next = index + 1 < tokens.count ? tokens[index + 1] : ""
                if value(next) == nil { books = max(books ?? 0, number) }
            }
        }
        if let match = line.range(of: #"(\d+) to (\d+)"#, options: .regularExpression) {
            let parts = line[match].split(separator: " ")
            if let high = parts.last.flatMap({ Int($0) }) { books = max(books ?? 0, high) }
        }
        return (shelves, books)
    }

    /// "shelf one book one" is a place they are showing, not a new total.
    static func shownShelf(_ text: String) -> Int? {
        let line = text.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
        let words = ["one": 1, "two": 2, "three": 3, "four": 4, "first": 1, "second": 2]
        let tokens = line.split(separator: " ").map(String.init)
        var found: Int?
        for (index, token) in tokens.enumerated() where token == "shelf" || token == "shelves" || token == "selves" {
            if index + 1 < tokens.count, let number = Int(tokens[index + 1]) ?? words[tokens[index + 1]] {
                found = number
            }
        }
        return found
    }
}
