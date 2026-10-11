import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { Window } from 'happy-dom';
import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';

import { TooltipProvider } from '@/components/ui/tooltip';
import { I18nProvider } from '@/lib/i18n';
import { SessionSuggestionChip } from './SessionSuggestionChip';

describe('SessionSuggestionChip', () => {
  let windowInstance: Window;
  let host: HTMLDivElement;
  let root: Root;
  let applied: string[];

  beforeEach(() => {
    windowInstance = new Window();
    Object.assign(globalThis, {
      window: windowInstance,
      document: windowInstance.document,
      HTMLElement: windowInstance.HTMLElement,
      Element: windowInstance.Element,
      Node: windowInstance.Node,
      IS_REACT_ACT_ENVIRONMENT: true,
    });
    host = document.createElement('div');
    document.body.append(host);
    root = createRoot(host);
    applied = [];
  });

  afterEach(async () => {
    await act(async () => root.unmount());
    await windowInstance.happyDOM.close();
  });

  const render = async ({ suggestion = null, options = [], hidden = false, showContinuation = false }: {
    suggestion?: string | null;
    options?: string[];
    hidden?: boolean;
    showContinuation?: boolean;
  }) => {
    await act(async () => {
      root.render(
        <I18nProvider>
          <TooltipProvider>
            <SessionSuggestionChip
              sessionId="ses_1"
              suggestion={suggestion}
              options={options}
              hidden={hidden}
              showContinuation={showContinuation}
              onApply={(text) => applied.push(text)}
            />
          </TooltipProvider>
        </I18nProvider>,
      );
    });
  };

  const buttonLabels = () => [...host.querySelectorAll('button')].map((button) => button.textContent || button.getAttribute('aria-label'));

  test('a chip fills the composer with its option and sends nothing', async () => {
    await render({ options: ['Yes, merge it', 'No, wait'] });
    expect(buttonLabels()).toEqual(['Yes, merge it', 'No, wait', 'Dismiss suggestion']);

    await act(async () => host.querySelectorAll('button')[1]?.click());
    expect(applied).toEqual(['No, wait']);
  });

  test('chips show on every layout, the continuation row only where asked', async () => {
    await render({ suggestion: 'Continue with the footer', showContinuation: false });
    expect(host.innerHTML).toBe('');

    await render({ suggestion: 'Continue with the footer', showContinuation: true });
    expect(host.textContent).toContain('Continue with the footer');

    await render({ options: ['Yes', 'No'], showContinuation: true });
    expect(buttonLabels()).toEqual(['Yes', 'No', 'Dismiss suggestion']);
  });

  test('content in the composer hides everything', async () => {
    await render({ suggestion: 'Continue', options: ['Yes', 'No'], hidden: true, showContinuation: true });
    expect(host.innerHTML).toBe('');
  });
});
