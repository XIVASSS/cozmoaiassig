import SwiftUI
import TipKit
import UIKit

struct RootView: View {
    var body: some View {
        HomeView()
    }
}

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var place = PlaceLocator()
    @State private var session: SweepSession?
    @State private var showHistory = false
    @State private var showReview = false
    @State private var showSettings = false

    var body: some View {
        GeometryReader { geo in
            let top = geo.safeAreaInsets.top
            let corner = ScreenCurve.radius(for: geo.size)
            let edge: CGFloat = 12
            let screen = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            ZStack {
                BubbleField()
                    .ignoresSafeArea()
                VStack(spacing: edge) {
                    glassHero(topInset: top, corner: corner)
                        .frame(maxWidth: .infinity)
                        .frame(height: screen * 35 / 48)
                    HStack(spacing: edge) {
                        Button {
                            LatestWalkTip().invalidate(reason: .actionPerformed)
                            Walkthrough.advance(to: 3)
                            showHistory = true
                        } label: { latestCard(radius: corner - edge, bottomInset: 0) }
                            .buttonStyle(.plain)
                            .popoverTip(LatestWalkTip(), arrowEdge: .bottom)
                        Button {
                            ReviewTip().invalidate(reason: .actionPerformed)
                            Walkthrough.advance(to: 2)
                            showReview = true
                        } label: { reviewCard(radius: corner - edge, bottomInset: 0) }
                            .buttonStyle(.plain)
                            .popoverTip(ReviewTip(), arrowEdge: .bottom)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, edge)
                    .padding(.bottom, edge)
                }
                .frame(height: screen)
            }
            .ignoresSafeArea()
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            place.start()
            model.reload()
        }
        .task { await Walkthrough.watch(StartWalkTip(), advanceTo: 1) }
        .task { await Walkthrough.watch(ReviewTip(), advanceTo: 2) }
        .task { await Walkthrough.watch(LatestWalkTip(), advanceTo: 3) }
        .onChange(of: place.ready) { _, ready in
            if ready { adoptPlace() }
        }
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
            Button {
                StartWalkTip().invalidate(reason: .actionPerformed)
                Walkthrough.advance(to: 1)
                openWalk(practice: false)
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.black)
                        .frame(width: 68, height: 68)
                        .background(.white, in: Circle())
                    Text("Start walk")
                        .font(.headline)
                    Text("One room")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.72))
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start a walk of one room")
            .popoverTip(StartWalkTip(), arrowEdge: .top)
            .padding(.bottom, 28)
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
        ZStack {
            Text("Sweep")
                .font(.headline)
                .foregroundStyle(.white)
            HStack {
                Button {
                    PracticeTip().invalidate(reason: .actionPerformed)
                    openWalk(practice: true)
                } label: {
                    Text("Practice")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Practice the rules")
                .popoverTip(PracticeTip(), arrowEdge: .bottom)
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.white.opacity(0.16), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
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
            }
            Label(place.ready ? "\(place.city) · \(place.currency)" : "Finding this place", systemImage: "location")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.82))
                .padding(.top, 8)
                .accessibilityLabel(place.ready ? "Prices for \(place.city), \(place.currency)" : "Finding this place")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func latestCard(radius: CGFloat, bottomInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Latest walk")
                    .font(.headline)
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.black.opacity(0.88))
            Spacer(minLength: 8)
            Text(caption)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.black.opacity(0.9))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if latest != nil {
                Text(share)
                    .font(.subheadline)
                    .foregroundStyle(.black.opacity(0.55))
            }
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
            HStack(alignment: .firstTextBaseline) {
                Text("To review")
                    .font(.headline)
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .opacity(0.7)
            }
            .foregroundStyle(.white.opacity(0.92))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(reviewCount)
                    .font(.system(size: 48, weight: .semibold))
                Text("to check")
                    .font(.body)
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
        Text("Hunches and missing prices. Not in the total.")
            .font(Theme.sans(13, weight: .light))
            .foregroundStyle(.white.opacity(0.72))
            .fixedSize(horizontal: false, vertical: true)
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
        guard let latest else { return "0" }
        return "\(latest.bookCount)"
    }

    private var latest: SessionSummary? {
        model.sessions.first { $0.packetVersion > 0 }
    }

    private var share: String {
        guard let latest else { return "" }
        return "Version \(latest.packetVersion)"
    }

    private var caption: String {
        guard let latest else { return "Nothing filed yet." }
        let books = latest.bookCount == 1 ? "book" : "books"
        return "\(latest.bookCount) \(books) identified"
    }

    private var reviewCount: String {
        guard let latest else { return "0" }
        return "\(latest.reviewCount)"
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

/// The fluid photo, larger than the screen, drifting slowly on its own.
private struct BubbleField: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let driftX = CGFloat(sin(time * 0.22) * 16)
            let driftY = CGFloat(cos(time * 0.17) * 12)
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
