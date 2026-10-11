import { describe, expect, it } from 'vitest';
import { buildAssistPrompt, buildAssistSystemPrompt } from './prompt.js';

const turn = { complete: true, user: { text: 'Fix the header', authored: 'Fix the header' }, assistant: { text: 'Fixed. Shall I merge?' } };

describe('session assist prompt', () => {
  it('asks for reply options with the three outcomes only when the suggestion is requested', () => {
    const both = buildAssistSystemPrompt({ recap: true, suggestion: true });
    expect(both).toContain('"options" (array of strings)');
    expect(both).toContain('Pick exactly one outcome');
    expect(both).toContain('at most 80 characters');
    expect(both).toContain('reports the work as done');

    const recapOnly = buildAssistSystemPrompt({ recap: true, suggestion: false });
    expect(recapOnly).toContain('"recap" (string)');
    expect(recapOnly).not.toContain('options');
    expect(recapOnly).not.toContain('suggestion');
  });

  it('names the options in the closing request of the user prompt', () => {
    expect(buildAssistPrompt([turn], { recap: false, suggestion: true }, 10_000).text)
      .toMatch(/reply options in options\.$/);
    expect(buildAssistPrompt([turn], { recap: true, suggestion: false }, 10_000).text)
      .not.toContain('options');
  });
});
