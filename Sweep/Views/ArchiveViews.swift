import SwiftUI

struct WalksView: View {
    @EnvironmentObject private var model: AppModel
    @State private var practice: SweepSession?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PageTitle(
                        title: "Walks",
                        subtitle: "Each finished walk keeps its packet. A later confirmation writes the next version."
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
                        EmptyNote(text: "No walks yet. Start one from Home, or practice the rules.")
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
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { model.reload() }
            .fullScreenCover(item: $practice, onDismiss: { model.reload() }) { live in
                WalkView(session: live)
            }
        }
    }
}

struct ReviewView: View {
    @EnvironmentObject private var model: AppModel
    @State private var busyID = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PageTitle(
                        title: "Review",
                        subtitle: "Hunches, missing prices, art, and scale disagreements. Nothing here is in the money."
                    )
                    let entries = model.reviewEntries()
                    if entries.isEmpty {
                        EmptyNote(text: "The queue is empty.")
                    }
                    ForEach(entries) { entry in
                        HStack(alignment: .center, spacing: 8) {
                            NavigationLink {
                                SessionDetailView(sessionID: entry.sessionID)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(entry.isHunch ? entry.hunchTitle : entry.refID.uppercased())
                                        .font(entry.isHunch ? Theme.sans(16, weight: .light) : Theme.mono(11))
                                        .tracking(entry.isHunch ? 0 : 1)
                                        .foregroundStyle(entry.isHunch ? Theme.cloud : Theme.ash)
                                    Text(entry.reason)
                                        .font(Theme.sans(16, weight: .light))
                                        .foregroundStyle(Theme.cloud)
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
                .padding(20)
            }
            .sweepScreen()
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { model.reload() }
        }
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

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

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
                        Text("APPRAISAL")
                            .font(Theme.mono(11))
                            .tracking(1.4)
                            .foregroundStyle(Theme.ash)
                        Text("$\(Int(model.settings.appraisalThreshold))")
                            .font(Theme.display(40))
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
                        Text("SCALE DISAGREEMENT")
                            .font(Theme.mono(11))
                            .tracking(1.4)
                            .foregroundStyle(Theme.ash)
                        Text("\(Int(model.settings.disagreementThreshold * 100))%")
                            .font(Theme.display(40))
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
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func settingCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(Theme.mono(11))
                .tracking(1.4)
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
