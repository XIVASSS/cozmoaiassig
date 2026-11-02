import CoreMotion
import SwiftUI
import UIKit

struct RootView: View {
    var body: some View {
        HomeView()
    }
}

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var tilt = TiltMotion()
    @StateObject private var place = PlaceLocator()
    @State private var session: SweepSession?
    @State private var showHistory = false
    @State private var showReview = false
    @State private var showSettings = false

    var body: some View {
        GeometryReader { geo in
            let top = geo.safeAreaInsets.top
            let bottom = geo.safeAreaInsets.bottom
            let corner = ScreenCurve.radius(for: geo.size)
            ZStack {
                BubbleField(roll: tilt.roll, pitch: tilt.pitch)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    glassHero(topInset: top, corner: corner)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack(spacing: 8) {
                        Button { showHistory = true } label: { latestCard(radius: corner, bottomInset: bottom) }
                            .buttonStyle(.plain)
                        Button { showReview = true } label: { reviewCard(radius: corner, bottomInset: bottom) }
                            .buttonStyle(.plain)
                    }
                    .frame(height: 172 + bottom)
                }
            }
            .ignoresSafeArea()
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            tilt.start()
            place.start()
            model.reload()
        }
        .onChange(of: place.ready) { _, ready in
            if ready { adoptPlace() }
        }
        .onDisappear { tilt.stop() }
        .fullScreenCover(item: $session, onDismiss: { model.reload() }) { live in
            WalkView(session: live)
        }
        .sheet(isPresented: $showHistory, onDismiss: { model.reload() }) {
            WalksView()
        }
        .sheet(isPresented: $showReview, onDismiss: { model.reload() }) {
            ReviewView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    private func glassHero(topInset: CGFloat, corner: CGFloat) -> some View {
        VStack(spacing: 0) {
            topBar
                .padding(.top, topInset + 8)
                .padding(.horizontal, 20)
            readout
                .padding(.horizontal, 24)
                .padding(.top, 24)
            Spacer(minLength: 0)
            ZStack(alignment: .bottom) {
                dial
                    .frame(maxWidth: .infinity)
                    .frame(height: 210)
                HStack {
                    Button {
                        openWalk(practice: true)
                    } label: {
                        Text("Practice")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Practice the rules")
                    Spacer()
                    Text("One room")
                }
                .font(Theme.sans(13))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 28)
                .padding(.bottom, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            heroShape(corner: corner)
                .fill(.ultraThinMaterial)
                .overlay(heroShape(corner: corner).fill(Color.black.opacity(0.02)))
        }
        .overlay {
            heroShape(corner: corner)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                .mask(
                    LinearGradient(
                        colors: [.clear, .clear, .white.opacity(0.35), .white],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .clipShape(heroShape(corner: corner))
    }

    private func heroShape(corner: CGFloat) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: corner,
            bottomTrailingRadius: corner,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    private var topBar: some View {
        HStack {
            glassButton("books.vertical", label: "Walks") { showHistory = true }
            Spacer()
            Button { showSettings = true } label: {
                Text("Sweep")
                    .font(Theme.sans(15, weight: .light))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            Spacer()
            glassButton("checklist", label: "Review") { showReview = true }
        }
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Books identified")
                .font(Theme.sans(15, weight: .light))
                .foregroundStyle(.white.opacity(0.78))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(count)
                    .font(.system(size: 84, weight: .light))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("books")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(place.currency)
                        .font(Theme.sans(13, weight: .light))
                    Text(place.ready ? place.city : "Finding this place")
                        .font(Theme.sans(13, weight: .light))
                        .lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.82))
                .accessibilityLabel(place.ready ? "\(place.city), \(place.currency)" : "Finding this place")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dial: some View {
        ZStack {
            ToneDial(roll: tilt.roll, pitch: tilt.pitch)
                .allowsHitTesting(false)
            Button {
                openWalk(practice: false)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.black)
                    .frame(width: 68, height: 68)
                    .background(.white, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start a walk. The camera stays off until you begin.")
        }
    }

    private func latestCard(radius: CGFloat, bottomInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Latest packet")
                    .font(Theme.sans(15, weight: .medium))
                Spacer(minLength: 6)
                Text(share)
                    .font(Theme.sans(13, weight: .light))
            }
            .foregroundStyle(.black.opacity(0.82))
            Spacer(minLength: 8)
            HStack {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 16, weight: .medium))
                    Text(latest == nil ? "NONE" : "OPEN")
                        .font(Theme.mono(10))
                        .tracking(0.8)
                }
                .foregroundStyle(.black.opacity(0.72))
                .frame(width: 72, height: 72)
                .background(.black.opacity(0.05), in: Circle())
                Spacer()
            }
            Text(caption)
                .font(Theme.sans(13, weight: .light))
                .foregroundStyle(.black.opacity(0.55))
                .lineLimit(2)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, max(18, bottomInset))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.92))
        .modifier(ScreenDock(radius: radius, pinsLeading: true, pinsTrailing: false, stroke: nil))
    }

    private func reviewCard(radius: CGFloat, bottomInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("To review")
                .font(Theme.sans(15, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(reviewCount)
                    .font(.system(size: 48, weight: .light))
                Text("lines")
                    .font(.system(size: 16, weight: .light))
                    .opacity(0.75)
            }
            .foregroundStyle(.white)
            Spacer(minLength: 8)
            reviewTrack
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, max(18, bottomInset))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Rectangle().fill(Color.black.opacity(0.22)))
        }
        .modifier(ScreenDock(radius: radius, pinsLeading: false, pinsTrailing: true, stroke: Color.white.opacity(0.12)))
    }

    private var reviewTrack: some View {
        Text("Hunches, missing prices, and art. Nothing here is in the money.")
            .font(Theme.sans(13, weight: .light))
            .foregroundStyle(.white.opacity(0.72))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func glassButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.16), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.28), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func openWalk(practice: Bool) {
        if place.ready { adoptPlace() }
        session = SweepSession(settings: model.settings, store: model.store, practice: practice)
    }

    private func adoptPlace() {
        var settings = model.settings
        settings.country = place.country
        settings.currency = place.currency
        settings.claimConfirmed = true
        model.updateSettings(settings)
    }

    private var count: String {
        guard let latest = model.sessions.first, latest.packetVersion > 0 else { return "—" }
        return "\(latest.bookCount)"
    }

    private var latest: SessionSummary? {
        guard let item = model.sessions.first, item.packetVersion > 0 else { return nil }
        return item
    }

    private var share: String {
        guard let latest else { return "—" }
        guard latest.packetVersion > 0 else { return "Open" }
        return "v\(latest.packetVersion)"
    }

    private var caption: String {
        guard let latest else { return "Nothing filed yet." }
        return "\(latest.bookCount) identified"
    }

    private var reviewCount: String {
        guard let latest else { return "—" }
        return "\(latest.reviewCount)"
    }

}

