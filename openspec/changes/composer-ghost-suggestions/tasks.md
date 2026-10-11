# Tasks

## 1. Server: reply options

- [x] 1.1 Extend `buildAssistSystemPrompt` / `buildAssistPrompt` with the `options` field and the three-outcome guidance; verify with new cases in `session-assist` tests (prompt contains options rules only when suggestion is requested).
- [x] 1.2 Validate and store `options` in `runtime.js` (trim, 80 chars, script guard, dedupe, 2 to 3, clears suggestion); verify with `runtime.test.js` cases for valid set, too few, duplicates, both returned, setting off.
- [x] 1.3 Add Jev `awaits_reply` question and extend `decideAssist`; verify with `session-work` tests (gate allows suggestion on decision, unanswered stays allowed).
- [x] 1.4 Update `session-assist/DOCUMENTATION.md` (step 5, payload) and `session-work/DOCUMENTATION.md`; verify by review.

## 2. UI: payload and state

- [x] 2.1 Parse `options` in `sessionAssistMetadata.ts` and expose them via `useSessionAssist`; verify with unit tests for parse and freshness.
- [x] 2.2 Dismiss (X) removes `suggestion` and `options`; verify with a test of the metadata patch.

## 3. UI: ghost text

- [x] 3.1 CodeMirror ghost-text extension (state field, widget, placeholder suppression, aria); verify with editor unit tests (shown only on empty doc, hidden on change).
- [x] 3.2 `ChatInput` wiring: visibility rules, accept key, Escape, local consumed state per payload, Tab falls through to `cycle_agent` when nothing is shown; verify with tests and a live run in the browser.

## 4. UI: option chips

- [x] 4.1 `SessionSuggestionChip` renders option chips and the continuation row per layout decision D4; click fills composer without sending; verify with component tests and live run (desktop and mobile viewport).
- [x] 4.2 i18n keys for all shipped locales; verify `bun run --cwd packages/ui test` for i18n checks.
- [x] 4.3 Update `composer/DOCUMENTATION.md`; verify by review.

## 5. Validation

- [x] 5.1 `bun run check:changed` and `bun run test` green.
- [ ] 5.2 Live check against a real OpenCode session on the builder (dev port, not 3000): continuation turn shows ghost text, decision turn shows 2 to 3 chips, finished turn shows nothing; record screenshots for the PR.
- [ ] 5.3 Reviews by `reviewer` and `reviewer-astra`, findings resolved.
