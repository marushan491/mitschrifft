import AppKit
import SwiftUI

struct MeetingTrailNote: Codable, Equatable {
    struct Topic: Codable, Equatable, Identifiable {
        let id: String
        let seconds: Int
        let title: String
        let points: [String]
        let suggestion: String?
        let reason: String?
    }

    let version: Int
    let meetingID: String
    let goal: String?
    let project: String?
    let hasProjectContext: Bool
    let topics: [Topic]
    var hint: String?
    var hintID: String?
    var terms: [String]?
    var basis: [String]?
    var decisions: [String]?
    var openPoints: [String]?
    var tasks: [String]?
    var ended: Bool?
    var recapSaved: Bool?
    var contextLabel: String?
    var workspaceID: String?
    var meetingTitle: String?
    var glossaryTerms: [String]?

    static func read(from file: URL) throws -> Self {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let limit = 256 * 1024
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw CocoaError(.fileReadCorruptFile) }
        let note = try JSONDecoder().decode(Self.self, from: data)
        guard note.version == 1, !note.meetingID.isEmpty,
              note.topics.allSatisfy({ !$0.id.isEmpty && $0.seconds >= 0 && !$0.title.isEmpty }),
              Set(note.topics.map(\.id)).count == note.topics.count,
              zip(note.topics, note.topics.dropFirst()).allSatisfy({ $0.0.seconds <= $0.1.seconds }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return note
    }
}

@MainActor
final class MeetingTrailState: ObservableObject {
    struct SubmittedQuestion {
        let text: String
        let reference: String?
    }

    @Published private(set) var note: MeetingTrailNote?
    @Published private(set) var waiting = true
    @Published private(set) var selectedID: String?
    @Published private(set) var expanded = true
    @Published private(set) var hasNewTopic = false
    @Published private(set) var hint: String?
    @Published var status: String?
    @Published var recentSpeaker: String?
#if !MEETING_TRAIL_PREVIEW
    @Published var speakers: [SpeakerReviewRow] = []
    @Published var speakerRecording: String?
    @Published var canEditSpeakers = false
#endif
    @Published var answer: String?
    @Published var answerFailed = false
    @Published private(set) var submittedQuestion: SubmittedQuestion?
    @Published var asking = false
    @Published var canAsk = false
    @Published var requestBusy = false
    @Published var projects: [String] = []
    @Published var project = ""
    @Published var armed = true
    @Published var questionDraft = ""
    @Published var questionReference: String?
    @Published var translucent = UserDefaults.standard.bool(forKey: "meetingTrail.translucent")
    @Published private(set) var draftRevision = 0
    private var expectedID: String?

    var arm: (() -> Void)?
    var ask: ((String) -> Void)?
#if !MEETING_TRAIL_PREVIEW
    var reviewSpeaker: ((SpeakerReviewAction) async -> SpeakerReviewResponse)?
#endif

    let file: URL

    var latest: MeetingTrailNote.Topic? { note?.topics.last }
    var selected: MeetingTrailNote.Topic? {
        note?.topics.first { $0.id == selectedID } ?? latest
    }

    init(file: URL) {
        self.file = file
        refresh()
    }

    func refresh() {
        guard let incoming = try? MeetingTrailNote.read(from: file) else {
            if !waiting { waiting = true }
            return
        }
        guard expectedID == nil || expectedID == incoming.meetingID else { return }
        if waiting { waiting = false }
        guard incoming != note else { return }
        if incoming.meetingID != note?.meetingID || !incoming.topics.contains(where: { $0.id == selectedID }) {
            selectedID = nil
        }
        if let previous = note?.meetingID, previous != incoming.meetingID {
            questionDraft = ""
            questionReference = nil
        }
        if incoming.meetingID != note?.meetingID || incoming.topics.last?.id != latest?.id {
            hasNewTopic = !expanded || selectedID != nil
        }
        if incoming.meetingID != note?.meetingID || incoming.hintID != note?.hintID {
            hint = incoming.hint
        }
        if incoming.ended == true {
            hint = nil
            hasNewTopic = false
        }
        note = incoming
    }

    func select(_ topic: MeetingTrailNote.Topic) {
        selectedID = topic.id == latest?.id ? nil : topic.id
        if selectedID == nil { hasNewTopic = false }
    }

