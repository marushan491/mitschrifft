import AVFoundation
import CoreMedia
import Foundation

struct SessionResult: Sendable {
    let startedAt: Date
    let endedAt: Date
    let segments: [Segment]

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

actor RecordingSession {
    private let locale: Locale
    private var mic: TrackTranscriber?
    private var system: TrackTranscriber?
    private var tap: AudioTap?
    private var origin: CMTime?
    private var startedAt = Date()
    private var micFrames = 0
    private var systemFrames = 0
    private var feeder: AsyncStream<TappedBuffer>.Continuation?
    private var pump: Task<Void, Never>?
    private var seenFormats: Set<String> = []
    private var micRate = 48_000.0
    private var systemRate = 48_000.0
    private var streamStopped = false
    private let speakers = SpeakerTracker()
    private var audioUptime: TimeInterval?
    private var captionTask: Task<Void, Never>?
    private var captionSink: SegmentSink?
    private var teamsCaptionsEnabled = false
    private var attribution = SpeakerAttribution()
    private var windowSpeakerAttribution = WindowSpeakerAttribution()
    private var speakerWindowApp: MeetingSpeakerApp?
    private var speakerWindowTitle: String?
    private var review = SpeakerReview()
    private var voiceTask: Task<Void, Never>?
    private var participantNames: Set<String> = []
    private var glossaryWords: [String] = []
    private var finalSegments: [Segment]?
    private var reviewSink: SegmentSink?

    init(locale: Locale) {
        self.locale = locale
    }

    func start(sink: SegmentSink? = nil) async throws {
        startedAt = Date()
        reviewSink = sink
        mic = try await TrackTranscriber(track: .mic, locale: locale)
        system = try await TrackTranscriber(track: .system, locale: locale)
        Task { [speakers] in await speakers.start() }

        let (queued, continuation) = AsyncStream<TappedBuffer>.makeStream(bufferingPolicy: .unbounded)
        feeder = continuation
        pump = Task { [weak self] in
            for await tapped in queued {
                await self?.handle(tapped)
            }
        }

        let tap = AudioTap(
            sink: { [continuation] tapped in
                continuation.yield(tapped)
            },
            onStop: { error in
                log("Audio-Stream gestoppt: \(error.localizedDescription)")
                Task { await self.markStreamStopped() }
            }
        )
        self.tap = tap
        try await tap.start()
        voiceTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(25)) }
                catch { return }
                await self?.refreshVoiceMatches()
            }
        }
    }

    private func handle(_ tapped: TappedBuffer) async {
        if origin == nil {
            origin = tapped.hostTime
            audioUptime = ProcessInfo.processInfo.systemUptime
        }
        let base = origin ?? tapped.hostTime
        let relative = CMTimeSubtract(tapped.hostTime, base)
        let offset = relative.isValid && relative.seconds >= 0 ? relative : CMTime.zero

        let shape = "\(tapped.track.rawValue) \(Int(tapped.buffer.format.sampleRate))Hz \(tapped.buffer.format.channelCount)ch"
        if seenFormats.insert(shape).inserted {
            log("Tonspur da: \(shape), \(tapped.buffer.frameLength) Rahmen pro Paket")
            if tapped.track == .mic { micRate = tapped.buffer.format.sampleRate }
            else { systemRate = tapped.buffer.format.sampleRate }
        }

        switch tapped.track {
        case .mic:
            micFrames += Int(tapped.buffer.frameLength)
            await mic?.feed(tapped.buffer, at: offset)
        case .system:
            systemFrames += Int(tapped.buffer.frameLength)
            await system?.feed(tapped.buffer, at: offset)
            await speakers.feed(tapped.buffer, at: offset.seconds)
        }
    }

    func resultCount() async -> Int {
        let a = await mic?.report().results ?? 0
        let b = await system?.report().results ?? 0
        return a + b
    }

    func frameCounts() -> (mic: Int, system: Int) {
        (micFrames, systemFrames)
    }

    private func markStreamStopped() { streamStopped = true }

    func setMeetingSpeakerSource(apps: [String], locale: String, title: String?, sink: SegmentSink) {
        let supported = Set(apps.compactMap(MeetingSpeakerApp.init(appName:)))
        let app = supported.count == 1 ? supported.first : nil
        guard app != speakerWindowApp || title != speakerWindowTitle else { return }
        captionTask?.cancel()
        captionTask = nil
        speakerWindowApp = app
        speakerWindowTitle = title
        guard let app else { return }
        if app == .teams {
            teamsCaptionsEnabled = true
            captionSink = sink
        }
        let reader = MeetingSpeakerReader(app: app)
        captionTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled, let self {
                let sample = await reader.read(locale: locale, meetingTitle: title)
                guard !Task.isCancelled else { return }
                await self.observeMeetingSpeaker(sample, sink: sink)
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
    }

    private func observeMeetingSpeaker(_ sample: MeetingSpeakerSample?, sink: SegmentSink) async {
        guard let audioUptime, let system else { return }
        let now = ProcessInfo.processInfo.systemUptime - audioUptime
        let segments = await system.currentSegments()
        let spans = await speakers.current()
        guard !Task.isCancelled else { return }
        let captions = sample?.captions
        attribution.observe(captions, at: now)
        attribution.match(segments, at: now, sink: sink)
        windowSpeakerAttribution.observe(sample?.activeNames ?? [],
                                         at: (sample?.observedUptime ?? audioUptime + now) - audioUptime)
        let recent = segments.filter { $0.end >= now - 45 }
        windowSpeakerAttribution.match(Speakers.label(recent, spans: spans), spans: spans)
        let names = (captions ?? []).map(\.name) + Array(sample?.activeNames ?? [])
        if !names.isEmpty { await addParticipants(names) }
    }

    func addParticipants(_ names: [String]) async {
        let previous = participantNames
        participantNames.formUnion(names)
        if participantNames != previous { await refreshSpeechContext() }
    }

    func setGlossary(_ terms: [String]) async {
        guard glossaryWords != terms else { return }
        glossaryWords = terms
        await refreshSpeechContext()
    }

    private func refreshSpeechContext() async {
        let terms = Array(participantNames.sorted().prefix(50)) + glossaryWords
        if let mic { try? await mic.setContextualStrings(terms) }
        if let system { try? await system.setContextualStrings(terms) }
    }

    func refreshVoiceMatches() async {
        let samples = await speakers.voiceReferences()
        guard !Task.isCancelled else { return }
        let names = participantNames
        let matches = await Task.detached(priority: .utility) {
            samples.compactMapValues { try? SpeakerProfiles.match($0, participants: names) }
        }.value
        guard !Task.isCancelled else { return }
        review.sampleCounts = samples.mapValues(\.count)
        review.profileMatches = matches
    }

    private func speakerSegments() async -> [Segment] {
        if let finalSegments { return finalSegments }
        let segments = (await mic?.currentSegments() ?? []) + (await system?.currentSegments() ?? [])
        let labelled = Speakers.label(segments.sorted { $0.start < $1.start }, spans: await speakers.current())
        return windowSpeakerAttribution.apply(to: teamsCaptionsEnabled ? attribution.apply(to: labelled) : labelled)
    }

    func speakerRows() async -> [SpeakerReviewRow] {
        review.rows(for: await speakerSegments())
    }

    func confirmSpeaker(_ raw: Int, as input: String) async -> SpeakerReviewResponse {
        guard raw != -1, let name = SpeakerIdentity.validName(input),
              let row = await speakerRows().first(where: { $0.id == raw }),
              finalSegments == nil || row.sampleCount >= 5 else {
            return SpeakerReviewResponse(message: "Der Sprecher oder Name ist nicht verfügbar.")
        }
        review.manual[raw] = name
        reviewSink?.appendSpeakerReview(speaker: raw, name: name)
        return .done
    }

    func mergeSpeaker(_ raw: Int, into target: Int) async -> SpeakerReviewResponse {
        let rows = await speakerRows()
        guard finalSegments == nil, raw != target, raw >= 0, target >= 0,
              let source = rows.first(where: { $0.id == raw }),
              let destination = rows.first(where: { $0.id == target }) else {
            return SpeakerReviewResponse(message: "Die Sprecher sind nicht mehr verfügbar.")
        }
        let names = Set([source.identity, destination.identity].compactMap {
            $0?.confirmed == true ? $0?.name : nil
        })
        guard !source.conflictingCaptions, !destination.conflictingCaptions, names.count < 2 else {
            return SpeakerReviewResponse(message: "Bestätige zuerst die richtige Person für beide Stimmen.")
        }
        review.aliases[raw] = target
        review.manual[target] = review.manual[target] ?? review.manual[raw]
        review.manual[raw] = nil
        reviewSink?.appendSpeakerMerge(speaker: raw, into: target)
        return .done
    }

    func rememberSpeaker(_ raw: Int, as name: String, consentedAt: Date) async throws {
        let references = await speakers.voiceReferences()
        guard let row = await speakerRows().first(where: { $0.id == raw }), row.identity?.name == name,
              row.identity?.source == .manual, let samples = references[raw], samples.count >= 5 else {
            throw CodexError.failed("Name oder fünf geeignete Stimmabschnitte fehlen.")
        }
        try await Task.detached(priority: .utility) {
            try SpeakerProfiles.remember(name: name, consentedAt: consentedAt, samples: samples)
        }.value
        await refreshVoiceMatches()
    }

    func speakerEvidence() async -> [Int: String] {
        var evidence: [Int: String] = [:]
        for segment in await speakerSegments() where !segment.overlappingSpeakers {
            guard let raw = segment.rawSpeaker, segment.speakerName == nil else { continue }
            let group = review.representative(raw)
            if review.manual[group] == nil, evidence[group, default: ""].count < 1600 {
                evidence[group, default: ""] += String(segment.text.prefix(350)) + "\n"
            }
        }
        return evidence
    }

    func acceptSuggestions(_ suggestions: [Int: SpeakerIdentity]) {
        guard finalSegments == nil else { return }
        review.suggestions = suggestions
    }

    func assistantSnapshot() async -> AssistantSnapshot {
        let labelled = await speakerSegments()
        let named = review.apply(to: labelled)
        return AssistantSnapshot(segments: Echo.removeMicEcho(named),
                                 elapsed: Date().timeIntervalSince(startedAt),
                                 recording: true, startedAt: startedAt, showsSpeakerIdentity: true,
                                 speakerReview: review.rows(for: labelled))
    }

    func healthLine() async -> String {
        let micReport = await mic?.report() ?? (fed: 0, dropped: 0, results: 0, alive: false)
        let sysReport = await system?.report() ?? (fed: 0, dropped: 0, results: 0, alive: false)
        return "Mikro \(Int(Double(micFrames) / micRate))s/\(micReport.results) Ergebnisse\(micReport.alive ? "" : ", SPUR TOT")"
            + ", System \(Int(Double(systemFrames) / systemRate))s/\(sysReport.results) Ergebnisse\(sysReport.alive ? "" : ", SPUR TOT")"
            + (micReport.dropped + sysReport.dropped > 0
               ? ", verworfen \(micReport.dropped + sysReport.dropped)" : "")
    }

    func finish(timeout: Int) async -> SessionResult {
        captionTask?.cancel()
        captionTask = nil
        voiceTask?.cancel()
        voiceTask = nil
        await tap?.stop()
        tap = nil

        feeder?.finish()
        feeder = nil
        await pump?.value
        pump = nil

        var segments: [Segment] = []
        if let mic { segments += await mic.finish(timeout: timeout) }
        if let system { segments += await system.finish(timeout: timeout) }
        self.mic = nil
        self.system = nil

        log("Aufnahme abgeschlossen: Mikro \(Int(Double(micFrames) / micRate))s, System \(Int(Double(systemFrames) / systemRate))s, \(segments.count) Textstuecke.")

        segments.sort { $0.start < $1.start }
        let spans = await speakers.finish()
        segments = Speakers.label(segments, spans: spans)
        if teamsCaptionsEnabled {
            if let audioUptime {
                attribution.match(segments, at: ProcessInfo.processInfo.systemUptime - audioUptime, sink: captionSink)
            }
            segments = attribution.apply(to: segments)
        }
        windowSpeakerAttribution.match(segments, spans: spans)
        segments = windowSpeakerAttribution.apply(to: segments)
        captionSink = nil
        reviewSink = nil
        finalSegments = segments
        return SessionResult(startedAt: startedAt, endedAt: Date(), segments: review.apply(to: segments))
    }
}
