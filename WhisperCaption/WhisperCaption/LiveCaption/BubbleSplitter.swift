import Foundation

/// Post-process layer between `TranscriptionEngine` output and the chat
/// model. Each engine emits captions at its own cadence — WhisperKit cuts
/// sentences after ~30-50 chars, Deepgram on server endpointing, ElevenLabs
/// on server VAD (often 200-400 chars). This layer normalises that into a
/// single user-controlled bubble shape:
///
///   * **Aggregator** — when the engine emits a final, we don't pass it
///     through as a final. The bubble stays open and grows by appending
///     the text of subsequent engine utterances. The bubble only closes
///     (`isFinal=true`) when one of:
///       1. Accumulated text crosses `maxChars` → forced cut, head goes
///          out as final, tail keeps growing in a fresh bubble id.
///       2. Silence timeout elapses (handled by `CaptionStream`'s task,
///          which calls `liveBubble(for:)` to find the open bubble and
///          marks it final, then `forgetLive(source:)` here).
///
///   * **Splitter** — when accumulated text exceeds `maxChars` we cut at
///     the nearest sentence boundary (or word boundary if sentence-aware
///     is off) within the safe zone (last ~30% of the cap). Last-resort
///     hard cut at the cap if no boundary is in range.
///
/// State per source — engine keeps emitting partials/finals with its own
/// caption ids; we project everything onto our own ids and an offset that
/// lets us cleanly split a still-in-flight engine utterance.
///
/// Not threaded — `@MainActor` because every caller (`CaptionStream`)
/// already runs there.
@MainActor
final class BubbleSplitter {

    /// Inputs for one process call. Lifted to a struct so settings are read
    /// once per caption and not threaded through closures.
    struct Config {
        let maxChars: Int
        let sentenceAware: Bool
    }

    /// One per `CaptionSource`. Cleared when the silence task or the
    /// stream itself closes the bubble.
    private struct SourceState {
        /// Our id for the bubble currently visible in the chat. Starts as
        /// the engine's first id for this bubble, replaced by a fresh
        /// UUID after every mid-flight split.
        var ourId: UUID
        /// Wall-clock of the moment THIS bubble was first emitted into the
        /// UI. NOT the engine's phrase-start time. Used as `startedAt` on
        /// every emit for this bubble, so the chat's timeline sort places
        /// the bubble at "when it was created", independent of when the
        /// underlying engine phrase began. Refreshed every time `ourId` is
        /// minted (fresh state, split tail, or after `finalize(source:)`).
        var bubbleStartedAt: Date
        /// Text from previous engine utterances (or from a prior split's
        /// tail) that already belongs to this bubble. Won't change unless
        /// the next emit pushes us past maxChars and we re-split.
        var fixedPrefix: String
        /// Engine's id for the utterance currently being narrated.
        var engineId: UUID
        /// Number of characters of the current engine utterance's text
        /// that have already been shipped — either as part of a previous
        /// finalised head, or already merged into `fixedPrefix`. The live
        /// engine contribution for the next emit is
        /// `caption.text.dropFirst(engineConsumed)`.
        var engineConsumed: Int
        /// Snapshot of the engine's most recent caption.text — used so the
        /// live engine text can be reconstructed on every emit independent
        /// of partial replay quirks.
        var lastEngineText: String
        /// Wall-clock of last update. Read by the silence task in
        /// `CaptionStream` to decide when to close the bubble.
        var lastUpdatedAt: Date
    }

    private var state: [CaptionSource: SourceState] = [:]

    func reset(source: CaptionSource) { state[source] = nil }
    func resetAll() { state.removeAll() }