    func toggle() {
        expanded.toggle()
        if expanded && selectedID == nil { hasNewTopic = false }
        if !expanded { hint = nil }
    }

    func prepareQuestion(about point: String) {
        guard canAsk else { return }
        questionReference = String(point.prefix(220))
        questionDraft = "Was bedeutet das für uns?"
        draftRevision += 1
    }

    func submitQuestion() {
        let question = questionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAsk, !question.isEmpty, !asking, !requestBusy, let ask else { return }
        let limit = questionReference == nil ? 500 : 250
        let sent = SubmittedQuestion(text: String(question.prefix(limit)), reference: questionReference)
        submittedQuestion = sent
        if let reference = questionReference {
            ask("Bezug: \(reference)\nFrage: \(sent.text)")
        } else {
            ask(sent.text)
        }
        questionDraft = ""
        questionReference = nil
    }

    func dismissAnswer() {
        answer = nil
        submittedQuestion = nil
        answerFailed = false
    }

    func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func discard(_ id: String) {
        guard note?.meetingID == id else { return }
        try? FileManager.default.removeItem(at: file)
        note = nil
        waiting = true
        selectedID = nil
        hint = nil
        hasNewTopic = false
        questionDraft = ""
        questionReference = nil
        dismissAnswer()
    }

    func expect(_ id: String) {
        expectedID = id
        guard note?.meetingID != id else { return }
        note = nil
        waiting = true
        selectedID = nil
        hint = nil
        hasNewTopic = false
        questionDraft = ""
        questionReference = nil
        dismissAnswer()
    }
}

@MainActor
struct MeetingTrailView: View {
    private enum ScrollAnchor { case start, answer }
    private struct ScrollEdges: Equatable {
        let above: Bool
        let below: Bool
    }
    @ObservedObject var state: MeetingTrailState
    var toggle: (() -> Void)? = nil
    var resize: (() -> Void)? = nil
    @FocusState private var composerFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var edges = ScrollEdges(above: false, below: false)

    private let tint = Color(nsColor: .controlAccentColor)
    private let supportingText = Color(nsColor: .labelColor).opacity(0.78)

