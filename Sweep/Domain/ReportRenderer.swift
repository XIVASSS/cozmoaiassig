import Foundation

enum ReportRenderer {
    static func html(for packet: ClaimPacket) -> String {
        let books = packet.books.map(bookRow).joined()
        let items = packet.items.map(itemRow).joined()
        let queue = packet.reviewQueue.map { "<li>\(escape($0.refId)): \(escape($0.reason))</li>" }.joined()
        let euros = packet.euroComparison.map(euroRow).joined()
        let banner = packet.practice ? "<p class=\"banner\">Practice replay. Not a claim.</p>" : ""
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>Sweep \(escape(packet.sweep.id))</title>
        <style>
        body { font-family: Georgia, "Iowan Old Style", serif; background: #000; color: #fff; margin: 0; padding: 32px; }
        h1 { font-weight: 400; font-style: italic; font-size: 56px; line-height: 1.05; margin: 0 0 8px; }
        p, td, li { font-family: -apple-system, sans-serif; color: #6d6d6d; }
        h2 { font-family: -apple-system, sans-serif; font-size: 13px; letter-spacing: 0; text-transform: none; font-weight: 400; color: #fff; margin-top: 36px; }
        .banner { background: transparent; color: #fff; display: inline-block; padding: 8px 18px; border-radius: 75px; border: 1px solid rgba(255,255,255,0.35); font-family: -apple-system, sans-serif; font-size: 13px; letter-spacing: 0; text-transform: none; }
        .stat { background: #181818; color: #fff; border-radius: 28px; padding: 28px; margin: 24px 0; }
        .stat strong { font-family: Georgia, serif; font-weight: 400; font-style: italic; font-size: 48px; color: #fff; }
        table { width: 100%; border-collapse: collapse; background: #2e2e2e; border-radius: 16px; overflow: hidden; }
        th, td { text-align: left; padding: 12px 14px; border-bottom: 1px solid #3f4041; font-size: 14px; vertical-align: top; color: #f5f5f7; }
        th { font-family: ui-monospace, monospace; font-size: 11px; text-transform: uppercase; letter-spacing: 0.14em; color: #9f9fa0; }
        </style>
        </head>
        <body>
        \(banner)
        <h1>Contents packet</h1>
        <p>\(escape(packet.sweep.country)) · \(escape(packet.sweep.currency)) · version \(packet.sweep.packetVersion)</p>
        <div class="stat">
          <div>\(packet.totals.bookCount) books</div>
          <strong>\(money(packet.totals.booksReplacementCost, packet.sweep.currency))</strong>
          <div>sourced replacement · \(packet.totals.booksIdentified) identified · \(packet.reviewQueue.count) to review</div>
        </div>
        <p>Scale: \(escape(packet.room.scaleMethod)) Confidence \(packet.room.confidence).</p>
        <p>Floor \(area(packet.room.floorAreaM2)) · walls \(area(packet.room.wallAreaM2)) · shelves \(area(packet.room.shelvedWallAreaM2)).</p>
        <p>\(escape(packet.room.shapeNote))</p>
        <h2>Books</h2>
        <table><tr><th>Shelf</th><th>Status</th><th>Title</th><th>Spine</th><th>Replacement</th><th>Used</th></tr>\(books)</table>
        <h2>Other contents</h2>
        <table><tr><th>Category</th><th>Status</th><th>Description</th><th>Size</th></tr>\(items)</table>
        <h2>Germany, euros</h2>
        <table><tr><th>Title</th><th>Replacement</th><th>Used</th></tr>\(euros)</table>
        <h2>Review</h2>
        <ul>\(queue)</ul>
        </body>
        </html>
        """
    }

    private static func bookRow(_ book: BookLine) -> String {
        let title = book.title.isEmpty ? (book.candidateTitle.isEmpty ? "Unidentified spine" : "Hunch: \(book.candidateTitle)") : book.title
        let spine = [book.spineHeightCm, book.spineThicknessCm].map { $0.map { "\($0)" } ?? "—" }.joined(separator: " × ")
        return "<tr><td>\(escape(book.shelf)) \(book.position)</td><td>\(book.status.rawValue)</td><td>\(escape(title))</td><td>\(spine) cm</td><td>\(price(book.replacementCost))</td><td>\(price(book.usedValue))</td></tr>"
    }

    private static func itemRow(_ item: ItemLine) -> String {
        let size = [item.dimensionsCm.w, item.dimensionsCm.h, item.dimensionsCm.d].map { $0.map { "\($0)" } ?? "—" }.joined(separator: " × ")
        return "<tr><td>\(escape(item.category))</td><td>\(item.status.rawValue)</td><td>\(escape(item.description))</td><td>\(size)</td></tr>"
    }

    private static func euroRow(_ row: EuroComparison) -> String {
        "<tr><td>\(escape(row.title))</td><td>\(price(row.replacement))</td><td>\(price(row.used))</td></tr>"
    }

    private static func price(_ money: SourcedMoney) -> String {
        guard let amount = money.amount, money.hasAmount else { return "No listing" }
        let converted = money.converted ? " converted" : ""
        return "\(amount) \(escape(money.source))\(converted)"
    }

    private static func money(_ amount: Double, _ currency: String) -> String {
        "\(amount) \(currency)"
    }

    private static func area(_ squareMetres: Double?) -> String {
        guard let squareMetres else { return "—" }
        let feet = squareMetres * 10.7639
        return String(format: "%.2f m² (%.0f ft²)", squareMetres, feet)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
