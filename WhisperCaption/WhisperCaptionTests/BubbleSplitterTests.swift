import Foundation
import Testing
@testable import WhisperCaption

/// Behaviour tests for `BubbleSplitter`. The splitter is an aggregator: it
/// keeps a "live" bubble open across streaming partials, only emitting a
/// `isFinal=true` head when accumulated text crosses `maxChars`. These tests
/// pin that contract down — anything outside of it (silence-driven finals,
/// engine id rollover) is the responsibility of `CaptionStream`.
@MainActor
@Suite("BubbleSplitter")
struct BubbleSplitterTests {

    private let baseDate = Date(timeIntervalSinceReferenceDate: 0)

    // MARK: - Empty / short input

    @Test("process() on whitespace-only text returns no captions")
    func emptyTextReturnsNoCaptions() {
        let splitter = BubbleSplitter()
        let config = BubbleSplitter.Config(maxChars: 80, sentenceAware: true)
        let input = Caption(
            id: UUID(),
            source: .microphone,
            text: "   ",
            isFinal: false,
            startedAt: baseDate,
            updatedAt: baseDate
        )

        let out = splitter.process(input, config: config)
        #expect(out.isEmpty)
    }

    @Test("Short final caption is passed through as a single non-final bubble")
    func shortFinalPassesThrough() {
        let splitter = BubbleSplitter()
        let config = BubbleSplitter.Config(maxChars: 80, sentenceAware: true)
        let input = Caption(
            id: UUID(),
            source: .microphone,
            text: "hello there",
            isFinal: true,
            startedAt: baseDate,
            updatedAt: baseDate
        )

        let out = splitter.process(input, config: config)
        #expect(out.count == 1)
        let bubble = out.first
        #expect(bubble?.text == "hello there")
        // Aggregator behaviour: engine "final" is downgraded to live so the
        // bubble can keep growing.
        #expect(bubble?.isFinal == false)
    }

    // MARK: - Splitting

    @Test("Long input splits at the sentence boundary when sentence-aware is on")
    func longInputSplitsAtSentenceBoundary() throws {
        let splitter = BubbleSplitter()
        // maxChars=20, safeFloor=14. The period after "First sentence" lives
        // at index 14, which sits at the bottom of the safe zone — exactly
        // where the splitter is supposed to cut.
        let config = BubbleSplitter.Config(maxChars: 20, sentenceAware: true)
        let input = Caption(
            id: UUID(),
            source: .microphone,
            text: "First sentence. Second sentence here",
            isFinal: false,
            startedAt: baseDate,
            updatedAt: baseDate
        )

        let out = splitter.process(input, config: config)
        #expect(out.count == 2)

        let head = try #require(out.first)
        let tail = try #require(out.last)
        #expect(head.isFinal)
        #expect(head.text.hasSuffix("sentence."))
        #expect(!tail.isFinal)
        #expect(tail.text.contains("Second sentence"))
        // Head and tail wear different ids — the head closes out the old
        // bubble, the tail opens a fresh one.
        #expect(head.id != tail.id)
    }

    // MARK: - Stable id across partials

    @Test("Repeated partials for the same engine id keep the same live bubble id")
    func samePartialIdKeepsLiveBubbleId() {
        let splitter = BubbleSplitter()
        let config = BubbleSplitter.Config(maxChars: 200, sentenceAware: true)
        let engineID = UUID()

        let first = Caption(
            id: engineID,
            source: .microphone,
            text: "hello",
            isFinal: false,
            startedAt: baseDate,
            updatedAt: baseDate
        )
        let second = Caption(
            id: engineID,
            source: .microphone,
            text: "hello world",
            isFinal: false,
            startedAt: baseDate,
            updatedAt: baseDate.addingTimeInterval(0.5)
        )

        let outA = splitter.process(first, config: config)
        let outB = splitter.process(second, config: config)
        #expect(outA.count == 1)
        #expect(outB.count == 1)
        #expect(outA.first?.id == outB.first?.id)
        #expect(outB.first?.text == "hello world")
    }

    // MARK: - liveBubble / forgetLive / resetAll

