import SwiftUI

@MainActor
struct SpeakerReviewView: View {
    private struct Prompt: Identifiable {
        enum Operation {
            case rename(recording: String, row: SpeakerReviewRow)
            case consent(recording: String, row: SpeakerReviewRow, name: String)
            case delete(SpeakerProfile)
            case suggest(recording: String)
        }

        let id = UUID()
        let operation: Operation
    }

    @ObservedObject var state: MeetingTrailState
    @State private var expanded = false
    @State private var profiles: [SpeakerProfile]?
    @State private var prompt: Prompt?
    @State private var nameDraft = ""
    @State private var consent = false
    @State private var busy = false
    @State private var status: String?

    var body: some View {
        DisclosureGroup("Sprecher", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if state.speakers.isEmpty {
                    Text(state.canEditSpeakers ? "Warte auf erkannte Stimmen." : "Kein Gespräch zur Prüfung.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(state.speakers) { row in
                    speaker(row)
                }
                if let id = state.speakerRecording, state.canEditSpeakers,
                   state.speakers.contains(where: { $0.id >= 0 && $0.identity?.confirmed != true }) {
                    Button("Namen aus dem Gespräch vorschlagen …") {
                        prompt = Prompt(operation: .suggest(recording: id))
                    }
                    .disabled(busy)
                }
                if let profiles {
                    Divider()
                    if profiles.isEmpty {
                        Text("Keine Stimmen gespeichert.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(profiles) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                Text("Einwilligung am \(profile.consentedAt.formatted(date: .numeric, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                prompt = Prompt(operation: .delete(profile))
                            } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("Stimmprofil von \(profile.name) löschen")
                            .disabled(busy)
                        }
                    }
                } else {
                    Button("Gespeicherte Stimmen anzeigen") { send(.profiles) }.disabled(busy)
                }
                if busy {
                    ProgressView().controlSize(.small).accessibilityLabel("Sprecheraktion läuft")
                }
                if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 8)
        }
        .sheet(item: $prompt) { value in
            sheet(value)
        }
    }

    private func speaker(_ row: SpeakerReviewRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).font(.callout.weight(.semibold))
                if let identity = row.identity {
                    if identity.name != row.title { Text(identity.name) }
                    HStack(spacing: 5) {
                        Text(identity.confirmed ? "Bestätigt" : "Vermutet")
                        if let score = identity.similarity {
                            Text("Auto \(score, format: .number.precision(.fractionLength(2)))")
                        } else if identity.source == .window {
                            Text("Meeting-Fenster")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if let quote = identity.quote {
                        Text("„\(quote)“").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } else {
                    Text(row.conflictingCaptions ? "? Widersprüchliche Untertitel" : "? Unbekannt")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if let id = state.speakerRecording { actions(row, recording: id) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func actions(_ row: SpeakerReviewRow, recording: String) -> some View {
        if state.canEditSpeakers, let identity = row.identity, !identity.confirmed {
            Button("Bestätigen") { send(.confirm(recording: recording, speaker: row.id, name: identity.name)) }
                .disabled(busy)
        }
        if row.id >= 0 && (state.canEditSpeakers || row.sampleCount >= 5) ||
            row.identity?.source == .manual && row.sampleCount >= 5 {
            Menu {
                if row.id >= 0 {
                    Button(state.canEditSpeakers ? "Namen bearbeiten …" : "Name fürs Stimmprofil …") {
                        nameDraft = row.identity?.name ?? ""
                        prompt = Prompt(operation: .rename(recording: recording, row: row))
                    }
                    let other = state.speakers.filter { $0.id >= 0 && $0.id != row.id }
                    if state.canEditSpeakers && !other.isEmpty {
                        Menu("Zusammenführen mit") {
                            ForEach(other) { target in
                                Button(target.title) { send(.merge(recording: recording, speaker: row.id, into: target.id)) }
                            }
                        }
                    }
                }
                if let identity = row.identity, identity.source == .manual {
                    Button("Stimme merken …") {
                        consent = false
                        prompt = Prompt(operation: .consent(recording: recording, row: row, name: identity.name))
                    }
                    .disabled(row.sampleCount < 5)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Aktionen für \(row.title)")
            .disabled(busy)
        }
    }

    private func sheet(_ value: Prompt) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            switch value.operation {
            case .rename(let recording, let row):
                Text("Name für \(row.title)").font(.headline)
                if !state.canEditSpeakers {
                    Text("Die gespeicherte Mitschrift bleibt erhalten. Dieser Name gilt für die Profilauswahl.")
                        .foregroundStyle(.secondary)
                }
                TextField("Name", text: $nameDraft)
                sheetButtons("Name bestätigen", enabled: SpeakerIdentity.validName(nameDraft) != nil) {
                    send(.confirm(recording: recording, speaker: row.id, name: nameDraft))
                }
            case .consent(let recording, let row, let name):
                Text("Stimme von \(name) merken?").font(.headline)
                Text("Mitschrift speichert verschlüsselte Stimmmerkmale auf diesem Mac. Das Profil kann jederzeit gelöscht werden.")
                Toggle("Die Person hat ausdrücklich zugestimmt", isOn: $consent)
                sheetButtons("Stimme merken", enabled: consent) {
                    guard consent else { return }
                    send(.remember(recording: recording, speaker: row.id, name: name, consent: Date()))
                }
            case .delete(let profile):
                Text("Stimmprofil von \(profile.name) löschen?").font(.headline)
                sheetButtons("Profil löschen", role: .destructive) { send(.delete(profile.id)) }
            case .suggest(let recording):
                Text("Sprechernamen vorschlagen lassen?").font(.headline)
                Text("Dafür werden Ausschnitte der laufenden Mitschrift an die konfigurierte Codex-Auswertung gesendet.")
                sheetButtons("Vorschläge suchen") { send(.suggest(recording: recording)) }
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func sheetButtons(_ title: String, enabled: Bool = true, role: ButtonRole? = nil,
                              action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button("Abbrechen", role: .cancel) { prompt = nil }
                .keyboardShortcut(.cancelAction)
            Button(title, role: role) {
                prompt = nil
                action()
            }
            .disabled(!enabled)
        }
    }

    private func send(_ action: SpeakerReviewAction) {
        guard !busy, let review = state.reviewSpeaker else { return }
        busy = true
        status = nil
        Task {
            let response = await review(action)
            if let list = response.profiles { profiles = list }
            status = response.message
            if case .remember = action, profiles != nil { profiles = await review(.profiles).profiles ?? profiles }
            busy = false
        }
    }
}