    /// Returns 0, 1, or 2 captions to push into the chat:
    /// - 0 — incoming text was empty after trim; nothing to show.
    /// - 1 — pass-through (with our id) of the live bubble's current text.
    /// - 2 — split happened: finalised head with prior `ourId`, then
    ///       the tail under a fresh `ourId`.
    func process(_ caption: Caption, config: Config) -> [Caption] {
        let source = caption.source
        let captionText = caption.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !captionText.isEmpty else { return [] }

        // --- step 1: bring state up to date for the incoming caption ---
        if var s = state[source] {
            if s.engineId != caption.id {
                // Engine has rolled to a new utterance. Lock the
                // UNCONSUMED portion of the previous engine text into the
                // fixed prefix — anything already shipped (via a prior
                // split's head or via `finalize(source:)`) stays out, so
                // a finalize-then-engine-roll path doesn't re-show the
                // pre-finalize content.
                let total = s.lastEngineText
                let unconsumed: String = {
                    guard s.engineConsumed < total.count else { return "" }
                    let idx = total.index(total.startIndex, offsetBy: s.engineConsumed)
                    return String(total[idx...])
                }()
                let liveOld = unconsumed.trimmingCharacters(in: .whitespacesAndNewlines)
                if !liveOld.isEmpty {
                    let trimmedPrefix = s.fixedPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
                    s.fixedPrefix = trimmedPrefix.isEmpty ? liveOld : (trimmedPrefix + " " + liveOld)
                }
                s.engineId = caption.id
                s.engineConsumed = 0
            }
            s.lastEngineText = caption.text
            s.lastUpdatedAt = caption.updatedAt
            state[source] = s
        } else {
            // Fresh state for this source. Mint a NEW `ourId` (NOT the
            // engine's caption.id) — after a `forgetLive(source:)` the
            // engine may keep emitting under the same engine id, so
            // reusing it would collide with the already-final prior
            // bubble in `CaptionStream.captions`. Also stamp
            // `bubbleStartedAt = Date()` so the timeline sort places
            // this bubble at "now", not at the engine's phrase start.
            state[source] = SourceState(
                ourId: UUID(),
                bubbleStartedAt: Date(),
                fixedPrefix: "",
                engineId: caption.id,
                engineConsumed: 0,
                lastEngineText: caption.text,
                lastUpdatedAt: caption.updatedAt
            )
        }

        var s = state[source]!

        // --- step 2: compute the live display text ---
        let liveEngineText: String = {
            let total = s.lastEngineText
            guard total.count > s.engineConsumed else { return "" }
            let start = total.index(total.startIndex, offsetBy: s.engineConsumed)
            return String(total[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        let prefixTrim = s.fixedPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayText: String = {
            if prefixTrim.isEmpty { return liveEngineText }
            if liveEngineText.isEmpty { return prefixTrim }
            return prefixTrim + " " + liveEngineText
        }()

        // --- step 3: split if we crossed the cap ---
        if displayText.count > config.maxChars,
           let splitPos = Self.findSplitPosition(in: displayText,
                                                  maxChars: config.maxChars,
                                                  sentenceAware: config.sentenceAware) {

            let headEnd = displayText.index(displayText.startIndex, offsetBy: splitPos)
            let head = displayText[..<headEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = displayText[headEnd...].trimmingCharacters(in: .whitespacesAndNewlines)

            if !head.isEmpty && !tail.isEmpty {
                let finalised = Caption(
                    id: s.ourId,
                    source: source,
                    text: head,
                    language: caption.language,
                    isFinal: true,
                    startedAt: s.bubbleStartedAt,
                    updatedAt: caption.updatedAt
                )

                // For the tail, work out how much came from each side so
                // the next engine partial doesn't double-count.
                //
                // Layout of displayText = prefixTrim + " " + liveEngineText
                // splitPos counts characters in displayText; same for
                // headLength = head.count (after trim, ~= splitPos).
                //
                // If splitPos <= prefixTrim.count: cut inside the prefix.
                //   tail = prefixTrim[splitPos:] + " " + liveEngineText
                //   The whole live engine utterance is in tail, so all of
                //   it is "unconsumed". engineConsumed stays where it was;
                //   we'll keep reading the engine's text past engineConsumed
                //   into the new bubble.
                //   New fixedPrefix = "" and the next emit will see
                //   liveEngineText == tail's engine portion. But we ALSO
                //   need the prefix-tail (the unfinalised remnant) to live
                //   somewhere — put it in fixedPrefix.
                // If splitPos > prefixTrim.count: cut inside the live
                //   engine text. The prefix is fully in head; tail is
                //   entirely from live engine text. Bump engineConsumed by
                //   (live.count - tail.count) so the next emit sees only
                //   the new tail and beyond.
                let newOurId = UUID()
                let newBubbleStartedAt = Date()
                if splitPos <= prefixTrim.count {
                    // Tail spans (remaining prefix) + space + live engine text
                    let prefixCutIdx = prefixTrim.index(prefixTrim.startIndex, offsetBy: splitPos)
                    let prefixTail = String(prefixTrim[prefixCutIdx...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    s.fixedPrefix = prefixTail
                    // engineConsumed unchanged; lastEngineText unchanged.
                } else {
                    // Tail is purely from live engine text. The live engine
                    // text portion that landed in head is
                    // (liveEngineText.count - tail.count) characters; add
                    // that to engineConsumed.
                    let liveLandedInHead = max(0, liveEngineText.count - tail.count)
                    s.engineConsumed += liveLandedInHead
                    s.fixedPrefix = ""
                }
                s.ourId = newOurId
                s.bubbleStartedAt = newBubbleStartedAt
                s.lastUpdatedAt = caption.updatedAt
                state[source] = s

                let tailCaption = Caption(
                    id: newOurId,
                    source: source,
                    text: tail,
                    language: caption.language,
                    isFinal: false,
                    startedAt: newBubbleStartedAt,
                    updatedAt: caption.updatedAt
                )
                return [finalised, tailCaption]
            }
        }

        // --- step 4: no split. Pass through as a live (not-final) update. ---
        // Crucially we override `isFinal=false` even when the engine said
        // true — that's the aggregator behaviour: the bubble stays open so
        // the next utterance can append to it.
        if displayText.isEmpty { return [] }

        let display = Caption(
            id: s.ourId,
            source: source,
            text: displayText,
            language: caption.language,
            isFinal: false,
            startedAt: s.bubbleStartedAt,
            updatedAt: caption.updatedAt
        )
        return [display]
    }

    /// Snapshot for the silence-driven finaliser on `CaptionStream`.
    func liveBubble(for source: CaptionSource) -> (id: UUID, lastUpdatedAt: Date)? {
        guard let s = state[source] else { return nil }
        return (s.ourId, s.lastUpdatedAt)
    }

    /// Drop all state for the source so the next emit starts completely
    /// fresh. Use this when the engine has TRULY moved on — e.g. the
    /// caller is sure a new phrase begins next. For mid-phrase finalises
    /// (screenshot, silence), prefer `finalize(source:)`, which keeps the
    /// engine bookkeeping but starts a fresh UI bubble.
    func forgetLive(source: CaptionSource) {
        state[source] = nil
    }

    /// Close the current UI bubble in-place: keep tracking what the
    /// engine has already shipped, but mint a fresh `ourId` +
    /// `bubbleStartedAt` so the next emit opens a new bubble at "now".
    ///
    /// Crucially `engineConsumed = lastEngineText.count`: any further
    /// emits with the same engine id show only NEW content past the
    /// cutoff, so a screenshot taken mid-phrase doesn't cause the
    /// already-spoken text to reappear in a duplicate bubble below the
    /// image.
    func finalize(source: CaptionSource) {
        guard var s = state[source] else { return }
        s.engineConsumed = s.lastEngineText.count
        s.fixedPrefix = ""
        s.ourId = UUID()
        s.bubbleStartedAt = Date()
        s.lastUpdatedAt = Date()
        state[source] = s
    }

    // MARK: - Split-position search

    /// Returns an index into `text` at which to split. When `sentenceAware`,
    /// prefers cutting AFTER a sentence terminator (`.`, `?`, `!`, `…`)
    /// inside the safe zone (last ~30% of the cap). Falls back to a
    /// whitespace cut, then a hard cut at `maxChars`.
    static func findSplitPosition(in text: String, maxChars: Int, sentenceAware: Bool) -> Int? {
        let length = text.count
        guard length > maxChars else { return nil }

        let safeFloor = max(maxChars * 7 / 10, 1)
        let upper = min(maxChars, length)

        if sentenceAware {
            let terminators: Set<Character> = [".", "?", "!", "…"]
            if let pos = lastIndex(in: text, lower: safeFloor, upperExclusive: upper, where: { terminators.contains($0) }) {
                return pos + 1
            }
        }

        if let pos = lastIndex(in: text, lower: safeFloor, upperExclusive: upper, where: { $0.isWhitespace }) {
            return pos + 1
        }

        return upper
    }

    private static func lastIndex(
        in text: String,
        lower: Int,
        upperExclusive: Int,
        where predicate: (Character) -> Bool
    ) -> Int? {
        guard lower < upperExclusive, upperExclusive <= text.count else { return nil }
        var i = upperExclusive - 1
        while i >= lower {
            let idx = text.index(text.startIndex, offsetBy: i)
            if predicate(text[idx]) { return i }
            i -= 1
        }
        return nil
    }
}