    var body: some View {
        VStack(spacing: 0) {
            if let toggle {
                Button(action: toggle) {
                    topicBar
                }
                .buttonStyle(.plain)
                .accessibilityHint(state.expanded ? "Gesprächsspur einklappen" : "Gesprächsspur aufklappen")
                .accessibilityValue(state.hint ?? (state.hasNewTopic ? "Neues Thema" : ""))
                if state.expanded { Divider() }
            } else if state.latest != nil, state.selectedID != nil || state.hasNewTopic {
                topicBar
                Divider()
            }

            if toggle == nil || state.expanded {
                transcript.padding(.bottom, state.canAsk || state.asking ? 8 : 0)
                if state.note?.ended != true && (state.canAsk || state.asking) {
                    VStack(spacing: 0) {
                        Divider()
                        questionBox.padding(12)
                    }
                    .background(Color(nsColor: .windowBackgroundColor))
                }
                if !state.armed, state.note?.ended == true, let arm = state.arm {
                    Divider()
                    setupForm(arm).padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            if state.translucent && !reduceTransparency {
                if toggle != nil { Rectangle().fill(.regularMaterial) }
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .onChange(of: state.draftRevision) { _, _ in composerFocused = true }
        .onChange(of: state.note?.topics.isEmpty) { _, _ in resize?() }
        .onChange(of: state.note?.ended) { _, _ in resize?() }
        .task {
            while !Task.isCancelled {
                state.refresh()
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }

    private var topicBar: some View {
        HStack(spacing: 9) {
            if state.hasNewTopic || state.hint != nil {
                Circle().fill(tint).frame(width: 7, height: 7).accessibilityHidden(true)
            }
            if state.note?.ended == true {
                Text("Abschluss").fontWeight(.semibold)
            } else if toggle == nil || !state.expanded || state.selected?.id != state.latest?.id {
                Text("Gerade:").fontWeight(.semibold)
                Text(state.latest?.title ?? "Warte auf den Termin").lineLimit(1)
            } else {
                Text("Mitschrift").fontWeight(.semibold)
            }
            Spacer(minLength: 4)
            if toggle != nil {
                Image(systemName: state.expanded ? "chevron.up" : "chevron.down")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 15)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .background(tint.opacity(state.hint == nil ? 0.10 : 0.24))
    }

    private var transcript: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    transcriptContents.id(ScrollAnchor.start)
                    if let answer = state.answer, state.note?.ended != true {
                        answerCard(answer).padding(.top, 10).id(ScrollAnchor.answer)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(15)
                .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)
            .clipped()
            .onScrollGeometryChange(for: ScrollEdges.self) { geometry in
                ScrollEdges(above: geometry.visibleRect.minY > 1,
                            below: geometry.visibleRect.maxY + 1 < geometry.contentSize.height)
            } action: { _, value in
                edges = value
            }
            .mask {
                VStack(spacing: 0) {
                    if edges.above {
                        Color.clear.frame(height: 5)
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: 14)
                    }
                    Rectangle()
                    if edges.below {
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 18)
                        Color.clear.frame(height: 6)
                    }
                }
            }
            .onChange(of: state.answer) { old, new in
                if new != nil {
                    scroll.scrollTo(ScrollAnchor.answer, anchor: .top)
                } else if old != nil {
                    scroll.scrollTo(ScrollAnchor.start, anchor: .top)
                }
            }
        }
    }

    private var transcriptContents: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let status = state.status {
                Text(status).font(.callout).foregroundStyle(supportingText)
            }
            if let hint = state.hint {
                Label(hint, systemImage: "circle.fill").font(.callout.weight(.semibold))
            }
            if state.selectedID == nil, state.note?.ended != true, let speaker = state.recentSpeaker {
                Label(speaker, systemImage: "person.wave.2")
                    .font(.callout).foregroundStyle(supportingText)
                    .accessibilityLabel("Zuletzt gesprochen: " + speaker)
            }
            if let note = state.note {
                overview(note)
                if note.ended != true {
                    if !note.topics.isEmpty {
                        timeline(note.topics)
                    }
                    if let selected = state.selected {
                        details(selected)
                    } else {
                        Text("Noch kein Thema").foregroundStyle(supportingText)
                    }
                }
                context(note)
            } else if state.armed && state.status == nil {
                Text("Sobald die erste Notiz da ist, erscheint hier der Gesprächsverlauf.")
                    .foregroundStyle(supportingText)
            }
#if !MEETING_TRAIL_PREVIEW
            if state.reviewSpeaker != nil {
                SpeakerReviewView(state: state)
            }
#endif
            if !state.armed, state.note?.ended != true, let arm = state.arm {
                setupForm(arm)
            }
        }
    }

    private func answerCard(_ answer: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(state.answerFailed ? "Antwort fehlgeschlagen" : "Sol")
                    .font(.headline)
                Spacer(minLength: 0)
                Button { state.copy(answer) } label: {
                    Image(systemName: "doc.on.doc").frame(width: 26, height: 26)
                }
                .accessibilityLabel("Antwort kopieren")
                .help("Antwort kopieren")
                Button(action: state.dismissAnswer) {
                    Image(systemName: "xmark").frame(width: 26, height: 26)
                }
                .accessibilityLabel("Antwort schließen")
                .help("Antwort schließen")
            }
            .buttonStyle(.plain)
            if let question = state.submittedQuestion {
                VStack(alignment: .leading, spacing: 4) {
                    Text(question.text).font(.callout.weight(.semibold))
                    if let reference = question.reference {
                        Text(reference).font(.callout)
                    }
                }
                .foregroundStyle(supportingText)
                Divider()
            }
            Text(answer)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private func setupForm(_ arm: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Projekt", selection: $state.project) {
                Text("Ohne Projektwissen").tag("")
                ForEach(state.projects, id: \.self) { Text($0).tag($0) }
            }
            Text("Mitschrift und Projektwissen gehen an Luna über Codex Business. Bei Projektwahl wird der Abschluss dort gespeichert.")
                .font(.caption).foregroundStyle(supportingText)
            Button("Gesprächsspur aktivieren", action: arm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var questionBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.canAsk || state.asking {
                if let reference = state.questionReference {
                    HStack(alignment: .top, spacing: 6) {
                        Text("Bezug").fontWeight(.semibold)
                        Text(reference).lineLimit(2).textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button {
                            state.questionReference = nil
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Bezug entfernen")
                    }
                    .font(.callout)
                    .foregroundStyle(supportingText)
                }
                HStack {
                    TextField("Frage zum Gespräch", text: $state.questionDraft)
                        .focused($composerFocused)
                        .onSubmit(state.submitQuestion)
                    Button(action: state.submitQuestion) {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                    .accessibilityLabel("Frage senden")
                    .disabled(state.asking || state.requestBusy ||
                              state.questionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if state.asking {
                Text("Sol antwortet …").font(.callout).foregroundStyle(supportingText)
            }
        }
    }

    @ViewBuilder
    private func context(_ note: MeetingTrailNote) -> some View {
        if note.ended == true {
            Text(note.recapSaved == true ? "In der Projektnotiz gespeichert" : "Abschluss in dieser Gesprächsspur")
                .font(.callout).foregroundStyle(supportingText)
        }
        contextSection("Begriffe", note.terms)
        contextSection("Entschieden", note.decisions?.filter { !(note.tasks ?? []).contains($0) }, expanded: note.ended == true)
        contextSection("Unklar", note.openPoints, expanded: note.ended == true)
        contextSection("Aufgaben", note.tasks, expanded: note.ended == true)
        contextSection("Worauf ihr aufbaut", note.basis)
    }

    @ViewBuilder
    private func contextSection(_ title: String, _ items: [String]?, expanded: Bool = false) -> some View {
        if let items, !items.isEmpty {
            TrailDetails(title: title, items: items, state: state, expanded: expanded).id(expanded)
        }
    }

    private func overview(_ note: MeetingTrailNote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = note.meetingTitle {
                Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
            }
            if let goal = note.goal {
                Text("Ziel").font(.caption).fontWeight(.semibold).foregroundStyle(supportingText)
                Text(goal).font(.headline).fixedSize(horizontal: false, vertical: true)
            }
            if state.waiting {
                Label("Notiz fehlt. Letzter Stand bleibt sichtbar.", systemImage: "exclamationmark.circle")
                    .font(.callout)
            }
            if !note.hasProjectContext {
                Label("Ohne Projektwissen", systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(supportingText)
            } else if let label = note.contextLabel ?? note.project {
                Text(label).font(.callout).foregroundStyle(supportingText)
            }
        }
    }

    private func timeline(_ topics: [MeetingTrailNote.Topic]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(topics) { topic in
                let current = topic.id == state.latest?.id
                let selected = topic.id == state.selected?.id
                Button {
                    state.select(topic)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(selected ? tint : Color(nsColor: .separatorColor))
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(String(format: "%02d:%02d", topic.seconds / 60, topic.seconds % 60))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(supportingText)
                        Text(topic.title).fontWeight(selected ? .semibold : .regular)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if current {
                            Text("Jetzt").font(.caption.weight(.semibold)).foregroundStyle(supportingText)
                        }
                    }
                    .padding(.horizontal, 9)
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
                    .background(selected ? tint.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
    }

    private func details(_ topic: MeetingTrailNote.Topic) -> some View {
        let current = topic.id == state.latest?.id
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(current ? "Im Gespräch" : "Rückblick")
                .font(.caption.weight(.semibold)).foregroundStyle(supportingText)
            ForEach(Array(topic.points.enumerated()), id: \.offset) { _, point in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").accessibilityHidden(true)
                    TrailPoint(text: point, state: state)
                }
            }
            if current, let suggestion = topic.suggestion {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Was du sagen kannst").font(.caption.weight(.semibold))
                    TrailPoint(text: suggestion, state: state).fontWeight(.semibold)
                    if let reason = topic.reason {
                        Text(reason).font(.callout).foregroundStyle(supportingText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}

private struct TrailDetails: View {
    let title: String
    let items: [String]
    @ObservedObject var state: MeetingTrailState
    @State var expanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("•").accessibilityHidden(true)
                        TrailPoint(text: item, state: state)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 5)
        } label: {
            Text(title).font(.callout.weight(.medium))
        }
    }
}

private struct TrailPoint: View {
    let text: String
    @ObservedObject var state: MeetingTrailState

    var body: some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .contextMenu {
                Button("Kopieren") { state.copy(text) }
                if state.canAsk {
                    Button("Dazu fragen") { state.prepareQuestion(about: text) }
                }
            }
    }
}
