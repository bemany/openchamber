import { describe, expect, test } from 'bun:test';
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';

import { composerGhostText, setGhostText } from '../ghostText';

const ghost = { text: 'Run the tests', hint: 'Tab', description: 'Suggestion: Run the tests. Press Tab to use it.' };

/** Number of decorations the extension asks the view to draw. */
const drawn = (state: EditorState) => state.facet(EditorView.decorations)
    .map((source) => (source instanceof Function ? 0 : source.size))
    .reduce((sum, size) => sum + size, 0);

const withGhost = (doc = '') => EditorState.create({ doc, extensions: composerGhostText })
    .update({ effects: setGhostText.of(ghost) }).state;

describe('composer ghost text', () => {
    test('draws nothing until the caller sets ghost text', () => {
        expect(drawn(EditorState.create({ extensions: composerGhostText }))).toBe(0);
        expect(drawn(withGhost())).toBe(1);
    });

    test('is never part of the document', () => {
        expect(withGhost().doc.toString()).toBe('');
    });

    test('shows only while the document is empty', () => {
        expect(drawn(withGhost('draft'))).toBe(0);
        const typed = withGhost().update({ changes: { from: 0, insert: 'a' } }).state;
        expect(drawn(typed)).toBe(0);
    });

    test('clearing it hides it', () => {
        expect(drawn(withGhost().update({ effects: setGhostText.of(null) }).state)).toBe(0);
    });
});
