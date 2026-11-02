import Foundation

struct SessionStore {
    let root: URL

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.root = documents.appendingPathComponent("sessions", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    func summaries() -> [SessionSummary] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder -> SessionSummary? in
            loadSummary(id: folder.lastPathComponent)
        }
        .sorted { $0.capturedAt > $1.capturedAt }
    }

    func makeSession(id: String) -> URL {
        let folder = directory(id)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("frames"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("packets"), withIntermediateDirectories: true)
        return folder
    }

    func save(summary: SessionSummary, logs: [WalkLog]) {
        let folder = makeSession(id: summary.id)
        write(summary, to: folder.appendingPathComponent("summary.json"))
        write(logs, to: folder.appendingPathComponent("events.json"))
    }

    func saveFrame(_ data: Data, sessionID: String, name: String) -> String {
        let relative = "frames/\(name)"
        let url = directory(sessionID).appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
        return relative
    }

    func savePacket(_ packet: ClaimPacket, logs: [WalkLog]) throws -> URL {
        let folder = makeSession(id: packet.sweep.id)
        let versionFolder = folder.appendingPathComponent("packets/v\(packet.sweep.packetVersion)", isDirectory: true)
        try FileManager.default.createDirectory(at: versionFolder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(packet)
        let jsonURL = versionFolder.appendingPathComponent("claim_packet.json")
        try json.write(to: jsonURL)
        let html = ReportRenderer.html(for: packet)
        try html.data(using: .utf8)?.write(to: versionFolder.appendingPathComponent("report.html"))
        write(logs, to: folder.appendingPathComponent("events.json"))
        let summary = SessionSummary(
            id: packet.sweep.id,
            capturedAt: ISO8601DateFormatter().date(from: packet.sweep.capturedAt) ?? Date(),
            practice: packet.practice,
            phase: "packet",
            bookCount: packet.totals.booksIdentified,
            floorAreaM2: packet.room.floorAreaM2,
            reviewCount: Set(packet.reviewQueue.map(\.refId)).count,
            packetVersion: packet.sweep.packetVersion,
            country: packet.sweep.country,
            currency: packet.sweep.currency
        )
        write(summary, to: folder.appendingPathComponent("summary.json"))
        return jsonURL
    }

    func latestPacket(id: String) -> ClaimPacket? {
        let versions = packetVersions(id: id)
        guard let last = versions.last else { return nil }
        return packet(id: id, version: last)
    }

    func packet(id: String, version: Int) -> ClaimPacket? {
        let url = directory(id).appendingPathComponent("packets/v\(version)/claim_packet.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ClaimPacket.self, from: data)
    }

    func packetVersions(id: String) -> [Int] {
        let folder = directory(id).appendingPathComponent("packets")
        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return children.compactMap { url -> Int? in
            let name = url.lastPathComponent
            guard name.hasPrefix("v") else { return nil }
            return Int(name.dropFirst())
        }
        .sorted()
    }

    func frameFiles(id: String) -> [URL] {
        let folder = directory(id).appendingPathComponent("frames")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func fileURL(sessionID: String, relative: String) -> URL {
        directory(sessionID).appendingPathComponent(relative)
    }

    func packetFile(id: String, version: Int, ext: String) -> URL {
        directory(id).appendingPathComponent("packets/v\(version)/\(ext)")
    }

    func delete(id: String) {
        try? FileManager.default.removeItem(at: directory(id))
    }

    private func loadSummary(id: String) -> SessionSummary? {
        let url = directory(id).appendingPathComponent("summary.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SessionSummary.self, from: data)
    }

    private func directory(_ id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url)
    }
}
