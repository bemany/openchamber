import { afterEach, beforeEach, expect, test } from 'bun:test';
import { EditorView } from '@codemirror/view';
import { Window } from 'happy-dom';

import { composerGhostText, setGhostText } from '../ghostText';
import { createComposerInputRedirect } from '../inputRedirect';

// Typing or pasting with nothing focused reaches a composer that shows ghost
// text through the same paths as typing into it: a document change for the
// change handler, and a paste event for the paste handler. Both are where
// `ChatInput` uses up the payload.

let browser: Window;
let descriptors: Map<string, PropertyDescriptor | undefined>;
let views: EditorView[];

beforeEach(() => {
    browser = new Window({ url: 'http://localhost' });
    const globals = {
        window: browser, document: browser.document, navigator: browser.navigator,
        HTMLElement: browser.HTMLElement, Element: browser.Element, Node: browser.Node,
        MutationObserver: browser.MutationObserver, ResizeObserver: browser.ResizeObserver,
        Event: browser.Event, KeyboardEvent: browser.KeyboardEvent, ClipboardEvent: browser.ClipboardEvent,
        DataTransfer: browser.DataTransfer,
        requestAnimationFrame: browser.requestAnimationFrame.bind(browser),
        cancelAnimationFrame: browser.cancelAnimationFrame.bind(browser),
        getComputedStyle: browser.getComputedStyle.bind(browser),
    };
    descriptors = new Map(Object.keys(globals).map((name) => [name, Object.getOwnPropertyDescriptor(globalThis, name)]));
    for (const [name, value] of Object.entries(globals)) {
        Object.defineProperty(globalThis, name, { value, configurable: true, writable: true });
    }
    views = [];
});

afterEach(async () => {
    for (const view of views) view.destroy();
    for (const [name, descriptor] of descriptors) {
        if (descriptor) Object.defineProperty(globalThis, name, descriptor);
        else Reflect.deleteProperty(globalThis, name);
    }
    await browser.happyDOM.close();
});

const ghost = { text: 'Run the tests', hint: 'Tab', description: 'Suggestion: Run the tests. Press Tab to use it.' };

function mountComposerWithGhostText() {
    const root = document.createElement('div');
    root.dataset.chatColumn = 'main';
    const host = document.createElement('div');
    host.dataset.chatInput = 'true';
    root.append(host);
    document.body.append(root);
    const changes: string[] = [];
    const view = new EditorView({
        parent: host,
        extensions: [
            composerGhostText,
            EditorView.updateListener.of((update) => {
                if (update.docChanged) changes.push(update.state.doc.toString());
            }),
        ],
    });
    view.dispatch({ effects: setGhostText.of(ghost) });
    views.push(view);
    return { view, changes };
}

const ghostDrawn = (view: EditorView) => view.contentDOM.querySelector('.cm-ghostText') !== null;

test('a key typed with nothing focused hides the ghost text and reaches the change handler', () => {
    const { view, changes } = mountComposerWithGhostText();
    expect(ghostDrawn(view)).toBe(true);

    const event = new KeyboardEvent('keydown', { key: 'x', bubbles: true, cancelable: true });
    document.body.dispatchEvent(event);
    expect(createComposerInputRedirect().redirectKey(event)).toBe(true);

    expect(view.state.doc.toString()).toBe('x');
    expect(changes).toEqual(['x']);
    expect(ghostDrawn(view)).toBe(false);
});

test('a paste with nothing focused reaches the paste handler first', () => {
    const { view } = mountComposerWithGhostText();
    // Stands in for `ChatInput`'s paste handler, which uses up the payload
    // before it decides on a link, a file, or the large-paste choice.
    const pastes: string[] = [];
    view.contentDOM.addEventListener('paste', (event) => {
        pastes.push(event.clipboardData?.getData('text/plain') ?? '');
    });

    const data = new DataTransfer();
    data.setData('text/plain', 'a long log');
    const event = new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true });
    document.body.dispatchEvent(event);
    expect(createComposerInputRedirect().redirectPaste(event)).toBe(true);

    expect(pastes).toEqual(['a long log']);
});
