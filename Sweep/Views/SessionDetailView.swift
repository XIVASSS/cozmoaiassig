import SwiftUI

struct SessionDetailView: View {
    @EnvironmentObject private var model: AppModel
    let sessionID: String
    @State private var version = 1
    @State private var packet: ClaimPacket?
    @State private var busyID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let packet {
                    if packet.practice {
                        Pill(title: "Practice replay. Not a claim.", style: .white)
                    }
                    Text((packet.sweep.country + " · " + packet.sweep.currency).uppercased())
                        .font(Theme.mono(11))
                        .tracking(1.4)
                        .foregroundStyle(Theme.ash)
                    StatCard(
                        eyebrow: "Version \(packet.sweep.packetVersion)",
                        value: "\(packet.totals.bookCount)",
                        detail: detail(packet)
                    )
                    versionPicker
                    roomBlock(packet)
                    books(packet)
                    section("Other contents", rows: packet.items.map { item in
                        InventoryRow(title: item.category, detail: item.description, kind: item.status.rawValue)
                    })
                    if !packet.euroComparison.isEmpty {
                        SectionLabel(title: "Germany, euros")
                        ForEach(packet.euroComparison, id: \.bookID) { row in
                            InventoryRow(
                                title: row.title.isEmpty ? row.bookID : row.title,
                                detail: euroDetail(row),
                                kind: "EUR"
                            )
                        }
                    }
                    SectionLabel(title: "Review")
                    if packet.reviewQueue.isEmpty {
                        EmptyNote(text: "Nothing queued.")
                    }
                    ForEach(packet.reviewQueue) { line in
                        Text(line.reason)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(Theme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                    frames(packet)
                    export(packet)
                } else {
                    Text("This walk has no packet yet.")
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(20)
        }
        .sweepScreen()
        .navigationTitle("Packet")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear { load() }
    }

    private var versionPicker: some View {
        let versions = model.store.packetVersions(id: sessionID)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(versions, id: \.self) { item in
                    Button("v\(item)") { version = item; load() }
                        .font(Theme.mono(12))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(item == version ? Theme.pure : Theme.graphite)
                        .foregroundStyle(item == version ? Theme.void : Theme.ash)
                        .clipShape(Capsule())
                }
            }
        }
    }

    private func roomBlock(_ packet: ClaimPacket) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(title: "Room")
            HStack(spacing: 8) {
                roomMetric("Floor", shown(packet.room.floorAreaM2))
                roomMetric("Walls", shown(packet.room.wallAreaM2))
                roomMetric("Shelves", shown(packet.room.shelvedWallAreaM2))
            }
            Text(packet.room.scaleMethod)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.ink)
            if let raw = packet.room.arkitFloorAreaM2 {
                Text("Tracking floor before the card: \(shown(raw)) m²")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }
            Text(packet.room.shapeNote)
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func frames(_ packet: ClaimPacket) -> some View {
        let refs = Array(Set(packet.books.map(\.frameRef) + packet.items.map(\.frameRef))).filter { !$0.isEmpty }.sorted()
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Frames")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(refs, id: \.self) { ref in
                        VStack(alignment: .leading) {
                            frameImage(ref)
                            Text(ref)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
        }
    }

    private func frameImage(_ ref: String) -> some View {
        let url = model.store.fileURL(sessionID: sessionID, relative: ref)
        return Group {
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Theme.lime
            }
        }
        .frame(width: 120, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func export(_ packet: ClaimPacket) -> some View {
        HStack(spacing: 10) {
            shareChip(
                model.store.packetFile(id: sessionID, version: packet.sweep.packetVersion, ext: "claim_packet.json"),
                title: "JSON"
            )
            shareChip(
                model.store.packetFile(id: sessionID, version: packet.sweep.packetVersion, ext: "report.html"),
                title: "Report"
            )
        }
    }

    private func shareChip(_ url: URL, title: String) -> some View {
        ShareLink(item: url) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private func books(_ packet: ClaimPacket) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Books")
            ForEach(packet.books) { book in
                HStack(alignment: .center, spacing: 8) {
                    InventoryRow(title: bookTitle(book), detail: bookDetail(book), kind: bookKind(book))
                    if AppModel.isHunch(book) {
                        HunchMark(busy: busyID == book.id) {
                            Task { await accept(book, in: packet) }
                        } reject: {
                            Task { await drop(book, in: packet) }
                        }
                    }
                }
            }
        }
    }

    private func accept(_ book: BookLine, in packet: ClaimPacket) async {
        busyID = book.id
        if let next = await model.acceptHunch(sessionID: sessionID, version: packet.sweep.packetVersion, bookID: book.id) {
            version = next
        }
        busyID = nil
        load()
    }

    private func drop(_ book: BookLine, in packet: ClaimPacket) async {
        busyID = book.id
        if let next = await model.dropHunch(sessionID: sessionID, version: packet.sweep.packetVersion, bookID: book.id) {
            version = next
        }
        busyID = nil
        load()
    }

    private func section(_ title: String, rows: [InventoryRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: title)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in row }
        }
    }

    private func load() {
        let versions = model.store.packetVersions(id: sessionID)
        if !versions.contains(version) { version = versions.last ?? 1 }
        packet = model.store.packet(id: sessionID, version: version)
    }

    private func detail(_ packet: ClaimPacket) -> String {
        let money: String
        if packet.books.contains(where: { $0.replacementCost.hasAmount && $0.status == .identified && !$0.excluded }) {
            money = "\(packet.totals.booksReplacementCost) \(packet.sweep.currency) replacement"
        } else {
            money = "no sourced replacement total"
        }
        return "\(packet.totals.booksIdentified) identified · \(money)"
    }

    private func bookTitle(_ book: BookLine) -> String {
        if !book.title.isEmpty { return book.title }
        if !book.candidateTitle.isEmpty { return book.candidateTitle }
        return "Unidentified spine"
    }

    private func bookDetail(_ book: BookLine) -> String {
        let height = book.spineHeightCm.map { String(format: "%.1f cm", $0) } ?? "no measurement"
        let price = book.replacementCost.hasAmount ? "\(book.replacementCost.amount ?? 0) \(book.replacementCost.source)" : "no listing"
        return "\(book.shelf) · \(height) · \(price)"
    }

    private func bookKind(_ book: BookLine) -> String {
        if book.excluded { return "Skipped" }
        if book.status == .unidentified, !book.candidateTitle.isEmpty { return "Hunch" }
        return book.status.rawValue
    }

    private func euroDetail(_ row: EuroComparison) -> String {
        let replacement = row.replacement.hasAmount ? "\(row.replacement.amount ?? 0) new" : "no new listing"
        let used = row.used.hasAmount ? "\(row.used.amount ?? 0) used" : "no used listing"
        return "\(replacement) · \(used)"
    }

    private func roomMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(Theme.mono(11))
                .tracking(1.2)
                .foregroundStyle(Theme.ash)
            Text(value)
                .font(Theme.display(28))
                .foregroundStyle(Theme.cloud)
            Text("m²")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func shown(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f", value)
    }
}
