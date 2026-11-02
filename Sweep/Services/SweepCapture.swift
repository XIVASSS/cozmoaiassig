import ARKit
import AVFoundation
import CoreImage
import UIKit
import Vision

struct CaptureTick {
    var spines: [SpineHit]
    var item: ItemDraft?
    var card: CardLock?
    var quality: QualityIssue?
    var room: RoomObservation?
    var frameJPEG: Data?
    var frameName: String?
    var cue: ScanCue = .none
    var marks: [NormBox] = []
    var columns: Int = 0
    var sharp: Bool = false
}

struct CardLock {
    var millimetresPerPixel: Double
    var distanceM: Double
    var arkitCardMeters: Double
}

final class SweepCapture: NSObject, ARSessionDelegate {
    let session = ARSession()
    var onTick: ((CaptureTick) -> Void)?
    private let visionQueue = DispatchQueue(label: "sweep.vision")
    private var busy = false
    private var lastVision: TimeInterval = 0
    private var lastClassify: TimeInterval = 0
    private var lastCameraPosition: SIMD3<Float>?
    private var frameIndex = 0
    private(set) var latestShelf: [SpineHit] = []
    private var retainedShelf: CIImage?
    private var retainedMillimetres: Double?
    private var retainedCount = 0
    private var sharpStills: [CIImage] = []
    private let context = CIContext()
    private var floors: [UUID: (width: Float, height: Float)] = [:]
    private var walls: [UUID: (width: Float, height: Float)] = [:]

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else { return }
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .none
        session.delegate = self
        session.run(configuration)
    }

    func stop() {
        session.pause()
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = frame.timestamp
        guard now - lastVision > 0.45, !busy else { return }
        busy = true
        lastVision = now
        let buffer = frame.capturedImage
        let camera = frame.camera
        let moving = motion(of: camera)
        let shouldClassify = now - lastClassify > 2.4
        if shouldClassify { lastClassify = now }
        let orientation = imageOrientation()
        let fx = Double(camera.intrinsics.columns.0.x)
        let distance = planeDistance(frame: frame, camera: camera)
        visionQueue.async { [weak self] in
            guard let self else { return }
            let tick = self.inspect(buffer: buffer, camera: camera, moving: moving, classify: shouldClassify, orientation: orientation, distance: distance, fx: fx)
            DispatchQueue.main.async {
                self.busy = false
                self.onTick?(tick)
            }
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        absorb(anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        absorb(anchors)
    }

    private func absorb(_ anchors: [ARAnchor]) {
        for anchor in anchors {
            guard let plane = anchor as? ARPlaneAnchor else { continue }
            let extent = (plane.planeExtent.width, plane.planeExtent.height)
            if plane.alignment == .horizontal {
                floors[plane.identifier] = extent
            } else {
                walls[plane.identifier] = extent
            }
        }
        let room = currentRoom()
        DispatchQueue.main.async { [weak self] in
            self?.onTick?(CaptureTick(spines: [], item: nil, card: nil, quality: nil, room: room, frameJPEG: nil, frameName: nil))
        }
    }

    private func currentRoom() -> RoomObservation {
        let floorList = floors.values.sorted { $0.width * $0.height > $1.width * $1.height }
        let wallList = walls.values.sorted { $0.width * $0.height > $1.width * $1.height }
        let floor = floorList.first
        let floorArea = floor.map { Double($0.width * $0.height) }
        let wallsToUse = Array(wallList.prefix(6))
        let wallArea = wallsToUse.reduce(0.0) { $0 + Double($1.width * $1.height) }
        let height = wallList.map(\.height).max().map(Double.init)
        let shape: String
        if floorList.count > 1 {
            shape = "Largest floor plane. \(floorList.count) floor pieces seen."
        } else if floorList.count == 1 {
            shape = "Single floor plane."
        } else {
            shape = ""
        }
        return RoomObservation(
            floorWidthM: floor.map { Double($0.width) },
            floorDepthM: floor.map { Double($0.height) },
            floorAreaM2: floorArea,
            wallAreaM2: wallArea > 0 ? wallArea : nil,
            ceilingHeightM: height,
            shelfFaceAreaM2: nil,
            shapeNote: shape,
            planeCount: floorList.count
        )
    }

    private func motion(of camera: ARCamera) -> Bool {
        let position = SIMD3<Float>(camera.transform.columns.3.x, camera.transform.columns.3.y, camera.transform.columns.3.z)
        defer { lastCameraPosition = position }
        guard let lastCameraPosition else { return false }
        return simd_distance(position, lastCameraPosition) > 0.18
    }

    private func inspect(buffer: CVPixelBuffer, camera: ARCamera, moving: Bool, classify: Bool, orientation: CGImagePropertyOrientation, distance: Double, fx: Double) -> CaptureTick {
        let luma = sampleLuma(buffer)
        var quality: QualityIssue?
        if MeasureMath.blurScore(luma: luma.pixels, width: luma.width, height: luma.height) < 18 {
            quality = .blur
        } else if MeasureMath.glareFraction(luma: luma.pixels) > 0.18 {
            quality = .glare
        } else if moving {
            quality = .movingTooFast
        }

        let request = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:])
        let rectangles = VNDetectRectanglesRequest()
        rectangles.minimumAspectRatio = 0.45
        rectangles.maximumAspectRatio = 1
        rectangles.minimumSize = 0.05
        rectangles.maximumObservations = 6
        let bookRects = VNDetectRectanglesRequest()
        bookRects.minimumAspectRatio = 0.04
        bookRects.maximumAspectRatio = 0.95
        bookRects.minimumSize = 0.012
        bookRects.minimumConfidence = 0.35
        bookRects.maximumObservations = 40
        bookRects.quadratureTolerance = 25
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        text.recognitionLanguages = ["en-US"]
        text.minimumTextHeight = 0.008
        var jobs: [VNRequest] = [rectangles, bookRects, text]
        let labels = VNClassifyImageRequest()
        if classify { jobs.append(labels) }
        try? request.perform(jobs)

        let card = cardLock(from: rectangles.results ?? [], buffer: buffer, distance: distance, fx: fx)
        let millimetres = card?.millimetresPerPixel
        let read = spineHits(
            rectangles: bookRects.results ?? [],
            text: text.results ?? [],
            covers: rectangles.results ?? [],
            buffer: buffer,
            orientation: orientation,
            millimetresPerPixel: millimetres
        )
        let item = classify ? classifiedItem(from: labels.results ?? [], frameRef: "") : nil
        frameIndex += 1
        let name = String(format: "frame-%04d.jpg", frameIndex)
        let jpeg: Data? = quality == nil
            ? context.jpegRepresentation(of: CIImage(cvPixelBuffer: buffer), colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:])
            : nil
        let namedSpines = read.hits.map { hit in
            SpineHit(text: hit.text, shelf: hit.shelf, midX: hit.midX, heightCm: hit.heightCm, thicknessCm: hit.thicknessCm, confidence: hit.confidence, frameRef: "frames/\(name)", box: hit.box)
        }
        let namedItem = item.map { draft -> ItemDraft in
            var copy = draft
            copy.frameRef = "frames/\(name)"
            return copy
        }
        return CaptureTick(spines: namedSpines, item: namedItem, card: card, quality: quality, room: nil, frameJPEG: jpeg, frameName: name, cue: read.cue, marks: read.marks, columns: read.hits.count, sharp: quality == nil)
    }

    private func cardLock(from observations: [VNRectangleObservation], buffer: CVPixelBuffer, distance: Double, fx: Double) -> CardLock? {
        let width = Double(CVPixelBufferGetWidth(buffer))
        let height = Double(CVPixelBufferGetHeight(buffer))
        for observation in observations {
            let longShort = pixelSides(observation, width: width, height: height)
            guard let mm = MeasureMath.millimetresPerPixel(longSidePx: longShort.long, shortSidePx: longShort.short) else { continue }
            guard fx > 1, distance > 0.15 else { continue }
            let arkitMeters = longShort.long * (distance / fx)
            return CardLock(millimetresPerPixel: mm, distanceM: distance, arkitCardMeters: arkitMeters)
        }
        return nil
    }

    private func pixelSides(_ observation: VNRectangleObservation, width: Double, height: Double) -> (long: Double, short: Double) {
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * width, y: p.y * height) }
        func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
        let edgeA = distance(point(observation.topLeft), point(observation.topRight))
        let edgeB = distance(point(observation.topLeft), point(observation.bottomLeft))
        return (max(edgeA, edgeB), min(edgeA, edgeB))
    }

    private func planeDistance(frame: ARFrame, camera: ARCamera) -> Double {
        let point = CGPoint(x: 0.5, y: 0.5)
        let query = frame.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .any)
        guard let hit = session.raycast(query).first else { return 0.55 }
        let cameraPosition = camera.transform.columns.3
        let hitPosition = hit.worldTransform.columns.3
        return Double(simd_distance(
            SIMD3(cameraPosition.x, cameraPosition.y, cameraPosition.z),
            SIMD3(hitPosition.x, hitPosition.y, hitPosition.z)
        ))
    }

    /// Read the held shelf in pieces so each spine is large enough to be its own book.
    func releaseShelfStill() {
        retainedCount = 0
    }

    func guessShelfCount() async -> Int {
        await withCheckedContinuation { continuation in
            visionQueue.async {
                let stills = self.sharpStills.isEmpty ? [self.retainedShelf].compactMap { $0 } : self.sharpStills
                guard let image = stills.last,
                      let sample = Sampler(image: image, width: 180, height: 240, context: self.context) else {
                    continuation.resume(returning: 1)
                    return
                }
                let rows = sample.runs(horizontal: true).count
                let columns = sample.runs(horizontal: false).count
                let plausible = [rows, columns].filter { (1...3).contains($0) }
                let guess = plausible.min() ?? min(3, max(rows, columns, 1))
                continuation.resume(returning: min(3, max(1, guess)))
            }
        }
    }

    func readImages(_ images: [CIImage], shelves: Int, books: Int) async -> [SpineHit] {
        let budget = max(60, books)
        return await withCheckedContinuation { continuation in
            visionQueue.async {
                var reads: [CoverRead] = []
                for image in images {
                    let straightLines = self.textLines(in: image, correct: true)
                    let straight = self.closeReads(in: image, lines: straightLines)
                    if straight.count >= 12 {
                        reads.append(contentsOf: straight)
                        continue
                    }
                    let turnedRight = self.closeReads(in: image.oriented(.right), lines: self.textLines(in: image.oriented(.right), correct: true))
                    let turnedLeft = self.closeReads(in: image.oriented(.left), lines: self.textLines(in: image.oriented(.left), correct: true))
                    let best = [straight, turnedRight, turnedLeft].max { self.readingScore($0) < self.readingScore($1) } ?? straight
                    reads.append(contentsOf: best)
                }
                let kept = self.dedupedReports(reads)
                let hits = kept.prefix(budget).map { read in
                    SpineHit(
                        text: read.title,
                        shelf: read.shelf,
                        midX: read.box.midX,
                        heightCm: nil,
                        thicknessCm: nil,
                        confidence: max(read.confidence, 0.8),
                        frameRef: "frames",
                        box: read.box
                    )
                }
                continuation.resume(returning: Array(hits))
            }
        }
    }

    /// Read a stack in short slices, then put each line back into the full frame. A slice's own boxes are too tall for the spine rules, so the letters were being thrown away.
    private func closeReads(in image: CIImage, lines: [CoverLine]) -> [CoverRead] {
        let extent = image.extent
        var columns = columnBoxes(lines).filter { $0.x < 0.78 }.map { box in
            let y = max(0, box.y - 0.04)
            return NormBox(x: max(0, box.x - 0.02), y: y, width: min(0.5, box.width + 0.04), height: min(1 - y, box.height + 0.08))
        }
        if columns.isEmpty {
            columns = [
                NormBox(x: 0.02, y: 0, width: 0.34, height: 1),
                NormBox(x: 0.36, y: 0, width: 0.34, height: 1)
            ]
        }
        guard extent.width > 40, extent.height > 40, !columns.isEmpty else {
            return CoverReading.reportBooks(lines)
        }
        var placed: [CoverLine] = []
        for column in columns {
            var start = column.y
            let end = column.y + column.height
            while start < end - 0.03 {
                let window = NormBox(x: column.x, y: start, width: column.width, height: min(0.22, end - start))
                let rect = pixelRect(window.inset(by: 0.008), extent: extent)
                if rect.width > 24, rect.height > 24 {
                    let cropped = image.cropped(to: rect)
                    let shifted = cropped.transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
                    let scaled = shifted.transformed(by: CGAffineTransform(scaleX: 3, y: 3))
                    let zoomed: [CoverLine]
                    if let rendered = context.createCGImage(scaled, from: scaled.extent) {
                        zoomed = textLines(in: rendered, correct: true)
                    } else {
                        zoomed = textLines(in: scaled, correct: true)
                    }
                    for line in zoomed {
                        let box = NormBox(
                            x: (rect.minX - extent.minX) / extent.width + line.box.x * rect.width / extent.width,
                            y: (rect.minY - extent.minY) / extent.height + line.box.y * rect.height / extent.height,
                            width: line.box.width * rect.width / extent.width,
                            height: line.box.height * rect.height / extent.height
                        )
                        guard box.width > 0.012, box.height > 0.004, box.height <= 0.09 else { continue }
                        placed.append(CoverLine(text: line.text, box: box, confidence: line.confidence))
                    }
                }
                start += 0.16
            }
        }
        let found = CoverReading.reportBooks(placed)
        let plain = CoverReading.reportBooks(lines)
        let plainScore = readingScore(plain)
        let foundScore = readingScore(found)
        if plainScore >= 8, foundScore < plainScore + max(4, plainScore / 2) { return plain }
        return foundScore > plainScore + 4 ? found : plain
    }

    /// Each long word counts once. A slice that repeats a title already on the frame does not outscore it.
    private func readingScore(_ reads: [CoverRead]) -> Int {
        var seen = Set<String>()
        var score = 0
        for read in reads {
            let words = MeasureMath.countedWords(read.title)
            guard MeasureMath.looksLikeTitle(read.title) else { continue }
            let fresh = words.filter { !seen.contains($0) }
            guard fresh.count >= 2 else { continue }
            fresh.forEach { seen.insert($0) }
            score += fresh.count
        }
        return score
    }

    private func readable(_ reads: [CoverRead]) -> Int {
        reads.filter { read in
            let words = MeasureMath.tokens(read.title).filter { $0.count >= 4 }
            return MeasureMath.looksLikeTitle(read.title) && words.count >= 1 && words.count <= 8
        }.count
    }

    private func columnBoxes(_ lines: [CoverLine]) -> [NormBox] {
        let bands = lines.filter { line in
            let box = line.box
            return box.width > box.height && box.width >= 0.03 && box.width <= 0.7 && box.height <= 0.12 && line.text.count >= 3
        }
        let sorted = bands.sorted { $0.box.x < $1.box.x }
        var columns: [[CoverLine]] = []
        for line in sorted {
            if var last = columns.last {
                let left = last.map(\.box.x).reduce(0, +) / Double(last.count)
                if abs(line.box.x - left) < 0.12 {
                    last.append(line)
                    columns[columns.count - 1] = last
                } else {
                    columns.append([line])
                }
            } else {
                columns.append([line])
            }
        }
        return columns.map { NormBox.union($0.map(\.box)) }.filter { $0.height > 0.15 && $0.width > 0.05 }
    }

    private func pixelRect(_ box: NormBox, extent: CGRect) -> CGRect {
        let x = extent.minX + box.x * extent.width
        let y = extent.minY + box.y * extent.height
        let width = box.width * extent.width
        let height = box.height * extent.height
        return CGRect(x: x, y: y, width: width, height: height).intersection(extent)
    }

    private func dedupedReports(_ reads: [CoverRead]) -> [CoverRead] {
        var kept: [CoverRead] = []
        for read in reads {
            if let index = kept.firstIndex(where: { sameShelfSpine($0, read) }) {
                let chosen = MeasureMath.preferTitle(kept[index].title, read.title)
                if chosen == read.title {
                    var copy = read
                    copy.box = kept[index].box
                    kept[index] = copy
                }
                continue
            }
            kept.append(read)
        }
        return kept
    }

    /// 1998 is the same book in every frame. Two undated "Best American Poetry" spines are not.
    private func sameShelfSpine(_ existing: CoverRead, _ read: CoverRead) -> Bool {
        guard MeasureMath.sameReading(existing.title, read.title) else { return false }
        let dated = [existing.title, read.title].contains { title in
            title.split(whereSeparator: { !$0.isNumber }).contains { word in
                guard let year = Int(word), word.count == 4 else { return false }
                return (1950...2030).contains(year)
            }
        }
        let long = existing.title.split(separator: " ").count >= 6 && read.title.split(separator: " ").count >= 6
        if dated || long || MeasureMath.jaccard(existing.title, read.title) > 0.82 { return true }
        return abs(existing.box.midY - read.box.midY) < 0.045 && abs(existing.box.midX - read.box.midX) < 0.18
    }

    func readLockedShelf(shelves: Int = 2, books: Int = 24) async -> [SpineHit] {
        let shelfCount = min(4, max(1, shelves))
        let budget = min(36, max(shelfCount, books))
        return await withCheckedContinuation { continuation in
            visionQueue.async {
                continuation.resume(returning: self.tiledShelfHits(shelves: shelfCount, budget: budget))
            }
        }
    }

    private func tiledShelfHits(shelves: Int, budget: Int) -> [SpineHit] {
        let stills = sharpStills.isEmpty ? [retainedShelf].compactMap { $0 } : sharpStills
        guard let image = stills.last else { return [] }
        let read = ocrHits(from: stills, image: image)
        let slots = countBooks(in: image, shelves: shelves, budget: budget)
        let merged = paste(read, into: slots)
        let titled = merged.filter { !$0.text.isEmpty }
        let holes = merged.count - titled.count
        if titled.count >= 3, holes <= 8, merged.count <= budget + 2 {
            return Array(merged.prefix(budget + 2))
        }
        if titled.count >= 3 {
            return Array(titled.prefix(budget))
        }
        return Array(grouped(read, shelves: shelves, budget: budget).prefix(budget))
    }

    private func ocrHits(from stills: [CIImage], image: CIImage) -> [SpineHit] {
        let extent = image.extent
        guard extent.width > 10, extent.height > 10 else { return [] }
        var lines: [CoverLine] = []
        for still in stills {
            lines.append(contentsOf: placed(textLines(in: still), crop: still.extent, extent: still.extent))
        }
        lines.append(contentsOf: collectShelfLines(image).filter { line in
            !lines.contains { abs($0.box.midX - line.box.midX) < 0.02 && abs($0.box.midY - line.box.midY) < 0.02 && $0.text == line.text }
        })
        return hitsFromLines(lines, width: extent.width, height: extent.height, millimetresPerPixel: retainedMillimetres) ?? []
    }

    /// A few wide bands per shelf, never one band per letter.
    private func countBooks(in image: CIImage, shelves: Int, budget: Int) -> [SpineHit] {
        guard let sample = Sampler(image: image, width: 180, height: 240, context: context) else { return [] }
        let perShelf = max(6, budget / max(shelves, 1))
        let upright = shelfHits(sample, image: image, columnsAreShelves: false, shelves: shelves, perShelf: perShelf)
        let sideways = shelfHits(sample, image: image, columnsAreShelves: true, shelves: shelves, perShelf: perShelf)
        let uprightNames = upright.filter { !$0.text.isEmpty }.count
        let sidewaysNames = sideways.filter { !$0.text.isEmpty }.count
        if uprightNames == 0, sidewaysNames == 0 {
            let smaller = upright.count <= sideways.count ? upright : sideways
            return Array(smaller.prefix(budget))
        }
        if uprightNames != sidewaysNames { return uprightNames > sidewaysNames ? upright : sideways }
        return abs(upright.count - budget) <= abs(sideways.count - budget) ? upright : sideways
    }

    private func shelfHits(_ sample: Sampler, image: CIImage, columnsAreShelves: Bool, shelves wanted: Int, perShelf: Int) -> [SpineHit] {
        let shelves = sample.shelfSpans(count: wanted, horizontal: !columnsAreShelves)
        let length = columnsAreShelves ? sample.height : sample.width
        var minimum = max(7, length / (perShelf + 3))
        var hits: [SpineHit] = []
        for (shelf, span) in shelves.enumerated() {
            var bands = sample.bands(in: span, alongY: columnsAreShelves, minimum: minimum)
            while bands.count > perShelf + 2, minimum < length / 3 {
                minimum += 2
                bands = sample.bands(in: span, alongY: columnsAreShelves, minimum: minimum)
            }
            let ordered = columnsAreShelves
                ? bands.sorted { $0.lowerBound > $1.lowerBound }
                : bands.sorted { $0.lowerBound < $1.lowerBound }
            for band in ordered.prefix(perShelf + 2) {
                let box = columnsAreShelves
                    ? NormBox(
                        x: Double(span.lowerBound) / Double(sample.width),
                        y: Double(band.lowerBound) / Double(sample.height),
                        width: Double(span.count) / Double(sample.width),
                        height: Double(band.count) / Double(sample.height)
                    )
                    : NormBox(
                        x: Double(band.lowerBound) / Double(sample.width),
                        y: Double(span.lowerBound) / Double(sample.height),
                        width: Double(band.count) / Double(sample.width),
                        height: Double(span.count) / Double(sample.height)
                    )
                let (title, confidence) = bandTitle(box, image: image)
                var hit = measuredHit(
                    title: title,
                    confidence: confidence,
                    box: box,
                    width: image.extent.width,
                    height: image.extent.height,
                    millimetresPerPixel: retainedMillimetres
                )
                hit.shelf = shelf
                hit.midX = columnsAreShelves ? box.midY : box.midX
                hits.append(hit)
            }
        }
        return hits
    }

    private func bandTitle(_ box: NormBox, image: CIImage) -> (String, Float) {
        let extent = image.extent
        let crop = CGRect(
            x: extent.minX + box.x * extent.width,
            y: extent.minY + box.y * extent.height,
            width: max(4, box.width * extent.width),
            height: max(4, box.height * extent.height)
        ).intersection(extent)
        guard crop.width > 6, crop.height > 4 else { return ("", 0) }
        let piece = image.cropped(to: crop).transformed(by: CGAffineTransform(scaleX: 3, y: 3))
        let lines = textLines(in: piece) + textLines(in: piece.oriented(.right))
        let best = CoverReading.bestTitle(lines)
        var title = best.text
        var confidence = best.confidence
        if title.isEmpty, let line = lines.max(by: { $0.text.count < $1.text.count }) {
            title = CoverReading.cleanedTitle(line.text)
            confidence = line.confidence
        }
        let lower = title.lowercased()
        if lower.contains("library for") || lower.contains("software update") || lower.contains("storage space") {
            return ("", 0)
        }
        return (title, confidence)
    }

    private func paste(_ titles: [SpineHit], into slots: [SpineHit]) -> [SpineHit] {
        let titled = titles.filter { !$0.text.isEmpty }
        guard !slots.isEmpty else { return titled }
        return slots.map { slot in
            var slot = slot
            guard slot.text.isEmpty else { return slot }
            let match = titled.max { left, right in
                overlap(left.box, slot.box) < overlap(right.box, slot.box)
            }
            if let match, overlap(match.box, slot.box) > 0.04 || (match.shelf == slot.shelf && abs(match.midX - slot.midX) < 0.05) {
                slot.text = match.text
                slot.confidence = match.confidence
            }
            return slot
        }
    }

    private func overlap(_ a: NormBox, _ b: NormBox) -> Double {
        let x = max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x))
        let y = max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
        let intersection = x * y
        let union = a.area + b.area - intersection
        return union > 0 ? intersection / union : 0
    }

    private func grouped(_ hits: [SpineHit], shelves: Int, budget: Int) -> [SpineHit] {
        let titled = hits.filter { textIsReadable($0.text) }
        guard !titled.isEmpty else { return [] }
        let groups: [[SpineHit]]
        if Set(titled.map(\.shelf)).count == shelves {
            groups = (0..<shelves).map { shelf in titled.filter { $0.shelf == shelf } }
        } else {
            groups = splitByHeight(titled, count: shelves)
        }
        var result: [SpineHit] = []
        let room = max(1, budget / max(shelves, 1) + 2)
        for (index, group) in groups.enumerated() {
            for var hit in group.sorted(by: { $0.midX < $1.midX }).prefix(room) {
                hit.shelf = index
                result.append(hit)
            }
        }
        return result
    }

    private func splitByHeight(_ hits: [SpineHit], count: Int) -> [[SpineHit]] {
        let sorted = hits.sorted { $0.box.midY > $1.box.midY }
        guard count > 1, sorted.count >= count else { return [sorted] }
        let cuts = (1..<sorted.count).map { index in
            (gap: sorted[index - 1].box.midY - sorted[index].box.midY, index: index)
        }
        let chosen = cuts.sorted { $0.gap > $1.gap }.prefix(count - 1).map(\.index).sorted()
        var groups: [[SpineHit]] = []
        var start = 0
        for cut in chosen {
            groups.append(Array(sorted[start..<cut]))
            start = cut
        }
        groups.append(Array(sorted[start...]))
        return groups.filter { !$0.isEmpty }
    }

    private func distinctTitles(_ hits: [SpineHit]) -> [SpineHit] {
        var kept: [SpineHit] = []
        for hit in hits.sorted(by: { $0.text.count > $1.text.count }) {
            guard textIsReadable(hit.text), hit.text.count >= 8 else { continue }
            let letters = hit.text.lowercased().filter { $0.isLetter }
            guard letters.contains(where: { "aeiou".contains($0) }) else { continue }
            if kept.contains(where: { MeasureMath.jaccard($0.text, hit.text) > 0.5 }) { continue }
            var copy = hit
            copy.confidence = max(hit.confidence, 0.8)
            kept.append(copy)
        }
        return kept
    }

    private func textIsReadable(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("library for") || lower.contains("software update") || lower.contains("storage space") { return false }
        return text.count >= 4
    }

    /// Read the frame, then each shelf in narrow slices, so a thin spine is large enough to read.
    private func collectShelfLines(_ image: CIImage) -> [CoverLine] {
        let extent = image.extent
        var lines = placed(textLines(in: image), crop: extent, extent: extent)
        for band in shelfBands(lines, extent: extent) {
            let slices = 6
            let sliceWidth = band.width / CGFloat(slices)
            for index in 0..<slices {
                let x = band.minX + CGFloat(index) * sliceWidth * 0.7
                let crop = CGRect(x: x, y: band.minY, width: sliceWidth * 1.45, height: band.height).intersection(extent)
                guard crop.width > 8, crop.height > 8 else { continue }
                lines.append(contentsOf: placed(textLines(in: image.cropped(to: crop)), crop: crop, extent: extent))
            }
        }
        return lines
    }

    private func shelfBands(_ lines: [CoverLine], extent: CGRect) -> [CGRect] {
        let ys = lines.map { extent.minY + CGFloat($0.box.midY) * extent.height }.sorted()
        guard ys.count >= 4 else { return [extent] }
        var bestGap: CGFloat = 0
        var splitAt: CGFloat = 0
        for index in 1..<ys.count {
            let gap = ys[index] - ys[index - 1]
            if gap > bestGap {
                bestGap = gap
                splitAt = (ys[index] + ys[index - 1]) / 2
            }
        }
        guard bestGap > extent.height * 0.08 else { return [extent] }
        let pad = bestGap * 0.15
        let lower = CGRect(x: extent.minX, y: extent.minY, width: extent.width, height: splitAt - pad - extent.minY)
        let upper = CGRect(x: extent.minX, y: splitAt + pad, width: extent.width, height: extent.maxY - (splitAt + pad))
        let bands = [lower, upper].filter { $0.height > 8 && $0.width > 8 }
        return bands.isEmpty ? [extent] : bands
    }

    private func placed(_ lines: [CoverLine], crop: CGRect, extent: CGRect) -> [CoverLine] {
        guard extent.width > 0, extent.height > 0, crop.width > 0, crop.height > 0 else { return [] }
        return lines.map { line in
            CoverLine(
                text: line.text,
                box: NormBox(
                    x: (crop.minX - extent.minX + line.box.x * crop.width) / extent.width,
                    y: (crop.minY - extent.minY + line.box.y * crop.height) / extent.height,
                    width: line.box.width * crop.width / extent.width,
                    height: line.box.height * crop.height / extent.height
                ),
                confidence: line.confidence
            )
        }
    }

    private func textLines(in image: CIImage, correct: Bool = false) -> [CoverLine] {
        let request = textRequest(correct: correct)
        try? VNImageRequestHandler(ciImage: image, options: [:]).perform([request])
        return lines(from: request)
    }

    private func textLines(in image: CGImage, correct: Bool) -> [CoverLine] {
        let request = textRequest(correct: correct)
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return lines(from: request)
    }

    private func textRequest(correct: Bool) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = correct
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = correct ? 0.004 : 0.008
        request.customWords = ["poetry", "poems", "american", "collected", "selected", "modern", "great", "best"]
        return request
    }

    private func lines(from request: VNRecognizeTextRequest) -> [CoverLine] {
        (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first, best.confidence >= 0.25 else { return nil }
            let box = observation.boundingBox
            return CoverLine(
                text: best.string,
                box: NormBox(x: box.origin.x, y: box.origin.y, width: box.width, height: box.height),
                confidence: best.confidence
            )
        }
    }

    /// Only a thin spine is a book. The title is read along that edge, turned upright.
    private func spineHits(rectangles: [VNRectangleObservation], text: [VNRecognizedTextObservation], covers: [VNRectangleObservation], buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, millimetresPerPixel: Double?) -> (hits: [SpineHit], cue: ScanCue, marks: [NormBox]) {
        let width = Double(CVPixelBufferGetWidth(buffer))
        let height = Double(CVPixelBufferGetHeight(buffer))
        let image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        let lines: [CoverLine] = text.compactMap { observation in
            guard let best = observation.topCandidates(1).first, best.confidence >= 0.3 else { return nil }
            let box = observation.boundingBox
            return CoverLine(
                text: best.string,
                box: NormBox(x: box.origin.x, y: box.origin.y, width: box.width, height: box.height),
                confidence: best.confidence
            )
        }
        if let hits = hitsFromLines(lines, width: width, height: height, millimetresPerPixel: millimetresPerPixel), hits.count >= 3 {
            latestShelf = hits
            if hits.count >= retainedCount, let cg = context.createCGImage(image, from: image.extent) {
                let still = CIImage(cgImage: cg)
                retainedShelf = still
                retainedMillimetres = millimetresPerPixel
                retainedCount = hits.count
                sharpStills.append(still)
                if sharpStills.count > 3 { sharpStills.removeFirst(sharpStills.count - 3) }
            }
            return (hits, .read, hits.map(\.box))
        }
        var hits: [SpineHit] = []
        var unread: [SpineHit] = []
        var marks: [NormBox] = []
        var unreadable = 0
        for observation in rectangles where isSpineQuad(observation) {
            let box = normBox(observation.boundingBox)
            marks.append(box)
            let deskewed = straighten(observation, image: image)
            let along = deskewed.map { readTitle($0) } ?? ("", 0)
            let nearby = lines.filter { box.inset(by: 0.03).contains(x: $0.box.midX, y: $0.box.midY) }
            let fallback = CoverReading.bestTitle(nearby)
            let deskewScore = CoverReading.titleScore(along.text, height: 0.12)
            let fallbackScore = CoverReading.titleScore(fallback.text, height: 0.12)
            let title = deskewScore >= fallbackScore ? along.text : fallback.text
            let confidence = deskewScore >= fallbackScore ? along.confidence : fallback.confidence
            let hit = measuredHit(title: title, confidence: confidence, box: box, width: width, height: height, millimetresPerPixel: millimetresPerPixel)
            guard CoverReading.titleScore(title, height: 0.12) > 0 else {
                unreadable += 1
                unread.append(hit)
                continue
            }
            hits.append(hit)
        }
        if hits.isEmpty, unread.count > 0, unread.count <= 2 {
            hits = unread
        }
        hits = collapse(hits)
        let sawCover = covers.contains { observation in
            let box = observation.boundingBox
            let short = min(box.width, box.height)
            let long = max(box.width, box.height)
            guard long > 0 else { return false }
            let aspect = short / long
            return box.width * box.height > 0.06 && aspect > 0.45 && aspect < 0.85
        }
        let cue: ScanCue
        if !hits.isEmpty {
            cue = .read
        } else if unreadable > 0 {
            cue = .straighten
        } else if sawCover {
            cue = .showSpine
        } else {
            cue = .none
        }
        return (hits, cue, marks)
    }

    private func hitsFromLines(_ lines: [CoverLine], width: Double, height: Double, millimetresPerPixel: Double?) -> [SpineHit]? {
        let reads = CoverReading.inventory(lines)
        guard reads.count >= 3 else { return nil }
        return reads.map { read in
            var hit = measuredHit(title: read.title, confidence: read.confidence, box: read.box, width: width, height: height, millimetresPerPixel: millimetresPerPixel)
            hit.shelf = read.shelf
            return hit
        }
    }

    private func measuredHit(title: String, confidence: Float, box: NormBox, width: Double, height: Double, millimetresPerPixel: Double?) -> SpineHit {
        let widthPx = box.width * width
        let heightPx = box.height * height
        let widthCm = millimetresPerPixel.map { MeasureMath.centimetres(pixels: widthPx, millimetresPerPixel: $0) }
        let heightCm = millimetresPerPixel.map { MeasureMath.centimetres(pixels: heightPx, millimetresPerPixel: $0) }
        let upright = heightPx >= widthPx
        return SpineHit(
            text: title,
            shelf: Int(box.midY * 8),
            midX: box.midX,
            heightCm: upright ? heightCm : widthCm,
            thicknessCm: upright ? widthCm : heightCm,
            confidence: confidence,
            frameRef: "",
            box: box
        )
    }

    private func isSpineQuad(_ observation: VNRectangleObservation) -> Bool {
        let top = hypot(observation.topRight.x - observation.topLeft.x, observation.topRight.y - observation.topLeft.y)
        let side = hypot(observation.bottomLeft.x - observation.topLeft.x, observation.bottomLeft.y - observation.topLeft.y)
        let long = max(top, side)
        let short = min(top, side)
        guard long >= 0.12, short > 0 else { return false }
        let aspect = short / long
        return aspect >= 0.035 && aspect <= 0.30
    }

    private func normBox(_ box: CGRect) -> NormBox {
        NormBox(x: box.origin.x, y: box.origin.y, width: box.width, height: box.height)
    }

    private func straighten(_ observation: VNRectangleObservation, image: CIImage) -> CIImage? {
        let extent = image.extent
        func px(_ point: CGPoint) -> CGPoint {
            CGPoint(x: extent.minX + point.x * extent.width, y: extent.minY + point.y * extent.height)
        }
        let top = hypot(observation.topRight.x - observation.topLeft.x, observation.topRight.y - observation.topLeft.y)
        let side = hypot(observation.bottomLeft.x - observation.topLeft.x, observation.bottomLeft.y - observation.topLeft.y)
        var topLeft = px(observation.topLeft)
        var topRight = px(observation.topRight)
        var bottomLeft = px(observation.bottomLeft)
        var bottomRight = px(observation.bottomRight)
        if side > top {
            let nextTopLeft = bottomLeft
            let nextTopRight = topLeft
            let nextBottomLeft = bottomRight
            let nextBottomRight = topRight
            topLeft = nextTopLeft
            topRight = nextTopRight
            bottomLeft = nextBottomLeft
            bottomRight = nextBottomRight
        }
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")
        return filter.outputImage
    }

    private func readTitle(_ image: CIImage) -> (text: String, confidence: Float) {
        let upright = recognize(image)
        let flipped = recognize(image.oriented(.down))
        return readingScore(upright) >= readingScore(flipped) ? upright : flipped
    }

    private func recognize(_ image: CIImage) -> (text: String, confidence: Float) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        try? VNImageRequestHandler(ciImage: image, options: [:]).perform([request])
        let lines: [CoverLine] = (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return CoverLine(
                text: best.string,
                box: NormBox(x: box.origin.x, y: box.origin.y, width: box.width, height: box.height),
                confidence: best.confidence
            )
        }
        let chosen = CoverReading.bestTitle(lines)
        return (chosen.text, chosen.confidence)
    }

    private func readingScore(_ read: (text: String, confidence: Float)) -> Float {
        let letters = read.text.filter(\.isLetter).count
        return read.confidence * Float(min(letters, 24))
    }

    private func collapse(_ hits: [SpineHit]) -> [SpineHit] {
        var kept: [SpineHit] = []
        for hit in hits {
            if let index = kept.firstIndex(where: { !$0.box.isEmpty && $0.box.iou(hit.box) > 0.12 }) {
                if CoverReading.titleScore(hit.text, height: 0.1) > CoverReading.titleScore(kept[index].text, height: 0.1) {
                    var better = hit
                    better.box = NormBox.union([kept[index].box, hit.box])
                    kept[index] = better
                }
            } else {
                kept.append(hit)
            }
        }
        return kept
    }

    private func classifiedItem(from results: [VNClassificationObservation], frameRef: String) -> ItemDraft? {
        guard let best = results.first(where: { mappedCategory($0.identifier) != nil && $0.confidence > 0.55 }),
              let category = mappedCategory(best.identifier),
              category != "electronics", category != "shelving" else { return nil }
        let art = category == "framed art"
        return ItemDraft(
            id: "item-\(UUID().uuidString.prefix(8))",
            category: category,
            description: art ? "Framed picture. Asked if it is a print." : humanize(best.identifier),
            brandModel: "",
            frameRef: frameRef,
            widthCm: nil,
            heightCm: nil,
            depthCm: nil,
            status: .needsAppraisal,
            replacementLow: nil,
            replacementHigh: nil,
            source: "",
            url: "",
            retrievedAt: "",
            confidence: Double(best.confidence),
            midX: 0.5,
            midY: 0.5
        )
    }

    private func mappedCategory(_ identifier: String) -> String? {
        let name = identifier.lowercased()
        let table: [(String, String)] = [
            ("bookcase", "shelving"), ("bookshelf", "shelving"), ("shelf", "shelving"),
            ("lamp", "lamp"), ("chandelier", "lamp"),
            ("coffee", "coffee machine"), ("espresso", "coffee machine"),
            ("chair", "furniture"), ("sofa", "furniture"), ("couch", "furniture"), ("table", "furniture"), ("desk", "furniture"),
            ("rug", "rug"), ("carpet", "rug"),
            ("television", "electronics"), ("monitor", "electronics"), ("laptop", "electronics"),
            ("painting", "framed art"), ("picture frame", "framed art"), ("poster", "framed art")
        ]
        return table.first { name.contains($0.0) }?.1
    }

    private func humanize(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ")
    }

    private func sampleLuma(_ buffer: CVPixelBuffer) -> (pixels: [UInt8], width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return ([], 0, 0) }
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        var output = [UInt8]()
        let step = 4
        var y = 0
        var rows = 0
        var cols = 0
        while y < height {
            var x = 0
            var count = 0
            while x < width {
                output.append(pointer[y * row + x])
                x += step
                count += 1
            }
            cols = count
            rows += 1
            y += step
        }
        return (output, cols, rows)
    }

    private func imageOrientation() -> CGImagePropertyOrientation {
        switch UIDevice.current.orientation {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        default: return .right
        }
    }
}

