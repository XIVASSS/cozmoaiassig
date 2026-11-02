import ARKit
import RealityKit
import SwiftUI
import TipKit

struct WalkView: View {
    @ObservedObject var session: SweepSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            stage
                .ignoresSafeArea()
            spineMarks
            if session.showRings {
                DistanceRings(progress: session.ringProgress)
            }
            VStack(spacing: 16) {
                if showGuide {
                    SpineGuide(straighten: session.cue == .straighten)
                        .padding(.top, 12)
                }
                Spacer()
                inventory
                if !session.engine.instruction.isEmpty {
                    direction
                }
                control
                    .modifier(EndWalkTipAnchor(practice: session.practice))
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 28)
        }
        .background(Color.black)
        .task { await begin() }
        .onDisappear { session.closeOpenWalk() }
    }

    private var stage: some View {
        Group {
            if session.practice {
                Color.black
            } else if session.cameraReady {
                CameraPreview(session: session.capture.session)
            } else {
                Theme.canvas
            }
        }
    }

    private var showGuide: Bool {
        if session.showRings || session.focusMark != nil { return false }
        switch session.cue {
        case .showSpine, .straighten: return true
        case .read: return false
        case .none: return false
        }
    }

    private var spineMarks: some View {
        GeometryReader { geo in
            if let mark = session.focusMark {
                spineGlow(mark, in: geo.size)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private func spineGlow(_ mark: NormBox, in size: CGSize) -> some View {
        let wide = mark.width >= mark.height
        let width = max(wide ? 48 : 22, mark.width * size.width)
        let height = max(wide ? 22 : 48, mark.height * size.height)
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return shape
            .fill(Color.white.opacity(0.28))
            .overlay(shape.stroke(Color.white, lineWidth: 4))
            .shadow(color: .white.opacity(0.95), radius: 18)
            .frame(width: width, height: height)
            .position(x: mark.midX * size.width, y: (1 - mark.midY) * size.height)
    }

    private var inventory: some View {
        let filed = session.engine.books.filter { !$0.excluded }
        let rows = session.packet == nil ? Array(filed.suffix(4)) : filed
        return VStack(alignment: .leading, spacing: 6) {
            Text(filed.isEmpty ? "Walk this room once, then end the walk." : "\(filed.count) \(filed.count == 1 ? "book" : "books")")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ash)
            Group {
                if rows.count > 5 {
                    ScrollView {
                        spineLines(rows)
                    }
                    .frame(maxHeight: 220)
                } else {
                    spineLines(rows)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Theme.graphite.opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func spineLines(_ rows: [BookDraft]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { book in
                Text(line(for: book))
                    .font(Theme.sans(15))
                    .foregroundStyle(Theme.cloud)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func line(for book: BookDraft) -> String {
        if !book.title.isEmpty { return book.title }
        if !book.candidateTitle.isEmpty { return "Hunch · \(book.candidateTitle)" }
        if let height = book.spineHeightCm, let thick = book.spineThicknessCm {
            return String(format: "Unidentified spine · %.0f × %.0f cm", height, thick)
        }
        return "Unidentified spine"
    }

    private var direction: some View {
        Text(session.engine.instruction)
            .font(.body)
            .foregroundStyle(Theme.cloud)
            .multilineTextAlignment(.center)
            .lineLimit(5)
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .frame(maxWidth: 340)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var control: some View {
        Button {
            if session.packet != nil {
                dismiss()
            } else {
                EndWalkTip().invalidate(reason: .actionPerformed)
                Task { await session.endWalk() }
            }
        } label: {
            Text(walkButton)
                .font(.headline)
                .foregroundStyle(Theme.void)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(Theme.pure, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(session.packet == nil && (session.reading || session.engine.phase == .finishing))
    }

    private var walkButton: String {
        if session.packet != nil { return "Done" }
        if session.reading || session.engine.phase == .finishing { return "Reading" }
        return "End walk"
    }

    private func begin() async {
        if session.practice {
            await session.runPractice()
        } else {
            session.start()
        }
    }
}

struct DistanceRings: View {
    var progress: Double

    var body: some View {
        let amount = min(1, max(0, progress))
        ZStack {
            Circle()
                .stroke(Theme.cyan, lineWidth: 2)
                .frame(width: 168, height: 168)
            Circle()
                .fill(Theme.cyan.opacity(0.85))
                .frame(width: 26 + 142 * amount, height: 26 + 142 * amount)
        }
        .allowsHitTesting(false)
    }
}

private struct EndWalkTipAnchor: ViewModifier {
    var practice: Bool

    func body(content: Content) -> some View {
        if practice {
            content
        } else {
            content.popoverTip(EndWalkTip(), arrowEdge: .top)
        }
    }
}

struct SpineGuide: View {
    var straighten: Bool

    var body: some View {
        Label(straighten ? "Hold still" : "Walk the shelf", systemImage: straighten ? "pause.circle" : "figure.walk")
            .font(.headline)
            .foregroundStyle(Theme.cloud)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = session
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        if uiView.session !== session {
            uiView.session = session
        }
    }
}
