import SwiftUI
import TipKit

/// One walkthrough. Closing a tip, or using the control it points at, moves `step` forward.
enum Walkthrough {
    @Parameter static var step: Int = 0

    static func advance(to next: Int) {
        if step < next { step = next }
    }

    static func watch<T: Tip>(_ tip: T, advanceTo next: Int) async {
        for await status in tip.statusUpdates {
            if case .invalidated = status {
                advance(to: next)
            }
        }
    }

    static var once: [any TipOption] {
        [Tips.MaxDisplayCount(1), Tips.IgnoresDisplayFrequency(true)]
    }
}

struct StartWalkTip: Tip {
    var title: Text { Text("Scan shelves") }
    var message: Text? { Text("Show each shelf in this room. Sweep reads the books as you go.") }
    var image: Image? { Image(systemName: "books.vertical") }
    var options: [any TipOption] { Walkthrough.once }
}

struct EndWalkTip: Tip {
    var title: Text { Text("End the scan") }
    var message: Text? { Text("When the room is done, stop. Sweep reads the saved frames and files the books.") }
    var image: Image? { Image(systemName: "checkmark.circle") }
    var options: [any TipOption] { Walkthrough.once }
}

struct ReviewTip: Tip {
    var title: Text { Text("Check hunches") }
    var message: Text? { Text("Unsure books wait here. Keep a title that is right, or remove it.") }
    var image: Image? { Image(systemName: "checklist") }
    var rules: [Rule] { #Rule(Walkthrough.$step) { $0 >= 1 } }
    var options: [any TipOption] { Walkthrough.once }
}

struct ReviewPageTip: Tip {
    var title: Text { Text("Grouped by scan") }
    var message: Text? { Text("Each heading is one room you scanned. The hunches under it came from those shelves.") }
    var image: Image? { Image(systemName: "rectangle.stack") }
    var options: [any TipOption] { Walkthrough.once }
}

struct LatestWalkTip: Tip {
    var title: Text { Text("Latest walk") }
    var message: Text? { Text("The newest filed packet is here, with its version.") }
    var image: Image? { Image(systemName: "book.closed") }
    var rules: [Rule] { #Rule(Walkthrough.$step) { $0 >= 2 } }
    var options: [any TipOption] { Walkthrough.once }
}

struct PracticeTip: Tip {
    var title: Text { Text("Practice") }
    var message: Text? { Text("Try the rules here. Practice does not file a claim.") }
    var image: Image? { Image(systemName: "play.circle") }
    var rules: [Rule] { #Rule(Walkthrough.$step) { $0 >= 3 } }
    var options: [any TipOption] { Walkthrough.once }
}