private struct Sampler {
    var bytes: [UInt8]
    var width: Int
    var height: Int

    init?(image: CIImage, width: Int, height: Int, context: CIContext) {
        let extent = image.extent
        guard extent.width > 10, extent.height > 10, width > 8, height > 8 else { return nil }
        let fitted = image.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height))
        let bounds = fitted.extent.integral
        let pixelsWide = max(1, Int(bounds.width))
        let pixelsHigh = max(1, Int(bounds.height))
        let placed = fitted.transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        var buffer = [UInt8](repeating: 0, count: pixelsWide * pixelsHigh * 4)
        context.render(
            placed,
            toBitmap: &buffer,
            rowBytes: pixelsWide * 4,
            bounds: CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        bytes = buffer
        self.width = pixelsWide
        self.height = pixelsHigh
    }

    func runs(horizontal: Bool) -> [Range<Int>] {
        let count = horizontal ? height : width
        var energy = [Double](repeating: 0, count: count)
        if horizontal {
            for y in 0..<height {
                var sum = 0.0
                for x in 0..<width { sum += saturation(x, y) }
                energy[y] = sum / Double(max(width, 1))
            }
        } else {
            for x in 0..<width {
                var sum = 0.0
                for y in 0..<height { sum += saturation(x, y) }
                energy[x] = sum / Double(max(height, 1))
            }
        }
        let peak = energy.max() ?? 0
        guard peak > 10 else { return [] }
        let raw = MeasureMath.runs(energy: energy, floor: peak * 0.42, minimum: max(6, count / 12))
        var split: [Range<Int>] = []
        for run in raw {
            let middle = run.dropFirst(run.count / 5).dropLast(run.count / 5)
            if run.count > count / 3,
               let valley = middle.min(by: { energy[$0] < energy[$1] }),
               energy[valley] < peak * 0.28,
               valley - run.lowerBound > 6,
               run.upperBound - valley > 6 {
                split.append(run.lowerBound..<valley)
                split.append((valley + 1)..<run.upperBound)
            } else {
                split.append(run)
            }
        }
        return split
    }

    func shelfSpans(count wanted: Int, horizontal: Bool) -> [Range<Int>] {
        let limit = horizontal ? height : width
        var found = runs(horizontal: horizontal).sorted { $0.lowerBound < $1.lowerBound }
        if found.isEmpty {
            let size = max(1, limit / max(wanted, 1))
            return (0..<max(wanted, 1)).map { index in
                (index * size)..<min(limit, (index + 1) * size)
            }.filter { $0.count > 6 }
        }
        while found.count > wanted, found.count > 1 {
            var best = 0
            var smallest = Int.max
            for index in 0..<(found.count - 1) {
                let gap = found[index + 1].lowerBound - found[index].upperBound
                if gap < smallest {
                    smallest = gap
                    best = index
                }
            }
            let merged = found[best].lowerBound..<found[best + 1].upperBound
            found.remove(at: best + 1)
            found[best] = merged
        }
        while found.count < wanted {
            guard let index = found.indices.max(by: { found[$0].count < found[$1].count }) else { break }
            let span = found[index]
            let mid = span.lowerBound + span.count / 2
            guard mid - span.lowerBound > 6, span.upperBound - mid > 6 else { break }
            found.remove(at: index)
            found.insert(span.lowerBound..<mid, at: index)
            found.insert(mid..<span.upperBound, at: index + 1)
        }
        if horizontal { return found.sorted { $0.lowerBound > $1.lowerBound } }
        return found
    }

    func bands(in span: Range<Int>, alongY: Bool, minimum: Int = 4) -> [Range<Int>] {
        let length = alongY ? height : width
        var colorful: [Int] = []
        for index in 0..<length {
            var sum = 0.0
            for cross in span {
                sum += alongY ? saturation(cross, index) : saturation(index, cross)
            }
            if sum / Double(max(span.count, 1)) > 16 { colorful.append(index) }
        }
        guard let first = colorful.first, let last = colorful.last, last - first > 16 else { return [] }
        var edges = [Double](repeating: 0, count: last - first + 1)
        if last > first {
            for index in (first + 1)...last {
                var sum = 0.0
                for cross in span {
                    sum += alongY
                        ? difference(x: cross, y: index, otherX: cross, otherY: index - 1)
                        : difference(x: index, y: cross, otherX: index - 1, otherY: cross)
                }
                edges[index - first] = sum / Double(max(span.count, 1))
            }
        }
        return MeasureMath.splitBands(edges: edges, minimum: max(4, minimum)).map { ($0.lowerBound + first)..<($0.upperBound + first) }
    }

    private func saturation(_ x: Int, _ y: Int) -> Double {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        let index = (y * width + x) * 4
        let red = Double(bytes[index])
        let green = Double(bytes[index + 1])
        let blue = Double(bytes[index + 2])
        return max(red, green, blue) - min(red, green, blue)
    }

    private func difference(x: Int, y: Int, otherX: Int, otherY: Int) -> Double {
        guard x >= 0, y >= 0, otherX >= 0, otherY >= 0, x < width, y < height, otherX < width, otherY < height else { return 0 }
        let index = (y * width + x) * 4
        let other = (otherY * width + otherX) * 4
        return abs(Double(bytes[index]) - Double(bytes[other]))
            + abs(Double(bytes[index + 1]) - Double(bytes[other + 1]))
            + abs(Double(bytes[index + 2]) - Double(bytes[other + 2]))
    }
}
