/**
 * When the composer shows ghost text, what the keys do to it, and which
 * payloads are already used up. `ChatInput` holds the state; the decisions
 * live here so they can be tested without mounting the composer.
 */

/** Per session, the payload (`forMessageID:generatedAt`) whose ghost text was dismissed or taken. */
export type GhostTextDismissals = ReadonlyMap<string, string>;

// One entry per session the composer has shown; the oldest go first.
const MAX_DISMISSALS = 50;

export interface GhostTextInput {
    /** The continuation suggestion, or else the first reply option. */
    candidate: string | null;
    payloadKey: string;
    sessionId: string | null;
    /** Desktop web, Electron, VS Code: a layout that assumes a hardware keyboard. */
    hasKeyboardLayout: boolean;
    composerText: string;
    /** The suggestion row's hiding rules: content, BTW, draft, queue, pending form. */
    suggestionHidden: boolean;
    inputMode: 'normal' | 'shell';
    dismissals: GhostTextDismissals;
}

export const visibleGhostText = (input: GhostTextInput): string | null => {
    if (!input.candidate || !input.sessionId || !input.payloadKey) return null;
    if (!input.hasKeyboardLayout || input.suggestionHidden || input.inputMode !== 'normal') return null;
    // Whitespace counts as content here: the ghost text needs an empty document.
    if (input.composerText.length > 0) return null;
    if (input.dismissals.get(input.sessionId) === input.payloadKey) return null;
    return input.candidate;
};

/**
 * The dismissals after the user acted on the session's current payload.
 * Taking the suggestion (Tab, a chip, the row) always uses it up, on every
 * layout, so a later switch to a keyboard layout does not offer it again.
 * Typing, pasting or Escape only retire ghost text that is actually showing.
 */
export const ghostTextDismissalsAfter = (
    dismissals: GhostTextDismissals,
    action: { kind: 'taken' | 'edited'; sessionId: string | null; payloadKey: string; ghostVisible: boolean },
): GhostTextDismissals => {
    if (!action.sessionId || !action.payloadKey) return dismissals;
    if (action.kind === 'edited' && !action.ghostVisible) return dismissals;
    return withGhostTextDismissed(dismissals, action.sessionId, action.payloadKey);
};

/** The dismissals with this payload used up; clearing the composer does not bring it back. */
export const withGhostTextDismissed = (
    dismissals: GhostTextDismissals,
    sessionId: string,
    payloadKey: string,
): GhostTextDismissals => {
    if (dismissals.get(sessionId) === payloadKey) return dismissals;
    const next = new Map(dismissals);
    next.delete(sessionId);
    next.set(sessionId, payloadKey);
    for (const oldest of next.keys()) {
        if (next.size <= MAX_DISMISSALS) break;
        next.delete(oldest);
    }
    return next;
};

interface GhostTextKey {
    key: string;
    shiftKey: boolean;
    altKey: boolean;
    ctrlKey: boolean;
    metaKey: boolean;
}

/**
 * What a key does to ghost text. Only visible ghost text with no picker open
 * takes keys: plain Tab accepts and Escape dismisses, both ahead of every other
 * composer branch (agent cycling, closing the expanded composer); a printable
 * character dismisses and then does what it always does. Everything else,
 * Shift+Tab included, leaves the ghost text alone, and `null` means the key
 * keeps its usual meaning.
 */
export const ghostTextKeyAction = (
    event: GhostTextKey,
    context: { visible: boolean; autocompleteOpen: boolean },
): 'accept' | 'dismiss' | 'dismiss-and-continue' | null => {
    if (!context.visible || context.autocompleteOpen) return null;
    const modified = event.altKey || event.ctrlKey || event.metaKey;
    if (event.key === 'Tab') return modified || event.shiftKey ? null : 'accept';
    if (event.key === 'Escape') return 'dismiss';
    if (event.key.length === 1 && !event.ctrlKey && !event.metaKey) return 'dismiss-and-continue';
    return null;
};

/**
 * Whether a key the ghost text took stops at the composer. Tab does, so no
 * window shortcut sees it. Escape keeps bubbling, already prevented: the
 * double-Escape stop (`useKeyboardShortcuts`) then counts it as an Escape the
 * composer spent on itself and disarms, instead of never seeing it and
 * keeping an earlier press armed.
 */
export const ghostTextKeyStopsAtComposer = (action: 'accept' | 'dismiss'): boolean => action === 'accept';
