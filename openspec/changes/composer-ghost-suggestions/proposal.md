# Proposal: Composer ghost text and reply options

## Why

Session assist already writes a suggested next message
(`metadata.openchamber.assist.suggestion`), but the composer shows it only as a
clickable row above the input. Two gaps remain:

1. Taking the suggestion needs the mouse. Claude Code shows the same idea as
   greyed-out text in the empty input that Tab accepts, which is faster and
   takes no extra vertical space.
2. When the agent ends its turn waiting for the user's decision ("Shall I
   merge?", "Option A or B?"), the assist deliberately returns nothing
   (`session-assist/DOCUMENTATION.md`, Generation step 5). That is exactly the
   moment where a short ready-made answer helps most.

## What Changes

- **Ghost text.** While the composer is empty and a current suggestion exists,
  the suggestion is drawn as greyed-out text inside the input. An accept key
  (Tab, see open decision D3) inserts it with the caret at the end. Typing any
  character or pressing Escape dismisses it for this turn. Nothing is ever sent
  automatically.
- **Reply options.** When the latest answer waits for a decision the user can
  give in a few words, session assist returns 2 to 3 short reply options in the
  user's voice instead of an empty suggestion. They appear as chips in the
  composer's top row; clicking a chip fills the composer (no send). The first
  option is also the ghost text.
- **Finished work stays silent.** A satisfied request, a closing summary, or a
  closing status line that reports completion still yields no suggestion and no
  options.
- **Gate.** The turn-end Jev gate today rules out the suggestion field exactly
  for "the next move belongs to the user". It gets one more question so a
  pending decision keeps the field alive; the Small Model then decides between
  continuation, options, or nothing.
- **Payload.** `assist` gains an optional `options: string[]`. `suggestion`
  keeps its meaning; older clients that ignore `options` behave as today.

## Non-goals

- No automatic sending, ever; not for options, not after a timeout.
- No answering of OpenCode's own question tool / permission forms. Those keep
  their dedicated UI, and ghost text and chips stay hidden while one is pending
  (as the suggestion row does today).
- No free-form autocomplete while typing (no completion of half-written
  messages). Ghost text exists only for an empty composer.
- No parsing of a project-specific status line (such as
  `STATUS: WARTET AUF ...`) as a hard rule in upstream code. The model judges;
  such a line is ordinary evidence in the answer text (see D2).
- No new model call per keystroke and no extra Small Model call per turn:
  options come from the same generation as recap and suggestion.
- No change to recap, sidebar tooltip, "In work", or review-offer behavior.
- No suggestions for subsessions, archived or reverted sessions (unchanged).
- VS Code's extension-only runtime still does not generate assists; it only
  renders payloads produced by a server.

## Capabilities

### New Capabilities

- `composer-suggestions`: how the composer presents a current suggestion
  (ghost text, accept and dismiss keys, reply-option chips, hiding rules).
- `session-assist-reply-options`: when session assist produces a
  continuation suggestion, reply options, or nothing, and the payload contract.

### Modified Capabilities

None (the repository has no OpenSpec specs yet; the current behavior lives in
`packages/web/server/lib/session-assist/DOCUMENTATION.md` and
`packages/ui/src/components/chat/composer/DOCUMENTATION.md`, which are updated
alongside the code).

## Impact

- Server: `packages/web/server/lib/session-assist/{prompt,runtime}.js`,
  `packages/web/server/lib/session-work/questions.js` (one Jev question and the
  gate decision), their tests and `DOCUMENTATION.md` files.
- UI: `packages/ui/src/lib/sessionAssistMetadata.ts`,
  `packages/ui/src/hooks/useSessionAssist.ts`,
  `packages/ui/src/components/chat/SessionSuggestionChip.tsx`,
  `ChatInput.tsx` keyboard handling, a CodeMirror ghost-text extension under
  `packages/ui/src/components/chat/composer/editor/`, i18n keys, composer
  `DOCUMENTATION.md`.
- Runtimes: web, Electron and hosted mobile share the UI; Capacitor and touch
  layouts keep chips only (no hardware Tab assumed). VS Code renders payloads.
- No new dependency. No new setting if D4 is accepted as recommended.

## Open decisions for Esref

- **D1 Upstream path.** CONTRIBUTING requires an Ideas discussion and the
  maintainer's go-ahead before a feature PR. Recommendation: build in the fork
  for our own use now, post a discussion draft (shown to Esref first) in
  parallel, PR only after a go-ahead.
- **D2 Decision signal.** Recommendation: model judgment only (generic,
  upstream-acceptable). Alternative: additionally treat a closing
  `STATUS: WARTET AUF ESREF` / `STATUS: FERTIG` line as a hard signal in a
  fork-only patch.
- **D3 Accept key.** Tab is OpenChamber's default `cycle_agent` shortcut.
  Recommendation: Tab accepts only while ghost text is visible; once it is
  dismissed (or absent) Tab cycles agents as before. Alternative: Right arrow
  (or End) accepts, Tab untouched.
- **D4 Continuation display and setting.** Recommendation: on desktop the
  continuation suggestion shows as ghost text plus a small "Tab" hint, and the
  current suggestion row is dropped there; touch layouts keep the row. Reuse
  `sessionSuggestionEnabled`, no new toggle. Alternative: keep the row on
  desktop too, or add a separate "ghost text" toggle.
- **D5 Dismiss persistence.** Recommendation: Escape and typing dismiss
  locally for this turn only; the chip row's X keeps deleting the payload from
  session metadata (everywhere), as today.