    @Test("liveBubble(for:) reports the live bubble until it's forgotten")
    func liveBubbleReportsCurrentBubble() {
        let splitter = BubbleSplitter()
        let config = BubbleSplitter.Config(maxChars: 200, sentenceAware: true)

        #expect(splitter.liveBubble(for: .microphone) == nil)

        let partial = Caption(
            id: UUID(),
            source: .microphone,
            text: "live text",
            isFinal: false,
            startedAt: baseDate,
            updatedAt: baseDate
        )
        let out = splitter.process(partial, config: config)
        let bubble = splitter.liveBubble(for: .microphone)
        #expect(bubble != nil)
        #expect(bubble?.id == out.first?.id)

        splitter.forgetLive(source: .microphone)
        #expect(splitter.liveBubble(for: .microphone) == nil)
    }

    @Test("finalize(source:) discards already-shipped engine text — next emit shows only NEW content")
    func finalizeDropsConsumedTextOnNextEmit() {
        // The screenshot-mid-phrase scenario: while a phrase is in flight,
        // CaptionStream finalises the live bubble. The engine keeps emitting
        // under the same engineId, with caption.text containing everything
        // from the start of the phrase. The splitter must show ONLY the
        // delta past the finalize point — not re-emit the pre-finalize text
        // as a duplicate bubble.
        let splitter = BubbleSplitter()
        let config = BubbleSplitter.Config(maxChars: 400, sentenceAware: true)
        let engineID = UUID()

        let before = Caption(
            id: engineID,
            source: .microphone,
            text: "hello world this is the first part",
            isFinal: false,
            startedAt: baseDate,
            updatedAt: baseDate
        )
        let outA = splitter.process(before, config: config)
        let beforeBubbleID = outA.first?.id

        // Mid-phrase, the stream finalises the bubble (screenshot).
        splitter.finalize(source: .microphone)

        // Engine continues to emit for the same phrase: caption.text now
        // contains the old content + new content.
        let after = Caption(
            id: engineID,
            source: .microphone,
            text: "hello world this is the first part and then more",
            isFinal: false,
            startedAt: baseDate,
            updatedAt: baseDate.addingTimeInterval(1)
        )
        let outB = splitter.process(after, config: config)

        #expect(outB.count == 1)
        let fresh = try? #require(outB.first)
        #expect(fresh?.id != beforeBubbleID, "Splitter reused the closed bubble's id")
        // The new bubble must show ONLY the content past the finalize
        // point — not duplicate the pre-finalize text.
        #expect(fresh?.text.contains("hello world") == false,
                "Pre-finalize content leaked into the new bubble: '\(fresh?.text ?? "")'")
        #expect(fresh?.text.contains("and then more") == true)
    }

    @Test("finalize(source:) gives the next bubble a fresh startedAt at finalize time")
    func finalizeRefreshesBubbleStartedAt() {
        let splitter = BubbleSplitter()
        let config = BubbleSplitter.Config(maxChars: 400, sentenceAware: true)
        let engineID = UUID()
        // Engine reports a phrase that started in the distant past.
        let oldPhraseStart = Date(timeIntervalSinceReferenceDate: 0)

        let before = Caption(
            id: engineID,
            source: .microphone,
            text: "early content",
            isFinal: false,
            startedAt: oldPhraseStart,
            updatedAt: oldPhraseStart
        )
        _ = splitter.process(before, config: config)

        let finalizeAt = Date()
        splitter.finalize(source: .microphone)

        let after = Caption(
            id: engineID,
            source: .microphone,
            text: "early content and continuation text",
            isFinal: false,
            startedAt: oldPhraseStart,
            updatedAt: Date()
        )
        let outB = splitter.process(after, config: config)
        let fresh = outB.first

        // The new bubble's startedAt should reflect the finalize moment,
        // NOT the engine's old phrase start.
        #expect(fresh != nil)
        #expect((fresh?.startedAt ?? .distantPast) >= finalizeAt,
                "Bubble startedAt = \(fresh?.startedAt ?? .distantPast), finalizeAt = \(finalizeAt) — expected new bubble to be timestamped at finalize time")
    }

    @Test("forgetLive(source:) starts a fresh bubble even when the next emit reuses the same engine id")
    func forgetLiveThenSameEngineIdStartsFreshBubble() {
        // Real scenario: an engine emits interim updates for a phrase
        // under one engineId. Mid-phrase, `CaptionStream.appendScreenshot`
        // closes the live bubble (forgetLive). The engine continues to
        // emit interim updates for the SAME phrase (engineId unchanged).
        // The splitter must mint a fresh ourId — otherwise the new emit
        // collides with the already-final prior bubble and overwrites it.
        let splitter = BubbleSplitter()
        let config = BubbleSplitter.Config(maxChars: 200, sentenceAware: true)
        let engineID = UUID()

        let first = Caption(
            id: engineID,
            source: .microphone,
            text: "ongoing phrase",
            isFinal: false,
            startedAt: baseDate,
            updatedAt: baseDate
        )
        let outA = splitter.process(first, config: config)
        let firstID = outA.first?.id

        splitter.forgetLive(source: .microphone)

        let second = Caption(
            id: engineID,           // <-- SAME engine id, phrase continues
            source: .microphone,
            text: "ongoing phrase and more",
            isFinal: false,
            startedAt: baseDate,
            updatedAt: baseDate.addingTimeInterval(0.5)
        )
        let outB = splitter.process(second, config: config)
        let secondID = outB.first?.id

        #expect(firstID != nil)
        #expect(secondID != nil)
        #expect(firstID != secondID, "Splitter reused the engine id as ourId after forgetLive — the new bubble collides with the closed one")
    }

    @Test("forgetLive(source:) starts a fresh bubble on the next emit")
    func forgetLiveStartsFreshBubble() {
        let splitter = BubbleSplitter()
        let config = BubbleSplitter.Config(maxChars: 200, sentenceAware: true)

        let firstEngineID = UUID()
        let first = Caption(
            id: firstEngineID,
            source: .microphone,
            text: "first bubble",
            isFinal: false,
            startedAt: baseDate,
            updatedAt: baseDate
        )
        let outA = splitter.process(first, config: config)
        let firstBubbleID = outA.first?.id

        splitter.forgetLive(source: .microphone)

        let second = Caption(
            id: UUID(),
            source: .microphone,
            text: "second bubble",
            isFinal: false,
            startedAt: baseDate.addingTimeInterval(1),
            updatedAt: baseDate.addingTimeInterval(1)
        )
        let outB = splitter.process(second, config: config)
        let secondBubbleID = outB.first?.id

        #expect(firstBubbleID != nil)
        #expect(secondBubbleID != nil)
        #expect(firstBubbleID != secondBubbleID)
    }

    @Test("resetAll() clears both microphone and system state")
    func resetAllClearsBothSources() {
        let splitter = BubbleSplitter()
        let config = BubbleSplitter.Config(maxChars: 200, sentenceAware: true)

        let mic = Caption(
            id: UUID(),
            source: .microphone,
            text: "mic line",
            isFinal: false,
            startedAt: baseDate,
            updatedAt: baseDate
        )
        let sys = Caption(
            id: UUID(),
            source: .system,
            text: "system line",
            isFinal: false,
            startedAt: baseDate,
            updatedAt: baseDate
        )
        _ = splitter.process(mic, config: config)
        _ = splitter.process(sys, config: config)
        #expect(splitter.liveBubble(for: .microphone) != nil)
        #expect(splitter.liveBubble(for: .system) != nil)

        splitter.resetAll()
        #expect(splitter.liveBubble(for: .microphone) == nil)
        #expect(splitter.liveBubble(for: .system) == nil)
    }

    // MARK: - Cross-source independence

    @Test("Microphone and system bubbles run in parallel with independent ids")
    func crossSourceIndependence() {
        let splitter = BubbleSplitter()
        let config = BubbleSplitter.Config(maxChars: 200, sentenceAware: true)

        let mic = Caption(
            id: UUID(),
            source: .microphone,
            text: "mic line",
            isFinal: false,
            startedAt: baseDate,
            updatedAt: baseDate
        )
        let sys = Caption(
            id: UUID(),
            source: .system,
            text: "system line",
            isFinal: false,
            startedAt: baseDate,
            updatedAt: baseDate
        )

        let micOut = splitter.process(mic, config: config)
        let sysOut = splitter.process(sys, config: config)

        #expect(micOut.first?.source == .microphone)
        #expect(sysOut.first?.source == .system)
        #expect(micOut.first?.id != sysOut.first?.id)

        let micLive = splitter.liveBubble(for: .microphone)
        let sysLive = splitter.liveBubble(for: .system)
        #expect(micLive != nil)
        #expect(sysLive != nil)
        #expect(micLive?.id != sysLive?.id)
    }
}
