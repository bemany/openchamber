/**
 * Ghost text: a suggested message drawn greyed out in the empty composer.
 *
 * The text is a widget, never part of the document, so `getValue()` stays
 * empty and nothing can send it by accident. The caller decides what to show
 * and when (`setGhostText`); the widget itself appears only while the
 * document is empty, so the first typed character hides it before the caller
 * has even re-rendered.
 */

import { StateEffect, StateField, type EditorState, type Extension } from '@codemirror/state';
import { Decoration, EditorView, WidgetType } from '@codemirror/view';

export interface ComposerGhostText {
    text: string;
    /** The accept key's label, drawn after the text. */
    hint: string;
    /** What assistive technology hears instead: the text and the accept key. */
    description: string;
}

export const setGhostText = StateEffect.define<ComposerGhostText | null>();

class GhostTextWidget extends WidgetType {
    constructor(private readonly ghost: ComposerGhostText) {
        super();
    }

    eq(other: GhostTextWidget): boolean {
        return other.ghost.text === this.ghost.text && other.ghost.hint === this.ghost.hint;
    }

    toDOM(): HTMLElement {
        // Hidden from assistive technology: the editor's `aria-description`
        // names the suggestion, and the accessible value stays empty.
        const root = document.createElement('span');
        root.className = 'cm-ghostText';
        root.setAttribute('aria-hidden', 'true');
        root.textContent = this.ghost.text;
        const hint = document.createElement('kbd');
        hint.className = 'cm-ghostText-hint';
        hint.textContent = this.ghost.hint;
        root.append(hint);
        return root;
    }
}

const ghostTextField = StateField.define<ComposerGhostText | null>({
    create: () => null,
    update(value, transaction) {
        for (const effect of transaction.effects) {
            if (effect.is(setGhostText)) return effect.value;
        }
        return value;
    },
});

const showsGhostText = (state: EditorState): ComposerGhostText | null => {
    const ghost = state.field(ghostTextField);
    return ghost && state.doc.length === 0 ? ghost : null;
};

const ghostTextDecorations = EditorView.decorations.compute([ghostTextField, 'doc'], (state) => {
    const ghost = showsGhostText(state);
    if (!ghost) return Decoration.none;
    // `side: 1` keeps the caret in front of the text, where typing starts.
    return Decoration.set([Decoration.widget({ widget: new GhostTextWidget(ghost), side: 1 }).range(0)]);
});

const ghostTextTheme = EditorView.baseTheme({
    // The placeholder's colour: the composer shows one or the other.
    // No pointer events: a click lands on the line and places the caret.
    '.cm-ghostText': {
        color: 'var(--surface-muted-foreground)',
        pointerEvents: 'none',
    },
    '.cm-ghostText-hint': {
        marginInlineStart: '0.5em',
        padding: '0 0.35em',
        border: '1px solid var(--interactive-border)',
        borderRadius: '4px',
        fontFamily: 'inherit',
        fontSize: '0.8em',
        whiteSpace: 'nowrap',
    },
});

export const composerGhostText: Extension = [ghostTextField, ghostTextDecorations, ghostTextTheme];