/// Device tilt, with a slow drift so the mark still moves when the phone is still.
final class TiltMotion: ObservableObject {
    @Published var roll = 0.0
    @Published var pitch = 0.0
    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.roll = min(1, max(-1, motion.attitude.roll / 0.5))
            self.pitch = min(1, max(-1, motion.attitude.pitch / 0.5))
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}

/// Display corner radius in points. Apple's Liquid Glass layout calls this concentric:
/// the corner that sits on the glass uses the panel's own radius.
/// https://developer.apple.com/documentation/swiftui/concentricrectangle
/// The point values are the ones iOS uses per device. Apple does not print them in the
/// Liquid Glass overview; they come from the device definitions.
private enum ScreenCurve {
    static func radius(for size: CGSize) -> CGFloat {
        let width = min(size.width, size.height)
        let height = max(size.width, size.height)
        func matches(_ panelWidth: CGFloat, _ panelHeight: CGFloat) -> Bool {
            abs(width - panelWidth) < 2 && abs(height - panelHeight) < 2
        }
        // 62: iPhone 16 Pro, 16 Pro Max, 17, 17 Pro, 17 Pro Max, Air, 18 Pro, 18 Pro Max.
        if matches(402, 874) || matches(440, 956) || matches(420, 912) { return 62 }
        // 55: iPhone 14 Pro through 16 and 16 Plus.
        if matches(393, 852) || matches(430, 932) { return 55 }
        if matches(428, 926) || matches(414, 896) { return 53.33 }
        if matches(390, 844) { return 47.33 }
        if matches(375, 812) { return 39 }
        if matches(360, 780) { return 44 }
        if height >= 874 { return 62 }
        if height >= 844 { return 55 }
        return 47.33
    }
}

