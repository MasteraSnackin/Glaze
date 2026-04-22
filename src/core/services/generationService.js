import { getApiReasoningTags } from '@/core/config/APISettings.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { executeRequest } from '@/core/services/llmApi.js';
import { vectorSearchLorebooks } from '@/core/states/lorebookState.js';
import { buildSummaryRequestPayload, buildMemoryDraftRequestPayload } from '@/core/llm/assemblers/requestAssemblers.js';
import { executeFinalChatRequest } from '@/core/llm/usecases/chatRequestExecution.js';
import {
    getEffectiveApiConfig,
    loadActivePreset,
    loadSessionVars,
    loadGlobalRegexes,
    getPromptWorkerOptions,
    buildPromptWorkerPayload,
    getSafeContextLimit,
    trimHistoryForContextWindow,
    processPromptAsync
} from '@/core/llm/usecases/chatPromptShared.js';
import { prepareChatPromptRequest } from '@/core/llm/usecases/chatPreparation.js';
import {
    mergeLateVectorLoreEntries,
    estimateVectorLoreTokens,
    injectMemoryMessages,
    injectLateVectorLoreMessages
} from '@/core/llm/usecases/chatLateEnrichment.js';
import { runChatPostPromptPipeline } from '@/core/llm/usecases/chatPostPromptPipeline.js';
import { executePreparedChatPrompt } from '@/core/llm/usecases/chatPreparedPromptExecution.js';
import { executeChatContextCalculation } from '@/core/llm/usecases/chatContextCalculation.js';
import { executeSummaryRequest } from '@/core/llm/usecases/summaryRequest.js';
import { executeMemoryDraftRequest } from '@/core/llm/usecases/memoryDraftRequest.js';
import {
    buildMemoryInjection
} from '@/core/llm/usecases/memoryBookContext.js';

let lastPrompt = null;

export function getLastPrompt() {
    return lastPrompt;
}

// --- Helpers ---

function getEffectiveApiConfig() {
    let config = getApiConfig();
    const runtime = getApiRuntimeStorage();
    let { maxTokens, contextSize } = config;

    if (!contextSize) contextSize = runtime.contextSize || 32000;
    if (maxTokens === undefined || maxTokens === null) {
        maxTokens = runtime.maxTokens || 8000;
    }

    return { ...config, maxTokens, contextSize };
}

function loadActivePreset(char, sessionId) {
    if (!presetState.initialized) {
        // Synchronous-ish check or just init (will be handled by reactive update anyway mostly)
    }
    const charId = char?.id;
    const chatId = charId && sessionId ? `${charId}_${sessionId}` : null;
    return getEffectivePreset(charId, chatId);
}

function getWorker() {
    if (!globalThis._genWorker) {
        globalThis._genWorker = new Worker(new URL('../../workers/generationWorker.js', import.meta.url), { type: 'module' });
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
            console.error("Generation worker crashed:", e);
            for (const [id, { reject }] of globalThis._workerQueue) {
                reject(new Error("Worker crashed: " + (e.message || "Unknown error")));
            }
            globalThis._workerQueue.clear();
            globalThis._genWorker.terminate();
            globalThis._genWorker = null;
        };
    }
    return globalThis._genWorker;
}

function processPromptAsync(payload) {
    const worker = getWorker();
    const WORKER_TIMEOUT = 30000;
    return new Promise((resolve, reject) => {
        const id = ++globalThis._msgIdCounter;

        const timer = setTimeout(() => {
            globalThis._workerQueue.delete(id);
            reject(new Error("Prompt building timed out (worker did not respond within 30s)"));
        }, WORKER_TIMEOUT);

        globalThis._workerQueue.set(id, {
            resolve: (data) => { clearTimeout(timer); resolve(data); },
            reject: (err) => { clearTimeout(timer); reject(err); }
        });
        worker.postMessage({ id, type: 'generateChatResponse', payload });
    });
}

function getSafeContextLimit(contextSize, maxTokens) {
    return contextSize - maxTokens > 0 ? contextSize - maxTokens : 8000;
}

function trimHistoryForContextWindow(history, safeContextLimit) {
    const isIOS = typeof navigator !== 'undefined' && /iPad|iPhone|iPod/.test(navigator.userAgent || '');
    const memoryLimitFactor = isIOS ? 15 : 5;
    const maxHistoryRetention = Math.max(100, Math.ceil(safeContextLimit / memoryLimitFactor));

    if (history && history.length > maxHistoryRetention) {
        return history.slice(-maxHistoryRetention);
    }

    return history;
}

function buildMergedContextBreakdown(contextBreakdown, { vectorLoreTokens = 0, memoryTokens = 0, memoryReserve = 0 } = {}) {
    if (!contextBreakdown) return null;

    const actualMemory = memoryTokens || memoryReserve;

    return {
        ...contextBreakdown,
        memory: memoryTokens,
        memoryReserve,
        vectorLore: (contextBreakdown.vectorLore || 0) + vectorLoreTokens,
        summaryBase: contextBreakdown.summary || 0,
        summary: (contextBreakdown.summary || 0) + actualMemory,
        fixedBase: (contextBreakdown.fixedBase || 0) + actualMemory,
        fixedTotal: (contextBreakdown.fixedTotal || 0),
        totalUsed: (contextBreakdown.totalUsed || 0),
        remaining: Math.max(0, (contextBreakdown.remaining || 0))
    };
}

function getSessionVarsKey(char) {
    const charId = char?.id || 'default';
    const sessionId = char?.sessionId || 'current';
    return `gz_vars_${charId}_${sessionId}`;
}

