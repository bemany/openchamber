import { describe, expect, test } from 'bun:test';
import type { Session } from '@/lib/opencode/model';
import { getCurrentSessionAssist, withoutAssistSuggestions } from './sessionAssistMetadata';

// SAFETY: fixture carries only the fields getCurrentSessionAssist reads plus the required identity fields.
const session = (time: Session['time'], assist: Record<string, string | number | Array<string | number>>): Session => ({
  id: 'ses_1',
  projectID: 'prj',
  directory: '/repo',
  title: 't',
  cost: 0,
  tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
  time,
  metadata: { openchamber: { assist: { forMessageID: 'msg_1', recap: 'r', ...assist } } },
} as Session);

describe('getCurrentSessionAssist', () => {
  test('returns the assist generated after the last turn ended', () => {
    expect(getCurrentSessionAssist(session({ created: 1, updated: 200, idle: 100 }, { suggestion: 'Run the tests', generatedAt: 160 }))?.suggestion)
      .toBe('Run the tests');
  });

  test('a later turn retires it', () => {
    expect(getCurrentSessionAssist(session({ created: 1, updated: 300, idle: 300 }, { suggestion: 'Run the tests', generatedAt: 160 })))
      .toBeNull();
  });

  test('a recap alone is still an assist', () => {
    expect(getCurrentSessionAssist(session({ created: 1, updated: 200, idle: 100 }, { suggestion: '', generatedAt: 160 }))?.recap)
      .toBe('r');
  });

  test('a reverted session has no current assist', () => {
    // SAFETY: the fixture is a Session; only the optional revert field is added.
    const reverted = { ...session({ created: 1, updated: 200, idle: 100 }, { suggestion: 'Run the tests', generatedAt: 160 }), revert: { messageID: 'msg_1' } } as Session;
    expect(getCurrentSessionAssist(reverted)).toBeNull();
  });

  test('reads reply options and treats them as content', () => {
    const assist = getCurrentSessionAssist(session({ created: 1, updated: 200, idle: 100 }, {
      recap: '', suggestion: '', options: [' Yes, merge ', 'No', 'yes, merge', 'x'.repeat(81), 'Later', 'Never'], generatedAt: 160,
    }));
    expect(assist?.options).toEqual(['Yes, merge', 'No', 'Later']);
  });

  test('options retire with the turn like the suggestion', () => {
    expect(getCurrentSessionAssist(session({ created: 1, updated: 300, idle: 300 }, { options: ['Yes', 'No'], generatedAt: 160 })))
      .toBeNull();
  });

  test('a malformed or too small option set is no option set', () => {
    const malformed = getCurrentSessionAssist(session({ created: 1, updated: 200, idle: 100 }, { suggestion: 'Run the tests', options: ['Yes', 2, 'No'], generatedAt: 160 }));
    expect(malformed?.options).toEqual([]);
    expect(malformed?.suggestion).toBe('Run the tests');
    const single = getCurrentSessionAssist(session({ created: 1, updated: 200, idle: 100 }, { recap: '', options: ['Yes', 'YES'], generatedAt: 160 }));
    expect(single).toBeNull();
  });

  test('options win over a suggestion stored alongside them', () => {
    const assist = getCurrentSessionAssist(session({ created: 1, updated: 200, idle: 100 }, { suggestion: 'Merge it', options: ['Yes', 'No'], generatedAt: 160 }));
    expect(assist).toMatchObject({ suggestion: '', options: ['Yes', 'No'] });
  });
});

describe('withoutAssistSuggestions', () => {
  test('removes the suggestion and the options and keeps everything else', () => {
    const metadata = {
      pinned: true,
      openchamber: {
        work: { state: 'open' },
        assist: { recap: 'r', suggestion: 'Merge it', options: ['Yes', 'No'], forMessageID: 'msg_1', generatedAt: 160 },
      },
    };
    expect(withoutAssistSuggestions(metadata)).toEqual({
      pinned: true,
      openchamber: {
        work: { state: 'open' },
        assist: { recap: 'r', forMessageID: 'msg_1', generatedAt: 160 },
      },
    });
  });

  test('copes with metadata that has no assist yet', () => {
    expect(withoutAssistSuggestions({})).toEqual({ openchamber: { assist: {} } });
  });
});
