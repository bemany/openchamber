import { describe, expect, test } from 'bun:test';

import {
    ghostTextKeyAction,
    visibleGhostText,
    withGhostTextDismissed,
    type GhostTextDismissals,
    type GhostTextInput,
} from '../ghostText';

const NONE: GhostTextDismissals = new Map();

const input = (overrides: Partial<GhostTextInput> = {}): GhostTextInput => ({
    candidate: 'Run the tests',
    payloadKey: 'msg_1:100',
    sessionId: 'ses_a',
    hasKeyboardLayout: true,
    composerText: '',
    suggestionHidden: false,
    inputMode: 'normal',
    dismissals: NONE,
    ...overrides,
});

const key = (name: string, modifiers: Partial<Record<'shiftKey' | 'altKey' | 'ctrlKey' | 'metaKey', boolean>> = {}) => ({
    key: name, shiftKey: false, altKey: false, ctrlKey: false, metaKey: false, ...modifiers,
});
const visible = { visible: true, autocompleteOpen: false };

describe('when ghost text shows', () => {
    test('in an empty composer on a keyboard layout', () => {
        expect(visibleGhostText(input())).toBe('Run the tests');
    });

    test('never on a phone or touch tablet, with content, or under the row hiding rules', () => {
        expect(visibleGhostText(input({ hasKeyboardLayout: false }))).toBeNull();
        expect(visibleGhostText(input({ composerText: ' ' }))).toBeNull();
        // BTW, a draft, a queue and a pending form all hide the row.
        expect(visibleGhostText(input({ suggestionHidden: true }))).toBeNull();
        expect(visibleGhostText(input({ inputMode: 'shell' }))).toBeNull();
        expect(visibleGhostText(input({ candidate: null }))).toBeNull();
        expect(visibleGhostText(input({ sessionId: null }))).toBeNull();
    });
});

describe('used-up payloads', () => {
    test('taking or typing over it and then clearing the composer does not bring it back', () => {
        const dismissals = withGhostTextDismissed(NONE, 'ses_a', 'msg_1:100');
        expect(visibleGhostText(input({ composerText: 'Run the tests', dismissals }))).toBeNull();
        expect(visibleGhostText(input({ composerText: '', dismissals }))).toBeNull();
    });

    test('a fresh payload for the same session shows again', () => {
        const dismissals = withGhostTextDismissed(NONE, 'ses_a', 'msg_1:100');
        expect(visibleGhostText(input({ payloadKey: 'msg_2:200', dismissals }))).toBe('Run the tests');
    });

    test('switching sessions and coming back keeps each session apart', () => {
        const dismissals = withGhostTextDismissed(NONE, 'ses_a', 'msg_1:100');
        expect(visibleGhostText(input({ sessionId: 'ses_b', payloadKey: 'msg_9:900', dismissals }))).toBe('Run the tests');
        expect(visibleGhostText(input({ dismissals }))).toBeNull();
    });

    test('keeps one entry per session and a bounded number of sessions', () => {
        let dismissals = withGhostTextDismissed(NONE, 'ses_a', 'msg_1:100');
        dismissals = withGhostTextDismissed(dismissals, 'ses_a', 'msg_2:200');
        expect([...dismissals]).toEqual([['ses_a', 'msg_2:200']]);
        for (let i = 0; i < 80; i += 1) dismissals = withGhostTextDismissed(dismissals, `ses_${i}`, 'msg:1');
        expect(dismissals.size).toBe(50);
        expect(dismissals.has('ses_a')).toBe(false);
        expect(dismissals.has('ses_79')).toBe(true);
    });

    test('dismissing the same payload twice keeps the same state', () => {
        const dismissals = withGhostTextDismissed(NONE, 'ses_a', 'msg_1:100');
        expect(withGhostTextDismissed(dismissals, 'ses_a', 'msg_1:100')).toBe(dismissals);
    });
});

describe('ghost text keys', () => {
    test('plain Tab accepts it instead of cycling the agent; Escape dismisses it', () => {
        expect(ghostTextKeyAction(key('Tab'), visible)).toBe('accept');
        expect(ghostTextKeyAction(key('Escape'), visible)).toBe('dismiss');
    });

    test('Tab and Escape keep their usual meaning without visible ghost text', () => {
        // Agent cycling, closing the expanded composer, leaving BTW or shell mode.
        expect(ghostTextKeyAction(key('Tab'), { visible: false, autocompleteOpen: false })).toBeNull();
        expect(ghostTextKeyAction(key('Escape'), { visible: false, autocompleteOpen: false })).toBeNull();
    });

    test('an open picker keeps Tab and Escape', () => {
        expect(ghostTextKeyAction(key('Tab'), { visible: true, autocompleteOpen: true })).toBeNull();
        expect(ghostTextKeyAction(key('Escape'), { visible: true, autocompleteOpen: true })).toBeNull();
    });

    test('modified Tab keeps its own meaning', () => {
        expect(ghostTextKeyAction(key('Tab', { shiftKey: true }), visible)).toBeNull();
        expect(ghostTextKeyAction(key('Tab', { ctrlKey: true }), visible)).toBeNull();
        expect(ghostTextKeyAction(key('Tab', { altKey: true }), visible)).toBeNull();
    });

    test('a typed character dismisses and still types', () => {
        expect(ghostTextKeyAction(key('a'), visible)).toBe('dismiss-and-continue');
        expect(ghostTextKeyAction(key('!'), visible)).toBe('dismiss-and-continue');
        expect(ghostTextKeyAction(key('A', { shiftKey: true }), visible)).toBe('dismiss-and-continue');
    });

    test('shortcuts and navigation leave it alone', () => {
        expect(ghostTextKeyAction(key('v', { metaKey: true }), visible)).toBeNull();
        expect(ghostTextKeyAction(key('ArrowUp'), visible)).toBeNull();
        expect(ghostTextKeyAction(key('Enter'), visible)).toBeNull();
    });
});
