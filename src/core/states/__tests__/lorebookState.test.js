import { describe, it, expect, beforeEach, vi } from 'vitest';
import { scanLorebooks, lorebookState } from '../lorebookState.js';

// Mock DB
vi.mock('@/utils/db.js', () => ({
    db: {
        get: vi.fn(),
        set: vi.fn()
    }
}));

describe('Lorebook Logic', () => {
    beforeEach(() => {
        lorebookState.lorebooks = [];
        lorebookState.globalSettings.maxInjectedEntries = 5;
    });

    it('matches basic primary keys', () => {
        const lb = {
            id: 'lb1', enabled: true, name: 'Basic',
            entries: [{
                id: 'e1', keys: ['foo'], content: 'Bar', enabled: true
            }]
        };
        lorebookState.lorebooks = [lb];

        // Match
        const res = scanLorebooks([], { name: 'Char' }, 'foo is here');
        expect(res).toHaveLength(1);
        expect(res[0].id).toBe('e1');

        // No Match
        const res2 = scanLorebooks([], { name: 'Char' }, 'baz is here');
        expect(res2).toHaveLength(0);
    });

    it('respects sticky logic', () => {
        const lb = {
            id: 'lb1', enabled: true, name: 'Sticky',
            entries: [{
                id: 'e1', keys: ['trigger'], content: 'Sticky Content', enabled: true, sticky: 2
            }]
        };
        lorebookState.lorebooks = [lb];

        // 1. Initial Trigger
        const res1 = scanLorebooks([], null, 'trigger me');
        expect(res1).toHaveLength(1);

        // 2. Next message (no key), should still trigger because sticky=2
        // History: [User: trigger me]
        const history = [{ role: 'user', content: 'trigger me' }];
        const res2 = scanLorebooks(history, null, 'nothing here');
        expect(res2).toHaveLength(1, 'Should match due to sticky');

        // 3. Third message (Sticky expired if logic counts 2 messages including trigger? Or 2 AFTER?)
        // Implementation: loop 1..sticky. 
        // history now: [trigger me, nothing here]
        // scan back 1: nothing here (no match)
        // scan back 2: trigger me (match!) -> Sticky Active
        const history2 = [{ role: 'user', content: 'trigger me' }, { role: 'user', content: 'nothing here' }];
        const res3 = scanLorebooks(history2, null, 'still nothing');
        expect(res3).toHaveLength(1, 'Should still match (sticky=2, checking history[-2])');

        // 4. Fourth message - should expire
        const history3 = [
            { role: 'user', content: 'trigger me' },
            { role: 'user', content: 'nothing here' },
            { role: 'user', content: 'still nothing' }
        ];
        // checking back 1..2. history[-1] = still nothing, history[-2] = nothing here. No match.
        const res4 = scanLorebooks(history3, null, 'end');
        expect(res4).toHaveLength(0, 'Should expire sticky');
    });

    it('respects cooldown logic', () => {
        const lb = {
            id: 'lb1', enabled: true, name: 'Cooldown',
            entries: [{
                id: 'e1', keys: ['cold'], content: 'Ice', enabled: true, cooldown: 1
            }]
        };
        lorebookState.lorebooks = [lb];

        // 1. Trigger
        const res1 = scanLorebooks([], null, 'cold');
        expect(res1).toHaveLength(1);

        // 2. Next message with key - should be blocked by cooldown
        const history = [{ role: 'user', content: 'cold' }];
        const res2 = scanLorebooks(history, null, 'cold again');
        expect(res2).toHaveLength(0, 'Should be blocked by cooldown');

        // 3. Third message - cooldown expires ONLY if the key wasn't present in the cooldown window
        // Current implementation is stateless "Anti-Frequency".
        // To verify it triggers again, we need a gap where keys are effectively absent or ignored, 
        // but since we scan raw text, we must ensure history[-1] does NOT have keys if we want to trigger.

        // Scenario A: Spamming keys -> Blocked by Anti-Frequency
        const historySpam = [{ role: 'user', content: 'cold' }, { role: 'user', content: 'cold again' }];
        const res3 = scanLorebooks(historySpam, null, 'cold yet again');
        expect(res3).toHaveLength(0, 'Should be blocked because key was in history[-1]');

        // Scenario B: Clean gap -> Trigger
        const historyClean = [{ role: 'user', content: 'cold' }, { role: 'user', content: 'something else' }];
        const res4 = scanLorebooks(historyClean, null, 'cold yet again');
        expect(res4).toHaveLength(1, 'Cooldown should expire after clean gap');
    });

    it('logical operators (AND/NOT)', () => {
        const lb = {
            id: 'lb1', enabled: true,
            entries: [
                { id: 'and', keys: ['A'], secondary_keys: ['B'], selectiveLogic: 0, content: 'AND', enabled: true },
                { id: 'not', keys: ['A'], secondary_keys: ['B'], selectiveLogic: 2, content: 'NOT', enabled: true } // 2 = NOT Any
            ]
        };
        lorebookState.lorebooks = [lb];

        // Only A -> NOT triggers
        const res1 = scanLorebooks([], null, 'Just A');
        expect(res1.find(e => e.id === 'not')).toBeTruthy();
        expect(res1.find(e => e.id === 'and')).toBeFalsy();

        // A and B -> AND triggers
        const res2 = scanLorebooks([], null, 'A and B');
        expect(res2.find(e => e.id === 'and')).toBeTruthy();
        expect(res2.find(e => e.id === 'not')).toBeFalsy();
    });

    it('scan depth', () => {
        const lb = {
            id: 'lb1', enabled: true,
            entries: [{
                id: 'deep', keys: ['deep'], content: 'Abyss', enabled: true, scanDepth: 2
            }]
        };
        lorebookState.lorebooks = [lb];

        // Key is 3 messages back (index -3)
        // history length 3. slice(-2) gets last 2. key ignored.
        const history = [
            { role: 'user', content: 'deep' },
            { role: 'user', content: 'msg' },
            { role: 'user', content: 'msg' }
        ];

        const res = scanLorebooks(history, null, 'current');
        expect(res).toHaveLength(0);

        // Key is 2 messages back
        const history2 = [
            { role: 'user', content: 'msg' },
            { role: 'user', content: 'deep' },
            { role: 'user', content: 'msg' }
        ];
        const res2 = scanLorebooks(history2, null, 'current');
        expect(res2).toHaveLength(1);
    });

    it('respects max injected lorebook entries', () => {
        lorebookState.globalSettings.maxInjectedEntries = 2;
        lorebookState.lorebooks = [{
            id: 'lb1', enabled: true, name: 'Limited',
            entries: [
                { id: 'e1', keys: ['topic'], content: 'One', enabled: true, order: 10 },
                { id: 'e2', keys: ['topic'], content: 'Two', enabled: true, order: 20 },
                { id: 'e3', keys: ['topic'], content: 'Three', enabled: true, order: 30 }
            ]
        }];

        const res = scanLorebooks([], null, 'topic appears here');
        expect(res).toHaveLength(2);
        expect(res.map(entry => entry.id)).toEqual(['e1', 'e2']);
    });
});
