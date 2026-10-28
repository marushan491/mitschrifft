import XCTest
@testable import mitschrift

final class MeetingTests: XCTestCase {
    func mic(_ start: Double, _ end: Double, _ text: String) -> Segment {
        Segment(track: .mic, start: start, end: end, text: text)
    }

    func system(_ start: Double, _ end: Double, _ text: String) -> Segment {
        Segment(track: .system, start: start, end: end, text: text)
    }

    func testMicEchoFromLoudspeakerIsRemovedDespiteRecognitionDrift() {
        let segments = [
            mic(44.8, 55.9, "oder die wir konkretisieren müssen, dann, wie machen wir das? Und es können Kleinigkeiten sein, es können aber auch bugfixes sein aus dem Juraticket oder ganzes Architekturkonzept sein, egal wie groß das Ding ist."),
            system(33.2, 47.9, "Vielleicht zeigen wir jetzt mal diese Zivilisation. Nehmen wir als Hypothese, dass wir sagen, wenn wir solche kleinen Funktionen dazu packen wollen, die heute anders implementiert sind oder die wir konkretisieren müssen, dann, wie machen wir das"),
            system(47.9, 56.5, "? Und es können Kleinigkeiten sein, es können aber auch backfixes sein aus dem Juraticket oder ganzes Architeurkonzept eigentlich egal, wie groß das Ding ist."),
            mic(58.2, 62.2, "Ja, okay, also"),
            system(58.2, 62.7, "Genau. Okay, also.")
        ]
        let cleaned = Echo.removeMicEcho(segments)
        XCTAssertEqual(cleaned.filter { $0.track == .mic }.count, 0)
        XCTAssertEqual(cleaned.filter { $0.track == .system }.count, 3)
    }

    func testOwnSpeechSurvivesNextToEcho() {
        let segments = [
            system(0, 6, "Genau, das sehe ich auch so"),
            mic(0.2, 9, "Genau, das sehe ich auch so und ich würde vorschlagen dass wir das am Freitag festhalten"),
            mic(20, 25, "Ich übernehme die Abstimmung mit dem Kunden"),
            system(19, 26, "Und es können Kleinigkeiten sein")
        ]
        let mine = Echo.removeMicEcho(segments).filter { $0.track == .mic }.map(\.text)
        XCTAssertEqual(mine, ["und ich würde vorschlagen dass wir das am Freitag festhalten",
                              "Ich übernehme die Abstimmung mit dem Kunden"])
    }

    func testTeamsOutputDoesNotAppearAgainAsOwnSpeech() {
        let output = "Ein relativ einfaches Thema, wo wir hauptsächlich ein paar Fragen klären müssen. Es geht darum, dass wir eine Schnittstelle für unsere Plattform bereitstellen."
        let pickedUp = "Ein relativ einfaches Thema, wo wir hauptsächlich ein paar Fragen klären müssen. Es geht darum, dass wir eine MCP-Schnittstelle für unsere Plattform bereitstellen."
        let cleaned = Echo.removeMicEcho([system(679, 693, output), mic(679, 693, pickedUp)])
        XCTAssertEqual(cleaned.count, 1)
        XCTAssertEqual(cleaned.first?.track, .system)
        XCTAssertFalse(MeetingText.lines(cleaned).contains("Ich:"))
    }

    func testSpeakersAreNumberedInOrderOfAppearance() {
        let spans = [SpeakerSpan(speaker: 4, start: 0, end: 10), SpeakerSpan(speaker: 1, start: 10, end: 20)]
        let labelled = Speakers.label([system(1, 9, "a"), mic(9, 11, "b"), system(11, 19, "c"), system(2, 3, "d")], spans: spans)
        XCTAssertEqual(labelled.map { Speakers.name($0) }, ["Sprecher 1", "Ich", "Sprecher 2", "Sprecher 1"])
    }

    func testTranscriptLinesCarryTimeAndRespectWindow() {
        let segments = [system(0, 5, "Hallo"), system(5, 8, "zusammen."), mic(70, 75, "Moin."), system(130, 140, "Marushan, wann bist du fertig?")]
        XCTAssertEqual(MeetingText.lines(segments), "[00:00] Andere: Hallo\n[00:05] Andere: zusammen.\n[01:10] Ich: Moin.\n[02:10] Andere: Marushan, wann bist du fertig?")
        XCTAssertEqual(MeetingText.lines(segments, since: 100), "[02:10] Andere: Marushan, wann bist du fertig?")
        let request = CodexAsk.request(.asked, question: "", snapshot: AssistantSnapshot(segments: segments, elapsed: 300, meeting: "Jour fixe", recording: true))
        XCTAssertEqual(request["transcript"] as? String, "[01:10] Ich: Moin.\n[02:10] Andere: Marushan, wann bist du fertig?")
        XCTAssertEqual(request["meeting"] as? String, "Jour fixe")
    }

    func testAIConfigKeepsPerTaskChoicesAndIgnoresRemovedOllamaFields() throws {
        let json = #"{"structureModel": "qwen3.5:9b", "structureContext": 16384, "ai": {"cleanup": {"provider": "ollama", "model": "qwen3.5:9b"}}}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(config.ai, ["cleanup": ["provider": "ollama", "model": "qwen3.5:9b"]])
        XCTAssertEqual(config.structureHost, "zotac")
        XCTAssertEqual(Array(CodexAsk.bridgeArguments(host: "zotac", script: config.bridgeScript).suffix(3)),
                       ["zotac", "python3", config.bridgeScript])
    }

    func testFollowUpIncludesHistoryAndFreshTranscript() {
        let turns = [ChatTurn(question: "Wer übernimmt das?", answer: "Alex [00:10].")]
        let snapshot = AssistantSnapshot(segments: [system(20, 25, "Die Frist ist Freitag.")], elapsed: 25)
        let request = CodexAsk.request(.question, question: "Bis wann?", snapshot: snapshot, history: turns)
        XCTAssertEqual(request["history"] as? [[String: String]],
                       [["question": "Wer übernimmt das?", "answer": "Alex [00:10]."]])
        XCTAssertEqual(request["transcript"] as? String, "[00:20] Andere: Die Frist ist Freitag.")
        XCTAssertNil(CodexAsk.request(.asked, question: "", snapshot: snapshot, history: turns)["history"])
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: request))
    }

    func testConversationIsBoundedAndResetsAtNewMeeting() {
        var conversation = AssistantConversation()
        let first = AssistantSnapshot(recording: true, startedAt: Date(timeIntervalSince1970: 100))
        conversation.update(for: first)
        for i in 0..<8 { conversation.append(question: "Frage \(i)", answer: "Antwort \(i)") }
        XCTAssertEqual(conversation.turns.map(\.question), (2..<8).map { "Frage \($0)" })
        conversation.update(for: first)
        XCTAssertEqual(conversation.turns.count, 6)
        conversation.update(for: AssistantSnapshot())
        XCTAssertEqual(conversation.turns.count, 6)
        conversation.update(for: AssistantSnapshot(recording: true, startedAt: Date(timeIntervalSince1970: 200)))
        XCTAssertTrue(conversation.turns.isEmpty)
        conversation.append(question: "Neu", answer: "Neu")
        conversation.clear()
        XCTAssertTrue(conversation.turns.isEmpty)
    }
}
