import SwiftUI

enum Theme {
    static let canvas = Color(hex: 0x0F1011)
    static let abyss = Color(hex: 0x090A0B)
    static let graphite = Color(hex: 0x2E2E2E)
    static let steel = Color(hex: 0x3F4041)
    static let silver = Color(hex: 0xCACACA)
    static let fog = Color(hex: 0x6A6B6B)
    static let ash = Color(hex: 0x9F9FA0)
    static let cloud = Color(hex: 0xF5F5F7)
    static let pure = Color.white
    static let void = Color.black
    static let iris = Color(hex: 0x847DFF)
    static let deepIris = Color(hex: 0x4B49AA)
    static let paleIris = Color(hex: 0xD1C9FF)
    static let cyan = Color(hex: 0x00B3DD)
    static let orchid = Color(hex: 0xDD90D8)
    static let periwinkle = Color(hex: 0x90B8F0)

    static let card = graphite
    static let ink = cloud
    static let muted = ash
    static let lime = iris
    static let charcoal = abyss
    static let line = Color.white.opacity(0.12)
    static let radius: CGFloat = 30

    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold)
    }

    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case home, walks, review, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .walks: return "Walks"
        case .review: return "Review"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .walks: return "list.bullet"
        case .review: return "exclamationmark.circle.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct FloatingTabBar: View {
    @Binding var tab: AppTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 16, weight: .semibold))
                        if tab == item {
                            Text(item.title)
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .font(Theme.sans(14))
                    .foregroundStyle(tab == item ? Theme.void : Theme.ash)
                    .padding(.horizontal, tab == item ? 16 : 13)
                    .frame(height: 46)
                    .background(tab == item ? Theme.pure : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial)
        .background(Theme.abyss.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
}

struct Pill: View {
    enum Style { case white, lime, charcoal }
    var title: String
    var style: Style = .white

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(foreground)
            .background(background)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(border, lineWidth: style == .white ? 1 : 0))
    }

    private var foreground: Color {
        switch style {
        case .white: return Theme.cloud
        case .lime: return Theme.void
        case .charcoal: return Theme.void
        }
    }

    private var background: Color {
        switch style {
        case .white: return Theme.graphite
        case .lime: return Theme.paleIris
        case .charcoal: return Theme.pure
        }
    }

    private var border: Color {
        style == .white ? Theme.line : .clear
    }
}

struct LimeButton: View {
    var title: String
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(Theme.sans(16))
                Spacer(minLength: 8)
                Image(systemName: "arrow.right")
                    .font(Theme.sans(16))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(minHeight: 48)
            .background(Theme.pure)
            .clipShape(Capsule())
            .foregroundStyle(Theme.void)
        }
        .buttonStyle(.plain)
    }
}

struct QuietButton: View {
    var title: String
    var systemImage: String = "arrow.right"
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(Theme.sans(16))
                Spacer(minLength: 8)
                Image(systemName: systemImage)
                    .font(Theme.sans(16))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(minHeight: 48)
            .background(Color.clear)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Theme.pure.opacity(0.35), lineWidth: 1))
            .foregroundStyle(Theme.pure)
        }
        .buttonStyle(.plain)
    }
}

struct StatCard: View {
    var eyebrow: String
    var value: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(eyebrow)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.void.opacity(0.62))
            Text(value)
                .font(Theme.display(72))
                .foregroundStyle(Theme.void)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(detail)
                .font(Theme.sans(16, weight: .light))
                .foregroundStyle(Theme.void.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .leading)
        .padding(32)
        .background(Theme.silver)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

struct PageTitle: View {
    var title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(Theme.cloud)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.sans(16, weight: .light))
                    .foregroundStyle(Theme.ash)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SectionLabel: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.ash)
    }
}

struct EmptyNote: View {
    var text: String

    var body: some View {
        Text(text)
            .font(Theme.sans(16, weight: .light))
            .foregroundStyle(Theme.ash)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(32)
            .background(Theme.graphite)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct SessionRow: View {
    var summary: SessionSummary

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(when)
                    .font(Theme.sans(17))
                    .foregroundStyle(Theme.cloud)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Theme.sans(14))
                    .foregroundStyle(Theme.ash)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if summary.practice {
                Text("Practice")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.ash)
            } else if summary.packetVersion > 0 {
                Text("Version \(summary.packetVersion)")
                    .font(.caption)
                    .foregroundStyle(Theme.ash)
            }
            Image(systemName: "chevron.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.ash)
        }
        .padding(18)
        .frame(minHeight: 104)
        .background(Theme.graphite)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var when: String {
        let day = summary.capturedAt.formatted(.dateTime.day().month(.abbreviated))
        let time = summary.capturedAt.formatted(.dateTime.hour().minute())
        return "\(day) · \(time)"
    }

    private var subtitle: String {
        if summary.packetVersion == 0 {
            return "Walk open · \(summary.bookCount) books"
        }
        return "\(summary.bookCount) books · \(summary.reviewCount) to review"
    }
}

struct InventoryRow: View {
    var title: String
    var detail: String
    var kind: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.sans(16))
                    .foregroundStyle(Theme.cloud)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.ash)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(kind)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(badgeFill)
                .foregroundStyle(badgeInk)
                .clipShape(Capsule())
        }
        .padding(16)
        .background(Theme.graphite)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var badgeFill: Color {
        switch kind {
        case "Hunch", "Practice": return Theme.paleIris
        case "Appraisal", "needsAppraisal", "needs_appraisal": return Theme.pure
        default: return Theme.steel
        }
    }

    private var badgeInk: Color {
        switch kind {
        case "Hunch", "Practice", "Appraisal", "needsAppraisal", "needs_appraisal": return Theme.void
        default: return Theme.cloud
        }
    }
}

extension View {
    func sweepScreen() -> some View {
        background(Theme.canvas)
            .toolbarBackground(Theme.canvas, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
    }

    /// System glass. On iOS 26 this is Liquid Glass: the background refracts through a lit rim.
    /// `clear` is the see-through capsule used over a gradient. `regular` is the softer glass used on paper.
    @ViewBuilder
    func systemGlass<S: Shape>(in shape: S, interactive: Bool = false, clear: Bool = false) -> some View {
        if #available(iOS 26, *) {
            let glass: Glass = clear ? .clear : .regular
            if interactive {
                glassEffect(glass.interactive(), in: shape)
            } else {
                glassEffect(glass, in: shape)
            }
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }

    /// Groups Liquid Glass shapes so a control can sit as glass on a glass card.
    @ViewBuilder
    func glassGrouped<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 28) {
                content()
            }
        } else {
            content()
        }
    }
}

struct HunchMark: View {
    var busy: Bool
    var accept: () -> Void
    var reject: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: accept) {
                Label("Keep", systemImage: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.void)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.pure, in: Capsule())
            }
            .accessibilityLabel("Keep this hunch")
            Button(action: reject) {
                Label("Remove", systemImage: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.cloud)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.steel, in: Capsule())
            }
            .accessibilityLabel("Remove this hunch")
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.45 : 1)
    }
}
