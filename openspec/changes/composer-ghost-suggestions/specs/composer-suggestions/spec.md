## ADDED Requirements

### Requirement: Ghost text in the empty composer

On layouts with a hardware keyboard (desktop web, Electron, VS Code webview),
when the composer is empty, the session is idle, and a current suggestion or
option set exists, the composer SHALL show the continuation suggestion, or else
the first option, as greyed-out text at the caret position in place of the
placeholder. It SHALL be hidden under every condition that hides the
suggestion row today (pending question or permission form, queued messages,
BTW, new-session draft, running turn).

#### Scenario: Suggestion appears
- **WHEN** a turn ends and the assist writes a suggestion while the composer is empty
- **THEN** the suggestion is drawn as ghost text with a visible accept-key hint

#### Scenario: Pending form
- **WHEN** a question or permission form is pending
- **THEN** no ghost text is drawn

### Requirement: Accepting ghost text

While ghost text is visible and no autocomplete menu is open, the accept key
SHALL insert the ghost text into the composer, place the caret at the end, and
focus the composer. Accepting SHALL NOT send. While ghost text is not visible,
the accept key SHALL keep its existing behavior (agent cycling for Tab).

#### Scenario: Tab accepts
- **WHEN** ghost text is visible and the user presses the accept key
- **THEN** the composer contains the text, the caret is at its end, and nothing was sent

#### Scenario: Tab without ghost text
- **WHEN** no ghost text is visible and the user presses Tab
- **THEN** the agent cycles as before

### Requirement: Dismissing ghost text

Typing any character, pasting, or pressing Escape while ghost text is visible
SHALL dismiss it for the current payload. Clearing the composer afterwards
SHALL NOT bring it back; the next fresh payload SHALL. Local dismissal SHALL
NOT modify session metadata.

#### Scenario: Typing
- **WHEN** ghost text is visible and the user types "a"
- **THEN** the composer contains "a" and no ghost text, and deleting "a" shows no ghost text

#### Scenario: Escape
- **WHEN** ghost text is visible and the user presses Escape
- **THEN** the ghost text disappears and Escape performs no other composer action

### Requirement: Reply option chips

When a current payload has options, the composer's top row SHALL show one chip
per option and a dismiss control. Selecting a chip SHALL replace the composer
content with the option text and focus it without sending. The dismiss control
SHALL remove `suggestion` and `options` from the session metadata. Chips
SHALL be available on every layout, including touch.

#### Scenario: Chip click
- **WHEN** the user clicks the second chip
- **THEN** the composer contains that option and nothing was sent

#### Scenario: Dismiss everywhere
- **WHEN** the user presses the dismiss control
- **THEN** the options disappear in this and every other client showing the session

### Requirement: Accessibility and i18n

Ghost text SHALL be exposed to assistive technology as a hint, not as composer
content, and all new labels SHALL use i18n keys for every shipped locale.

#### Scenario: Screen reader
- **WHEN** ghost text is visible
- **THEN** the composer's accessible value is empty and its description names the suggestion and the accept key
