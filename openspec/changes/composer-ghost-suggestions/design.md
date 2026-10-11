# Design

## Context

See proposal.md (Why). Relevant current state, at tag `v2.2.0`:

- `session-assist/runtime.js` asks Jev (`session-work/questions.js`,
  `decideAssist`) which fields are worth the Small Model, waits 60 s of quiet,
  then makes one structured Small Model call for `recap` and `suggestion`.
- The Jev `next_step` criteria explicitly answer *false* when "the next move
  belongs to the user (test, choose, approve, answer a question)", and the
  prompt in `prompt.js` returns `""` in the same case. Both have to change for
  options to exist.
- The composer is a CodeMirror 6 editor (`composer/editor/ComposerEditor.tsx`)
  with a placeholder compartment. Keys go through `ChatInput.handleKeyDown`,
  where Tab is the default `cycle_agent` shortcut and the autocomplete menu
  already consumes Tab while open.
- `SessionSuggestionChip` renders the composer top row and deletes the
  suggestion from metadata on X.

## Goals / Non-Goals

Goals: one generation per turn as today, no extra network on the client,
Tab-accept that never steals Tab when nothing is shown. Non-goals: see
proposal.md.

## Decisions

1. **Options in the same structured call.** The JSON schema gains
   `options: string[]` whenever `suggestion` is requested. The system prompt
   describes the three outcomes (continue, options, nothing) with the existing
   "finishing is normal" bias kept. Alternative: a second call only for
   decision turns. Rejected: doubles cost and latency for no quality gain on
   small models.
2. **Server-side validation, not trust.** `runtime.js` trims, drops options
   over 80 chars or failing `scriptMismatch`, de-duplicates, caps at 3, and
   discards sets under 2. If options survive, `suggestion` is cleared.
3. **One extra Jev question, same call.** Add `awaits_reply` ("Does the final
   answer end by asking the user to choose, approve, or answer something a few
   words can settle?"). `decideAssist` allows the suggestion field when
   `next_step >= 0.5 || awaits_reply >= 0.5`. The `next_step` wording stays
   unchanged so its measured behavior stays. The threshold is a first value
   and is verified on recorded sessions (task 5.2). Alternative: drop the
   gate for the suggestion field. Rejected: loses the cost filter that the
   maintainer measured.
4. **Decision signal is model judgment (D2).** No regex on status lines in
   upstream code. Prompt guidance names "a closing line that reports the work
   as done" as a reason for nothing and "a closing question to the user" as a
   reason for options, without any project-specific wording.
5. **Ghost text as a CodeMirror widget.** A small extension
   (`composer/editor/ghostText.ts`) holds a `StateField<string | null>` set by
   an effect from `ChatInput`, and renders a `Decoration.widget` at position 0
   only while the doc is empty. The placeholder is suppressed while ghost text
   shows. The widget is `aria-hidden`; the editor gets `aria-description`.
   Alternative: an overlay `<div>` positioned over the editor. Rejected:
   breaks with bidi, wrapping, and font scaling that CodeMirror already
   handles.
6. **Key handling in `ChatInput` (D3).** Before the `cycle_agent` branch and
   after the autocomplete branch: if ghost text is visible and the key is the
   accept key, `preventDefault`, insert, mark the payload consumed. Escape
   with visible ghost text dismisses before the BTW/expanded Escape branches.
   Any doc change dismisses. "Consumed" is local UI state keyed by
   `forMessageID + generatedAt`, so a new payload shows again.
7. **Chips extend `SessionSuggestionChip`** rather than a new component: it
   renders either the single continuation row (touch layouts, and desktop if
   D4 keeps it) or the option chips. Its X deletes both fields.
8. **Payload parsing** in `sessionAssistMetadata.ts` gains `options: string[]`
   with the same validation as the server (defensive, a malformed entry drops
   the set), and `getSessionAssist` treats options as content for the
   "has anything" check.

## Risks / Trade-offs

- [Tab muscle memory for agent cycling] → Tab only acts on visible ghost text;
  Escape first restores plain Tab. The hint shows the key. D3 alternative
  available.
- [Small models invent options for finished work] → prompt bias plus server
  rule "fewer than 2 valid → none", plus tests on fixtures of finished turns.
- [Options that sound like approval are picked carelessly] → never sent
  automatically; the user still presses Enter. Option text is only text.
- [Extra Jev question changes gate cost] → same call, one more noul question.
- [Upstream rejects the product direction] → fork keeps working; changes are
  isolated to the listed modules so rebasing stays cheap.

## Migration Plan

No data migration: `options` is additive and old payloads stay valid. Rollout
to the builder and the way back to the npm build are planned separately
(Head of Staff step 5) and need Esref's approval because restarting
`dev.openchamber.web` interrupts running sessions.

## Open Questions

- Exact Jev threshold for `awaits_reply` after measuring on real sessions
  (does not change specs or tasks).
