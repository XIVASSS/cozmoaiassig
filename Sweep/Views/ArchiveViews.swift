import SwiftUI
import TipKit

struct WalksView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var practice: SweepSession?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PageTitle(
                        title: "Walks",
                        subtitle: "Each finished scan keeps its packet. Confirming a hunch writes the next version."
                    )
                    Button {
                        practice = SweepSession(settings: model.settings, store: model.store, practice: true)
                    } label: {
                        Text("Practice the rules")
                            .font(Theme.sans(16))
                            .foregroundStyle(Theme.void)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(Theme.pure)
                            .clipShape(Capsule())
                            .padding(.bottom, 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Practice the rules")
                    if model.sessions.isEmpty {
                        EmptyNote(text: "No scans yet. Scan the shelves from Home, or practice the rules.")
                    }
                    ForEach(model.sessions) { summary in
                        NavigationLink {
                            SessionDetailView(sessionID: summary.id)
                        } label: {
                            SessionRow(summary: summary)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete", role: .destructive) { model.delete(summary.id) }
                        }
                    }
                }
                .padding(20)
            }
            .sweepScreen()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
            .onAppear { model.reload() }
            .fullScreenCover(item: $practice, onDismiss: { model.reload() }) { live in
                WalkView(session: live)
            }
        }
    }
}

struct ReviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var busyID = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    PageTitle(
                        title: "Review",
                        subtitle: "Each scan keeps its own hunches. Nothing here is in the money."
                    )
                    TipView(ReviewPageTip())
                    let walks = reviewWalks
                    if walks.isEmpty {
                        EmptyNote(text: "The queue is empty.")
                    }
                    ForEach(walks) { walk in
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(walk.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.cloud)
                                Text(walk.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.ash)
                            }
                            ForEach(walk.entries) { entry in
                                HStack(alignment: .center, spacing: 8) {
                                    NavigationLink {
                                        SessionDetailView(sessionID: entry.sessionID)
                                    } label: {
                                        HStack(alignment: .center, spacing: 12) {
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(entry.isHunch ? entry.hunchTitle : entry.reason)
                                                    .font(.body)
                                                    .foregroundStyle(Theme.cloud)
                                                if entry.isHunch {
                                                    Text(entry.reason)
                                                        .font(.subheadline)
                                                        .foregroundStyle(Theme.ash)
                                                }
                                            }
                                            Spacer(minLength: 8)
                                            Image(systemName: "chevron.right")
                                                .font(.footnote.weight(.semibold))
                                                .foregroundStyle(Theme.ash)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(18)
                                        .background(Theme.graphite)
                                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    if entry.isHunch {
                                        HunchMark(busy: busyID == entry.id) {
                                            Task { await mark(entry, keep: true) }
                                        } reject: {
                                            Task { await mark(entry, keep: false) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .sweepScreen()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
            .onAppear { model.reload() }
        }
    }

    private var reviewWalks: [ReviewWalk] {
        let entries = model.reviewEntries()
        var order: [String] = []
        var grouped: [String: [ReviewEntry]] = [:]
        for entry in entries {
            if grouped[entry.sessionID] == nil {
                order.append(entry.sessionID)
            }
            grouped[entry.sessionID, default: []].append(entry)
        }
        return order.compactMap { id in
            guard let items = grouped[id] else { return nil }
            let summary = model.sessions.first { $0.id == id }
            return ReviewWalk(
                id: id,
                title: summary.map(Self.walkTitle) ?? "Walk",
                detail: Self.walkDetail(summary: summary, count: items.count),
                entries: items
            )
        }
    }

    private static func walkTitle(_ summary: SessionSummary) -> String {
        let day = summary.capturedAt.formatted(.dateTime.day().month(.abbreviated))
        let time = summary.capturedAt.formatted(.dateTime.hour().minute())
        return "\(day) · \(time)"
    }

    private static func walkDetail(summary: SessionSummary?, count: Int) -> String {
        let checks = count == 1 ? "1 to check" : "\(count) to check"
        if summary?.practice == true {
            return "Practice · \(checks)"
        }
        if let version = summary?.packetVersion, version > 0 {
            return "Version \(version) · \(checks)"
        }
        return checks
    }

    private func mark(_ entry: ReviewEntry, keep: Bool) async {
        busyID = entry.id
        if keep {
            await model.acceptHunch(sessionID: entry.sessionID, version: entry.packetVersion, bookID: entry.refID)
        } else {
            await model.dropHunch(sessionID: entry.sessionID, version: entry.packetVersion, bookID: entry.refID)
        }
        busyID = ""
    }
}

private struct ReviewWalk: Identifiable {
    var id: String
    var title: String
    var detail: String
    var entries: [ReviewEntry]
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PageTitle(
                        title: "Settings",
                        subtitle: "Location sets the country and currency. These lines send a price to a person."
                    )
                    settingCard(
                        title: "Country and currency",
                        value: "\(model.settings.country) · \(model.settings.currency)"
                    )
                    settingCard(title: "Second market", value: "Germany · EUR · same 10 books")
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Appraisal")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ash)
                        Text("$\(Int(model.settings.appraisalThreshold))")
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(Theme.cloud)
                        Slider(value: binding(\.appraisalThreshold), in: 25...500, step: 5)
                            .tint(Theme.cyan)
                        Text("A price at or above this goes to a person.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Scale disagreement")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ash)
                        Text("\(Int(model.settings.disagreementThreshold * 100))%")
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(Theme.cloud)
                        Slider(value: binding(\.disagreementThreshold), in: 0.03...0.25, step: 0.01)
                            .tint(Theme.cyan)
                        Text("Above this, the card still wins and both numbers stay on the packet.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                }
                .padding(20)
            }
            .sweepScreen()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }

    private func settingCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ash)
            Text(value)
                .font(Theme.sans(18, weight: .light))
                .foregroundStyle(Theme.cloud)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func binding(_ keyPath: WritableKeyPath<WalkSettings, Double>) -> Binding<Double> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in
                var settings = model.settings
                settings[keyPath: keyPath] = newValue
                model.updateSettings(settings)
            }
        )
    }
}
