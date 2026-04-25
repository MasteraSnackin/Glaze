import { beforeEach, describe, expect, it, vi } from 'vitest';

const embeddingRecords = new Map();
const mockGetEmbeddings = vi.fn();
const mockExecuteRequest = vi.fn(async ({ callbacks }) => {
    callbacks?.onComplete?.('ok', null);
});

vi.mock('@/core/services/embeddingService.js', () => ({
    getEmbeddings: (...args) => mockGetEmbeddings(...args)
}));

vi.mock('@/utils/db.js', () => ({
    db: {
        get: vi.fn(async () => null),
        getChat: vi.fn(async () => ({ currentId: 'chat-1', sessions: { 'chat-1': [] }, memoryBooks: {} })),
        queuedSet: vi.fn(async () => undefined),
        getEmbedding: vi.fn(async (id) => embeddingRecords.get(id) || null),
        getEmbeddingsBySource: vi.fn(async (sourceType) => Array.from(embeddingRecords.values()).filter(v => v.sourceType === sourceType)),
        saveEmbedding: vi.fn(async (record) => {
            embeddingRecords.set(record.id, record);
        }),
        deleteEmbedding: vi.fn(async (id) => {
            embeddingRecords.delete(id);
        })
    }
}));

vi.mock('@/core/llm/transport/requestOrchestrator.js', () => ({
    executeRequest: (...args) => mockExecuteRequest(...args)
}));

vi.mock('@/core/services/notificationService.js', () => ({
    sendMessageNotification: vi.fn()
}));

vi.mock('@/core/states/bottomSheetState.js', () => ({
    showBottomSheet: vi.fn(),
    closeBottomSheet: vi.fn()
}));

class MockWorker {
    constructor() {
        this.onmessage = null;
        this.onerror = null;
    }

    postMessage(message) {
        const data = {
            messages: [
                { role: 'system', content: 'Base prompt block' },
                { role: 'user', content: 'Current user message', isHistory: true }
            ],
            loreEntries: [],
            staticTokens: 8,
            contextBreakdown: { lorebook: 0 },
            needsVarsSave: false,
            sessionVars: {}
        };

        queueMicrotask(() => {
            this.onmessage?.({ data: { id: message.id, success: true, data } });
        });
    }

    terminate() {}
}

globalThis.Worker = MockWorker;

const localStorageData = new Map();
globalThis.localStorage = {
    getItem(key) {
        return localStorageData.has(key) ? localStorageData.get(key) : null;
    },
    setItem(key, value) {
        localStorageData.set(key, String(value));
    },
    removeItem(key) {
        localStorageData.delete(key);
    },
    clear() {
        localStorageData.clear();
    }
};

if (!globalThis.crypto?.subtle) {
    const { webcrypto } = await import('node:crypto');
    Object.defineProperty(globalThis, 'crypto', {
        value: webcrypto,
        configurable: true
    });
}

const { lorebookState, indexLorebookEntries, vectorSearchLorebooks } = await import('../../states/lorebookState.js');
const { generateChatResponse } = await import('../generationService.js');
const { getLastRequestPreviewSnapshot } = await import('../../states/requestPreviewState.js');

