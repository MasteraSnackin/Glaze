import { getApiConfig, getApiRuntimeStorage } from '@/core/config/APISettings.js';
import { getEffectivePreset } from '@/core/states/presetState.js';
import { lorebookState } from '@/core/states/lorebookState.js';
import { getEffectivePersona } from '@/core/states/personaState.js';
import { db } from '@/utils/db.js';
import { estimateTokens } from '@/utils/tokenizer.js';

export function getEffectiveApiConfig() {
    const config = getApiConfig();
    const runtime = getApiRuntimeStorage();
    let { maxTokens, contextSize } = config;

    if (!contextSize) contextSize = runtime.contextSize || 32000;
    if (maxTokens === undefined || maxTokens === null) {
        maxTokens = runtime.maxTokens || 8000;
    }

    return { ...config, maxTokens, contextSize };
}

export function loadActivePreset(char, sessionId) {
    const charId = char?.id;
    const chatId = charId && sessionId ? `${charId}_${sessionId}` : null;
    return getEffectivePreset(charId, chatId);
}

function getWorker() {
    if (!globalThis._genWorker) {
        globalThis._genWorker = new Worker(new URL('../../../workers/generationWorker.js', import.meta.url), { type: 'module' });
        globalThis._workerQueue = new Map();
        globalThis._msgIdCounter = 0;

        globalThis._genWorker.onmessage = (e) => {
            const { id, success, data, error } = e.data;
            if (globalThis._workerQueue.has(id)) {
                if (success) globalThis._workerQueue.get(id).resolve(data);
                else globalThis._workerQueue.get(id).reject(new Error(error));
                globalThis._workerQueue.delete(id);
            }
        };

        globalThis._genWorker.onerror = (e) => {
            console.error('Generation worker crashed:', e);
            for (const [, { reject }] of globalThis._workerQueue) {
                reject(new Error('Worker crashed: ' + (e.message || 'Unknown error')));
            }
            globalThis._workerQueue.clear();
            globalThis._genWorker.terminate();
            globalThis._genWorker = null;
        };
    }
    return globalThis._genWorker;
}

export function processPromptAsync(payload) {
    const worker = getWorker();
    const WORKER_TIMEOUT = 30000;
    return new Promise((resolve, reject) => {
        const id = ++globalThis._msgIdCounter;

        const timer = setTimeout(() => {
            globalThis._workerQueue.delete(id);
            reject(new Error('Prompt building timed out (worker did not respond within 30s)'));
        }, WORKER_TIMEOUT);

        globalThis._workerQueue.set(id, {
            resolve: (data) => { clearTimeout(timer); resolve(data); },
            reject: (err) => { clearTimeout(timer); reject(err); }
        });
        worker.postMessage({ id, type: 'generateChatResponse', payload });
    });
}

export function getSafeContextLimit(contextSize, maxTokens) {
    return contextSize - maxTokens > 0 ? contextSize - maxTokens : 8000;
}

export function trimHistoryForContextWindow(history, safeContextLimit) {
    const isIOS = typeof navigator !== 'undefined' && /iPad|iPhone|iPod/.test(navigator.userAgent || '');
    const memoryLimitFactor = isIOS ? 15 : 5;
    const maxHistoryRetention = Math.max(100, Math.ceil(safeContextLimit / memoryLimitFactor));

    if (history && history.length > maxHistoryRetention) {
        return history.slice(-maxHistoryRetention);
    }

    return history;
}

export function loadSessionVars(char) {
    const charId = char?.id || 'default';
    const sessionId = char?.sessionId || 'current';
    const varsKey = `gz_vars_${charId}_${sessionId}`;
    let sessionVars = {};
    try { sessionVars = JSON.parse(localStorage.getItem(varsKey)) || {}; } catch (e) { }
    return { varsKey, sessionVars };
}

export function loadGlobalRegexes() {
    let globalRegexes = [];
    try { globalRegexes = JSON.parse(localStorage.getItem('regex_scripts')) || []; } catch (e) { }
    return globalRegexes;
}

export function getPromptWorkerOptions(char, activePreset) {
    return {
        mergePrompts: activePreset?.mergePrompts || false,
        mergeRole: activePreset?.mergeRole || 'system',
        noAssistant: activePreset?.noAssistant || false,
        userPrefix: activePreset?.userPrefix || '',
        charPrefix: activePreset?.charPrefix || '',
        squashRole: activePreset?.squashRole || 'assistant',
        personaObj: getEffectivePersona(char?.id, char?.sessionId) || { name: 'User', prompt: '' }
    };
}

export function buildPromptWorkerPayload({
    char,
    history,
    summary,
    activePreset,
    promptOptions,
    authorsNote,
    guidanceText,
    guidanceType,
    globalRegexes,
    sessionVars,
    apiConfig,
    memoryReserve = 0
}) {
    return JSON.parse(JSON.stringify({
        char,
        history,
        summary,
        activePreset,
        mergePrompts: promptOptions.mergePrompts,
        mergeRole: promptOptions.mergeRole,
        noAssistant: promptOptions.noAssistant,
        userPrefix: promptOptions.userPrefix,
        charPrefix: promptOptions.charPrefix,
        squashRole: promptOptions.squashRole,
        personaObj: promptOptions.personaObj,
        authorsNote: (authorsNote && authorsNote.enabled) ? authorsNote : null,
        guidanceText,
        guidanceType,
        lorebooks: lorebookState.lorebooks,
        globalSettings: lorebookState.globalSettings,
        activations: lorebookState.activations,
        globalRegexes,
        sessionVars,
        apiConfig,
        memoryReserve
    }));
}

export async function getMemoryReserveEstimate(char, safeContext) {
    const charId = char?.id;
    const sessionId = char?.sessionId;
    if (!charId || !sessionId) return 0;
    try {
        const chatData = await db.getChat(charId);
        const memoryBook = chatData?.memoryBooks?.[sessionId];
        const settings = memoryBook?.settings || {};
        const activeEntries = (Array.isArray(memoryBook?.entries) ? memoryBook.entries : [])
            .filter(e => e && (e.status || 'active') === 'active' && (e.content || '').trim());
        if (!settings.enabled || !activeEntries.length) return 0;
        const maxInjected = Math.max(1, Math.min(20, settings.maxInjectedEntries || 3));
        let totalContentLen = 0;
        for (const entry of activeEntries.slice(0, maxInjected)) {
            totalContentLen += (entry.content || '').trim().length;
        }
        const estimatedTokens = estimateTokens('M'.repeat(totalContentLen));
        return Math.min(estimatedTokens, Math.floor(safeContext * 0.35));
    } catch (e) {
        return 0;
    }
}
