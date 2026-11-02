import Foundation

enum PracticeWalk {
    /// Same rules as a live walk, with scripted observations and no prices.
    static func make(sessionID: String, settings: WalkSettings = .unitedStates) -> WalkEngine {
        var engine = WalkEngine()
        engine.begin(sessionID: sessionID, settings: settings, device: "practice-replay", practice: true)
        engine.confirmCountry()
        engine.noteCard(millimetresPerPixel: 0.2, distanceM: 0.6, arkitCardMeters: 0.09)
        engine.noteSpines([
            SpineHit(text: "The Odyssey", shelf: 2, midX: 0.2, heightCm: 20.2, thicknessCm: 3.1, confidence: 0.92, frameRef: "frames/practice.jpg"),
            SpineHit(text: "zz", shelf: 2, midX: 0.42, heightCm: 18, thicknessCm: 2.4, confidence: 0.2, frameRef: "frames/practice.jpg"),
            SpineHit(text: "", shelf: 2, midX: 0.62, heightCm: 21, thicknessCm: 4, confidence: 0, frameRef: "frames/practice.jpg")
        ])
        engine.resolve(trackID: engine.books.first(where: { $0.candidateTitle.contains("Odyssey") })?.id ?? "", match: CatalogueMatch(
            title: "The Odyssey",
            author: "Homer",
            isbn: "9780140268867",
            publisher: "Penguin",
            firstPublishYear: nil,
            score: 0.9
        ))
        engine.noteObject(ItemDraft(
            id: "item-lamp",
            category: "lamp",
            description: "Lamp seen in the room.",
            brandModel: "",
            frameRef: "frames/practice.jpg",
            widthCm: 18,
            heightCm: 40,
            depthCm: nil,
            status: .needsAppraisal,
            replacementLow: nil,
            replacementHigh: nil,
            source: "",
            url: "",
            retrievedAt: "",
            confidence: 0.7,
            midX: 0.2,
            midY: 0.5
        ))
        engine.noteObject(ItemDraft(
            id: "item-art",
            category: "framed art",
            description: "Framed picture. Asked if it is a print.",
            brandModel: "",
            frameRef: "frames/practice.jpg",
            widthCm: 40,
            heightCm: 50,
            depthCm: nil,
            status: .needsAppraisal,
            replacementLow: nil,
            replacementHigh: nil,
            source: "",
            url: "",
            retrievedAt: "",
            confidence: 0.66,
            midX: 0.7,
            midY: 0.4
        ))
        engine.noteRoom(RoomObservation(
            floorWidthM: 3.4,
            floorDepthM: 2.8,
            floorAreaM2: 9.52,
            wallAreaM2: 24.8,
            ceilingHeightM: 2.6,
            shelfFaceAreaM2: 1.4,
            shapeNote: "Single floor plane.",
            planeCount: 1
        ))
        return engine
    }
}