function loadSessionVars(char) {
    const varsKey = getSessionVarsKey(char);
    let sessionVars = {};
    try { sessionVars = JSON.parse(localStorage.getItem(varsKey)) || {}; } catch (e) { }
    return { varsKey, sessionVars };
}

function loadGlobalRegexes() {
    let globalRegexes = [];
    try { globalRegexes = JSON.parse(localStorage.getItem('regex_scripts')) || []; } catch (e) { }
    return globalRegexes;
}

function getPromptWorkerOptions(char, activePreset) {
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

function buildPromptWorkerPayload({
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

async function getMemoryReserveEstimate(char, safeContext) {
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

function resolvePromptCutoffIndex(result) {
    if (!result) return -1;
    return result.cutoffOriginalIndex !== undefined && result.cutoffOriginalIndex !== -1
        ? result.cutoffOriginalIndex
        : (result.cutoffIndex !== undefined ? result.cutoffIndex : -1);
}

async function buildPromptMemoryInjection({ char, history, summary, safeContext, result }) {
    return buildMemoryInjection({
        char,
        history,
        summary,
        safeContext,
        cutoffOriginalIndex: resolvePromptCutoffIndex(result)
    });
}

function normalizeKeywordLoreEntries(loreEntries = []) {
    if (!Array.isArray(loreEntries)) return [];
    loreEntries.forEach(entry => {
        if (entry && !entry._source) entry._source = 'keyword';
    });
    return loreEntries.filter(entry => entry?._source === 'keyword');
}

function mergeLateVectorLoreEntries(result, vectorResults = []) {
    const keywordEntries = normalizeKeywordLoreEntries(result?.loreEntries || []);
    const keywordIds = new Set(keywordEntries.map(entry => entry.id));
    const vectorEntries = limitVectorLoreEntries(
        vectorResults.filter(entry => !keywordIds.has(entry.id)),
        keywordEntries
    );

    vectorEntries.forEach(entry => { entry._source = 'vector'; });

    if (Array.isArray(result?.loreEntries)) {
        result.loreEntries = [...keywordEntries, ...vectorEntries];
    }

    return {
        keywordEntries,
        vectorEntries
    };
}

function estimateVectorLoreTokens(entries = []) {
    return entries.reduce((sum, entry) => sum + estimateTokens(entry?.content || ''), 0);
}

function buildContextCalculationResult(result, { vectorLoreTokens = 0, memoryTokens = 0, memoryReserve = 0 } = {}) {
    return {
        cutoffIndex: resolvePromptCutoffIndex(result),
        contextBreakdown: buildMergedContextBreakdown(result?.contextBreakdown, {
            vectorLoreTokens,
            memoryTokens,
            memoryReserve
        })
    };
}

export async function generateChatResponse({
    text,
    char,
    history,
    authorsNote,
    summary,
    guidanceText,
    type = 'normal',
    controller,
    callbacks
}) {
    const { onUpdate, onComplete, onError } = callbacks;
    const preparedRequest = prepareChatPromptRequest({
        text,
        char,
        history,
        authorsNote,
        summary,
        guidanceText,
        type
    });

    const t = (key) => translations[currentLang.value]?.[key] || key;
    const preparedPromptExecution = await executePreparedChatPrompt({
        preparedRequest,
        onError,
        deps: {
            t,
            showBottomSheet,
            closeBottomSheet,
            openApiSheet: () => {
                window.dispatchEvent(new CustomEvent('open-api-sheet'));
            }
        }
    });
    if (!preparedPromptExecution) return;

    const {
        result,
        safeHistory,
        contextSize,
        maxTokens,
        requestConfig
    } = preparedPromptExecution;

    await runChatPostPromptPipeline({
        text,
        char,
        history,
        safeHistory,
        summary,
        contextSize,
        maxTokens,
        result,
        requestConfig,
        callbacks: {
            ...callbacks,
            onUpdate,
            onComplete,
            onError
        },
        deps: {
            t,
            showBottomSheet,
            closeBottomSheet,
            vectorSearchLorebooks,
            mergeLateVectorLoreEntries,
            injectMemoryMessages,
            injectLateVectorLoreMessages,
            buildPromptMemoryInjection,
            buildMergedContextBreakdown,
            executeFinalChatRequest,
            setLastPrompt: (prompt) => {
                lastPrompt = prompt;
            }
        }
    });
}

export async function calculateContext({ char, history, authorsNote, summary }) {
    return executeChatContextCalculation({
        char,
        history,
        authorsNote,
        summary,
        deps: {
            getEffectiveApiConfig,
            loadActivePreset,
            getPromptWorkerOptions,
            loadSessionVars,
            loadGlobalRegexes,
            getSafeContextLimit,
            trimHistoryForContextWindow,
            buildPromptWorkerPayload,
            processPromptAsync,
            buildPromptMemoryInjection,
            vectorSearchLorebooks,
            mergeLateVectorLoreEntries,
            estimateVectorLoreTokens,
            buildContextCalculationResult
        }
    });
}

export async function generateSummary({ history, prompt, controller, apiConfigOverride = null }) {
    return executeSummaryRequest({
        history,
        prompt,
        controller,
        apiConfigOverride,
        deps: {
            getEffectiveApiConfig,
            buildSummaryRequestPayload,
            executeRequest
        }
    });
}

export async function generateMemoryDraft({ history, prompt, controller, apiConfigOverride = null }) {
    return executeMemoryDraftRequest({
        history,
        prompt,
        controller,
        apiConfigOverride,
        deps: {
            getEffectiveApiConfig,
            buildMemoryDraftRequestPayload,
            executeRequest,
            setLastPrompt: (promptBody) => {
                lastPrompt = promptBody;
            }
        }
    });
}