/// Pins the outer bottom corner to the display curve and keeps the other corners at that same radius.
private struct ScreenDock: ViewModifier {
    var radius: CGFloat
    var pinsLeading: Bool
    var pinsTrailing: Bool
    var stroke: Color?

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            let shape = ConcentricRectangle(
                topLeadingCorner: .fixed(radius),
                topTrailingCorner: .fixed(radius),
                bottomLeadingCorner: pinsLeading ? .concentric(minimum: .fixed(radius)) : .fixed(radius),
                bottomTrailingCorner: pinsTrailing ? .concentric(minimum: .fixed(radius)) : .fixed(radius)
            )
            content
                .overlay {
                    if let stroke {
                        shape.stroke(stroke, lineWidth: 1)
                    }
                }
                .clipShape(shape)
        } else {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            content
                .overlay {
                    if let stroke {
                        shape.stroke(stroke, lineWidth: 1)
                    }
                }
                .clipShape(shape)
        }
    }
}

/// The fluid photo, larger than the screen, so tilt and a slow drift slide it.
private struct BubbleField: View {
    var roll: Double
    var pitch: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let driftX = CGFloat(sin(time * 0.22) * 16 + roll * 46)
            let driftY = CGFloat(cos(time * 0.17) * 12 + pitch * 34)
            GeometryReader { geo in
                bubble
                    .scaledToFill()
                    .frame(width: geo.size.width * 1.45, height: geo.size.height * 1.45)
                    .offset(
                        x: -geo.size.width * 0.18 + driftX,
                        y: -geo.size.height * 0.16 + driftY
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var bubble: some View {
        if let image = UIImage(named: "FluidBubble") ?? bundleImage {
            Image(uiImage: image)
                .resizable()
        } else {
            Color(red: 0.08, green: 0.12, blue: 0.06)
        }
    }

    private var bundleImage: UIImage? {
        guard let url = Bundle.main.url(forResource: "FluidBubble", withExtension: "png") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

/// A round tick dial. The mark follows the phone's tilt.
private struct ToneDial: View {
    var roll: Double
    var pitch: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let wander = sin(t * 0.7) * 0.38 + sin(t * 0.23) * 0.16
            let moving = abs(roll) + abs(pitch) > 0.05
            let along = min(1, max(-1, moving ? roll * 0.8 + wander * 0.2 : wander))
            mark(along: along, drift: moving ? pitch : wander * 0.4)
        }
    }

    private func mark(along: Double, drift: Double) -> some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) * 0.42
            let center = CGPoint(x: size.width / 2 + drift * 6, y: size.height * 0.62)
            let start = 200.0 * .pi / 180
            let sweep = 140.0 * .pi / 180

            func point(on unit: Double, extra: CGFloat = 0) -> CGPoint {
                let theta = start + (unit + 1) / 2 * sweep
                let reach = radius + extra
                return CGPoint(
                    x: center.x + CGFloat(cos(theta)) * reach,
                    y: center.y + CGFloat(sin(theta)) * reach
                )
            }

            var guide = Path()
            for step in 0...48 {
                let spot = point(on: -1 + 2 * Double(step) / 48)
                if step == 0 { guide.move(to: spot) } else { guide.addLine(to: spot) }
            }
            context.stroke(guide, with: .color(.white.opacity(0.28)), style: StrokeStyle(lineWidth: 1, lineCap: .round))

            for step in 0...28 {
                let unit = -1 + 2 * Double(step) / 28
                let theta = start + (unit + 1) / 2 * sweep
                let major = step % 7 == 0
                let inner = radius - (major ? 10 : 6)
                let outer = radius + (major ? 4 : 1)
                var tick = Path()
                tick.move(to: CGPoint(x: center.x + CGFloat(cos(theta)) * inner, y: center.y + CGFloat(sin(theta)) * inner))
                tick.addLine(to: CGPoint(x: center.x + CGFloat(cos(theta)) * outer, y: center.y + CGFloat(sin(theta)) * outer))
                context.stroke(tick, with: .color(.white.opacity(major ? 0.9 : 0.45)), style: StrokeStyle(lineWidth: major ? 1.4 : 1, lineCap: .round))
            }

            let knob = point(on: along)
            let head = CGRect(x: knob.x - 5, y: knob.y - 5, width: 10, height: 10)
            context.fill(Path(ellipseIn: head), with: .color(.white))
        }
    }
}