describe('Vector lorebook E2E verification', () => {
    beforeEach(() => {
        embeddingRecords.clear();
        localStorage.clear();
        mockGetEmbeddings.mockReset();
        mockExecuteRequest.mockClear();
        globalThis._genWorker = null;
        globalThis._workerQueue = new Map();
        globalThis._msgIdCounter = 0;

        localStorage.setItem('gz_embedding_enabled', 'true');
        localStorage.setItem('gz_embedding_use_same', 'false');
        localStorage.setItem('gz_embedding_endpoint', 'http://127.0.0.1:11434/v1');
        localStorage.setItem('gz_embedding_model', 'test-embedding-model');
        localStorage.setItem('gz_embedding_target', 'content');
        localStorage.setItem('gz_embedding_scan_depth', '5');
        localStorage.setItem('gz_embedding_threshold', '0.6');
        localStorage.setItem('gz_embedding_top_k', '5');
        localStorage.setItem('gz_lorebook_search_type', 'both');

        localStorage.setItem('api-endpoint', 'http://127.0.0.1:1234/v1');
        localStorage.setItem('gz_api_endpoint_normalized', 'http://127.0.0.1:1234/v1');
        localStorage.setItem('api-model', 'test-llm');
        localStorage.setItem('api-max-tokens', '256');
        localStorage.setItem('api-context', '4096');
        localStorage.setItem('gz_api_stream', 'false');
        localStorage.setItem('gz_api_temp', '0.7');
        localStorage.setItem('gz_api_topp', '0.9');

        lorebookState.lorebooks = [
            {
                id: 'lb-vector',
                name: 'Vector QA',
                enabled: true,
                entries: [
                    {
                        id: 'entry-vector-only',
                        comment: 'Asei Vector QA',
                        keys: ['Asei'],
                        content: 'Asei has bright blue hair, cat ears, a fluffy tail, and heterochromia.',
                        enabled: true,
                        vectorSearch: true,
                        position: 'worldInfoBefore'
                    }
                ]
            }
        ];
        lorebookState.globalSettings.searchType = 'both';
        lorebookState.globalSettings.vectorThreshold = 0.6;
        lorebookState.globalSettings.vectorTopK = 5;
    });

    it('indexes a vector-only entry and matches it semantically', async () => {
        mockGetEmbeddings.mockImplementation(async (texts) => texts.map((text) => [{
            text,
            vector: text.includes('bright blue hair') ? [1, 0, 0] : [0.98, 0.02, 0]
        }]));

        const result = await indexLorebookEntries('lb-vector');
        expect(result.failed).toBe(0);
        expect(result.indexed).toBe(1);

        const matches = await vectorSearchLorebooks([], 'blue-haired catgirl with a fluffy tail', { id: 'char-1' }, 'chat-1');
        expect(matches).toHaveLength(1);
        expect(matches[0].id).toBe('entry-vector-only');
        expect(matches[0].comment).toBe('Asei Vector QA');
    });

    it('injects a vector-only entry into triggered lorebooks and final prompt', async () => {
        mockGetEmbeddings.mockImplementation(async (texts) => texts.map((text) => [{
            text,
            vector: text.includes('bright blue hair') ? [1, 0, 0] : [0.98, 0.02, 0]
        }]));

        await indexLorebookEntries('lb-vector');

        let promptReadyPayload = null;
        await generateChatResponse({
            text: 'I am looking for the blue-haired catgirl with a fluffy tail.',
            char: { id: 'char-1', name: 'Tester', sessionId: 'chat-1' },
            history: [{ role: 'user', content: 'Tell me about the blue-haired catgirl.' }],
            authorsNote: null,
            summary: '',
            controller: { signal: { aborted: false } },
            callbacks: {
                onUpdate: vi.fn(),
                onComplete: vi.fn(),
                onError: vi.fn(),
                onPromptReady: (payload) => {
                    promptReadyPayload = payload;
                }
            }
        });

        expect(promptReadyPayload).toBeTruthy();
        expect(promptReadyPayload.loreEntries.some(entry => entry.id === 'entry-vector-only')).toBe(true);

        const lastPrompt = getLastRequestPreviewSnapshot().prompt;
        expect(lastPrompt).toBeTruthy();
        expect(lastPrompt.messages.some(message =>
            typeof message.content === 'string' && message.content.includes('bright blue hair, cat ears, a fluffy tail')
        )).toBe(true);
        expect(mockExecuteRequest).toHaveBeenCalledOnce();
    });

    it('places late vector lore after char card when target is worldInfoAfter', async () => {
        mockGetEmbeddings.mockImplementation(async (texts) => texts.map((text) => [{
            text,
            vector: text.includes('bright blue hair') ? [1, 0, 0] : [0.98, 0.02, 0]
        }]));

        lorebookState.lorebooks = [{
            id: 'lb-vector-after',
            name: 'Vector After',
            enabled: true,
            entries: [{
                id: 'entry-vector-after',
                comment: 'Asei After',
                keys: ['Asei'],
                content: 'After block lore',
                enabled: true,
                vectorSearch: true,
                position: 'worldInfoAfter'
            }]
        }];

        await indexLorebookEntries('lb-vector-after');

        globalThis._genWorker = null;
        globalThis.Worker = class extends MockWorker {
            postMessage(message) {
                const data = {
                    messages: [
                        { role: 'system', content: 'Character card', blockId: 'char_card' },
                        { role: 'system', content: 'Scenario block', blockId: 'scenario' },
                        { role: 'user', content: 'Current user message', isHistory: true }
                    ],
                    loreEntries: [],
                    staticTokens: 8,
                    contextBreakdown: { lorebook: 0 },
                    needsVarsSave: false,
                    sessionVars: {}
                };
                queueMicrotask(() => {
                    this.onmessage?.({ data: { id: message.id, success: true, data } });
                });
            }
        };

        await generateChatResponse({
            text: 'I am looking for the blue-haired catgirl with a fluffy tail.',
            char: { id: 'char-1', name: 'Tester', sessionId: 'chat-1' },
            history: [{ role: 'user', content: 'Tell me about the blue-haired catgirl.' }],
            authorsNote: null,
            summary: '',
            controller: { signal: { aborted: false } },
            callbacks: {
                onUpdate: vi.fn(),
                onComplete: vi.fn(),
                onError: vi.fn(),
                onPromptReady: vi.fn()
            }
        });

        const lastPrompt = getLastRequestPreviewSnapshot().prompt;
        expect(lastPrompt).toBeTruthy();
        const contents = lastPrompt.messages.map(message => message.content);
        expect(contents).toEqual([
            'Character card',
            'Scenario block',
            'After block lore',
            'Current user message'
        ]);

        globalThis._genWorker = null;
        globalThis.Worker = MockWorker;
    });

    it('only injects lorebook macro entries into {{lorebooks}} blocks', async () => {
        mockGetEmbeddings.mockImplementation(async (texts) => texts.map((text) => [{
            text,
            vector: [0.95, 0.05, 0]
        }]));

        lorebookState.globalSettings.searchType = 'keys';
        lorebookState.globalSettings.injectionPosition = 'worldInfoBefore';
        lorebookState.lorebooks = [{
            id: 'lb-macro',
            name: 'Macro split',
            enabled: true,
            entries: [
                {
                    id: 'entry-before',
                    comment: 'Before entry',
                    keys: ['topic'],
                    content: 'Before block lore',
                    enabled: true,
                    position: 'worldInfoBefore'
                },
                {
                    id: 'entry-macro',
                    comment: 'Macro entry',
                    keys: ['topic'],
                    content: 'Macro block lore',
                    enabled: true,
                    position: 'lorebooksMacro'
                }
            ]
        }];

        const customWorkerData = {
            messages: [
                { role: 'system', content: 'Header' },
                { role: 'system', content: 'Lore slot: Macro block lore' },
                { role: 'system', content: 'Before block lore' },
                { role: 'user', content: 'Current user message', isHistory: true }
            ],
            loreEntries: [
                { id: 'entry-before', content: 'Before block lore', position: 'worldInfoBefore' },
                { id: 'entry-macro', content: 'Macro block lore', position: 'lorebooksMacro' }
            ],
            staticTokens: 12,
            contextBreakdown: { lorebook: 2 },
            needsVarsSave: false,
            sessionVars: {}
        };

        globalThis._genWorker = null;
        globalThis.Worker = class extends MockWorker {
            postMessage(message) {
                queueMicrotask(() => {
                    this.onmessage?.({ data: { id: message.id, success: true, data: customWorkerData } });
                });
            }
        };

        await generateChatResponse({
            text: 'topic',
            char: { id: 'char-1', name: 'Tester', sessionId: 'chat-1' },
            history: [{ role: 'user', content: 'topic' }],
            authorsNote: null,
            summary: '',
            controller: { signal: { aborted: false } },
            callbacks: {
                onUpdate: vi.fn(),
                onComplete: vi.fn(),
                onError: vi.fn(),
                onPromptReady: vi.fn()
            }
        });

        const lastPrompt = getLastRequestPreviewSnapshot().prompt;
        expect(lastPrompt).toBeTruthy();
        expect(lastPrompt.messages.some(message => message.content === 'Lore slot: Macro block lore')).toBe(true);
        expect(lastPrompt.messages.some(message => message.content === 'Lore slot: Before block lore\n\nMacro block lore')).toBe(false);

        globalThis._genWorker = null;
        globalThis.Worker = MockWorker;
    });

    it('respects maxInjectedEntries when vector-only results are added late', async () => {
        mockGetEmbeddings.mockImplementation(async (texts) => texts.map((text) => [{
            text,
            vector: text.includes('Vector extra lore') ? [1, 0, 0] : [0.98, 0.02, 0]
        }]));

        lorebookState.globalSettings.searchType = 'both';
        lorebookState.globalSettings.maxInjectedEntries = 1;
        lorebookState.lorebooks = [{
            id: 'lb-mixed-limit',
            name: 'Mixed limit',
            enabled: true,
            entries: [
                {
                    id: 'entry-keyword',
                    comment: 'Keyword entry',
                    keys: ['topic'],
                    content: 'Keyword lore',
                    enabled: true,
                    position: 'worldInfoBefore'
                },
                {
                    id: 'entry-vector-only',
                    comment: 'Vector only entry',
                    keys: ['vector'],
                    content: 'Vector extra lore',
                    enabled: true,
                    vectorSearch: true,
                    useKeywordSearch: false,
                    position: 'worldInfoBefore'
                }
            ]
        }];

        await indexLorebookEntries('lb-mixed-limit');

        globalThis._genWorker = null;
        globalThis.Worker = class extends MockWorker {
            postMessage(message) {
                const data = {
                    messages: [
                        { role: 'system', content: 'Keyword lore' },
                        { role: 'user', content: 'Current user message', isHistory: true }
                    ],
                    loreEntries: [
                        { id: 'entry-keyword', comment: 'Keyword entry', content: 'Keyword lore', position: 'worldInfoBefore', _source: 'keyword' }
                    ],
                    staticTokens: 8,
                    contextBreakdown: { lorebook: 2 },
                    needsVarsSave: false,
                    sessionVars: {}
                };
                queueMicrotask(() => {
                    this.onmessage?.({ data: { id: message.id, success: true, data } });
                });
            }
        };

        let promptReadyPayload = null;
        await generateChatResponse({
            text: 'topic and vector extra lore',
            char: { id: 'char-1', name: 'Tester', sessionId: 'chat-1' },
            history: [{ role: 'user', content: 'topic and vector extra lore' }],
            authorsNote: null,
            summary: '',
            controller: { signal: { aborted: false } },
            callbacks: {
                onUpdate: vi.fn(),
                onComplete: vi.fn(),
                onError: vi.fn(),
                onPromptReady: (payload) => {
                    promptReadyPayload = payload;
                }
            }
        });

        expect(promptReadyPayload).toBeTruthy();
        expect(promptReadyPayload.loreEntries.map(entry => entry.id)).toEqual(['entry-keyword']);

        const lastPrompt = getLastRequestPreviewSnapshot().prompt;
        expect(lastPrompt).toBeTruthy();
        expect(lastPrompt.messages.some(message => typeof message.content === 'string' && message.content.includes('Vector extra lore'))).toBe(false);

        lorebookState.globalSettings.maxInjectedEntries = 5;
        globalThis._genWorker = null;
        globalThis.Worker = MockWorker;
    });

    it('fails generation with a visible error when embedding retrieval crashes', async () => {
        mockGetEmbeddings.mockImplementation(async (texts) => texts.map((text) => {
            if (text.includes('bright blue hair')) {
                return [{ text, vector: [1, 0, 0] }];
            }
            throw new Error('Embedding API Error: 503');
        }));

        await indexLorebookEntries('lb-vector');

        const onError = vi.fn();

        await generateChatResponse({
            text: 'Tell me about the blue-haired catgirl.',
            char: { id: 'char-1', name: 'Tester', sessionId: 'chat-1' },
            history: [{ role: 'user', content: 'Tell me about the blue-haired catgirl.' }],
            authorsNote: null,
            summary: '',
            controller: { signal: { aborted: false } },
            callbacks: {
                onUpdate: vi.fn(),
                onComplete: vi.fn(),
                onError,
                onPromptReady: vi.fn()
            }
        });

        expect(onError).toHaveBeenCalledOnce();
        expect(mockExecuteRequest).not.toHaveBeenCalled();
    });
});
