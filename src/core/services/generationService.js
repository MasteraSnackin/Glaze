import { getApiConfig, getApiRuntimeStorage, getApiReasoningTags } from '@/core/config/APISettings.js';
import { estimateTokens } from '@/utils/tokenizer.js';
import { replaceMacros } from '@/utils/macroEngine.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { executeRequest } from '@/core/services/llmApi.js';
import { sendMessageNotification } from '@/core/services/notificationService.js';
import { presetState, initPresetState, getEffectivePreset } from '@/core/states/presetState.js';
import { lorebookState, scanLorebooks, initLorebookState, vectorSearchLorebooks } from '@/core/states/lorebookState.js';
import { getEffectivePersona } from '@/core/states/personaState.js';
import { applyRegexes } from '@/core/services/regexService.js';
import { buildChatRequestPayload, buildSummaryRequestPayload, buildMemoryDraftRequestPayload } from '@/core/llm/assemblers/requestAssemblers.js';
import { db } from '@/utils/db.js';
import { getEmbeddings } from '@/core/services/embeddingService.js';
import { getEmbeddingConfig, isEmbeddingConfigured } from '@/core/config/embeddingSettings.js';
import { findTopK } from '@/utils/vectorMath.js';
import { logger } from '../../utils/logger.js';

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

function buildMergedContextBreakdown(contextBreakdown, { vectorLoreTokens = 0, memoryTokens = 0 } = {}) {
    if (!contextBreakdown) return null;

    return {
        ...contextBreakdown,
        memory: memoryTokens,
        vectorLore: (contextBreakdown.vectorLore || 0) + vectorLoreTokens,
        summaryBase: contextBreakdown.summary || 0,
        summary: (contextBreakdown.summary || 0) + memoryTokens,
        fixedBase: (contextBreakdown.fixedBase || 0) + memoryTokens,
        fixedTotal: (contextBreakdown.fixedTotal || 0) + memoryTokens,
        totalUsed: (contextBreakdown.totalUsed || 0) + memoryTokens,
        remaining: Math.max(0, (contextBreakdown.remaining || 0) - memoryTokens)
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
    apiConfig
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
        apiConfig
    }));
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
    let apiConfig = getEffectiveApiConfig();
    let { providerId, apiKey, apiUrl, model, stream, requestReasoning, reasoningEffort, temp, topP, maxTokens, contextSize } = apiConfig;

    const t = (key) => translations[currentLang.value]?.[key] || key;

    if (!apiUrl || !model) {
        showBottomSheet({
            title: t('section_connection') || "Connection",
            bigInfo: {
                icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;"><path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.04.24.24.41.48.41h3.84c.24 0 .43-.17.47-.41l.36-2.54c.59-.24 1.13-.57 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"/></svg>',
                description: t('api_not_configured') || "API Not Configured",
                buttonText: t('btn_configure') || "Configure",
                onButtonClick: () => {
                    closeBottomSheet();
                    window.dispatchEvent(new CustomEvent('open-api-sheet'));
                }
            }
        });
        if (onError) onError(new Error("API Not Configured"));
        return;
    }

    // --- Prompt Construction based on Preset ---
    const activePreset = loadActivePreset(char, char?.sessionId);

    // Reasoning Tags from Preset
    const reasoningTags = getApiReasoningTags();
    const tagStart = activePreset?.reasoningStart || reasoningTags.start;
    const tagEnd = activePreset?.reasoningEnd || reasoningTags.end;

    const promptOptions = getPromptWorkerOptions(char, activePreset);
    const stopString = activePreset?.stopString || '';

    if (activePreset && typeof activePreset.reasoningEnabled === 'boolean') {
        // Only override if preset explicitly enables it, otherwise keep user setting
        if (activePreset.reasoningEnabled === true) {
            requestReasoning = true;
        }
        // If preset is false and user enabled reasoning in API settings, keep user's choice
    }
    if (activePreset && activePreset.reasoningEffort) {
        reasoningEffort = activePreset.reasoningEffort;
    }

    const { varsKey, sessionVars } = loadSessionVars(char);

    // Set reasoning macros for {{reasoningPrefix}} and {{reasoningSuffix}}
    sessionVars.reasoningPrefix = tagStart;
    sessionVars.reasoningSuffix = tagEnd;
    localStorage.setItem(varsKey, JSON.stringify(sessionVars));

    const globalRegexes = loadGlobalRegexes();

    let result;
    let safeHistory = history;
    try {
        const safeContextLimit = getSafeContextLimit(contextSize, maxTokens);
        safeHistory = trimHistoryForContextWindow(history, safeContextLimit);

        const payload = buildPromptWorkerPayload({
            char,
            history: safeHistory,
            summary,
            activePreset,
            promptOptions,
            authorsNote,
            guidanceText,
            guidanceType: type,
            globalRegexes,
            sessionVars,
            apiConfig
        });

        result = await processPromptAsync(payload);
    } catch (e) {
        console.error("Worker error:", e);
        if (onError) onError(e);
        return;
    }

    // Guard: if aborted while worker was building prompt, don't send API request
    if (controller?.signal?.aborted) {
        if (onError) onError(new DOMException('Aborted', 'AbortError'));
        return;
    }

    if (result.needsVarsSave) {
        localStorage.setItem(varsKey, JSON.stringify(result.sessionVars));
    }

    let newVectorEntries = [];
    let vectorLoreTokens = 0;
    try {
        const vectorResults = await vectorSearchLorebooks(safeHistory || history, text, char, char?.sessionId);
        if (vectorResults.length > 0) {
            ({ vectorEntries: newVectorEntries } = mergeLateVectorLoreEntries(result, vectorResults));
        }
    } catch (e) {
        console.warn('[generateChatResponse] Vector search failed:', e);
        showBottomSheet({
            title: t('title_error') || 'Error',
            bigInfo: {
                icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;color:#ff9500"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>',
                description: t('msg_vector_generation_failed') || 'The embedding model did not respond during generation, so vector lorebook retrieval could not complete.',
                buttonText: t('btn_ok') || 'OK',
                onButtonClick: () => closeBottomSheet()
            }
        });
        if (onError) onError(e);
        return;
    }

    const safeContext = contextSize - maxTokens;
    const memoryInjection = await buildPromptMemoryInjection({
        char,
        history: safeHistory || history,
        summary,
        safeContext,
        result
    });
    let messages = result.messages;

    if (memoryInjection.messages.length > 0) {
        messages = injectMemoryMessages(messages, memoryInjection, {
            injectionTarget: memoryInjection.injectionTarget
        });
    }

    if (newVectorEntries.length > 0) {
        const vectorLoreMessages = newVectorEntries
            .map(entry => {
                const content = entry.content || '';
                const tokens = estimateTokens(content);
                return {
                    role: 'system',
                    content,
                    id: entry.id,
                    position: entry.position,
                    blockName: `Lorebook: ${entry.comment || entry.keys?.[0] || 'Entry'}`,
                    isLorebook: true,
                    sources: tokens > 0 ? [{ source: 'vectorLore', tokens }] : [],
                    _allSources: tokens > 0 ? [{ source: 'vectorLore', tokens }] : []
                };
            })
            .filter(msg => msg.content && msg.content.trim().length > 0);

        vectorLoreTokens = vectorLoreMessages.reduce((sum, m) => sum + (m._allSources?.[0]?.tokens || 0), 0);

        if (vectorLoreMessages.length > 0) {
            messages = injectVectorLoreMessages(messages, vectorLoreMessages);

            // Re-apply history trimming after late vector lore injection so we don't blow the effective context.
            const staticMessages = messages.filter(m => !m.isHistory);
            const historyMessages = messages.filter(m => m.isHistory);
            let staticTokens = 0;
            for (const msg of staticMessages) {
                staticTokens += estimateTokens(msg.content || '');
            }

            if (staticTokens >= safeContext) {
                messages = staticMessages;
            } else {
                let remainingHistoryBudget = safeContext - staticTokens;
                let includedHistoryCount = 0;
                let currentHistoryTokens = 0;

                for (let i = historyMessages.length - 1; i >= 0; i--) {
                    const tokens = estimateTokens(historyMessages[i].content || '');
                    if (currentHistoryTokens + tokens <= remainingHistoryBudget) {
                        currentHistoryTokens += tokens;
                        includedHistoryCount++;
                    } else {
                        break;
                    }
                }

                const keptHistoryMessages = historyMessages.slice(historyMessages.length - includedHistoryCount);
                messages = [
                    ...staticMessages,
                    ...keptHistoryMessages
                ];
            }
        }
    }

    if (result.staticTokens >= safeContext) {
        showBottomSheet({
            title: t('error_context_limit') || "Context Limit Exceeded",
            bigInfo: {
                icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;color:#ff4444"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>',
                description: t('msg_context_limit') || "The preset prompts exceed the context limit. Please increase Context Size or reduce prompt length.",
                glossaryChip: { term: 'context', hint: t('context_limit_glossary_hint') || 'Learn more:', label: t('context_limit_glossary_chip') || 'Context' },
                buttonText: t('btn_ok') || "OK",
                onButtonClick: () => closeBottomSheet()
            }
        });
        if (onError) onError(new Error("Context limit exceeded"));
        return;
    }

    if (callbacks.onPromptReady) {
        const contextBreakdown = buildMergedContextBreakdown(result.contextBreakdown, {
            vectorLoreTokens,
            memoryTokens: memoryInjection.tokens || 0
        });

        callbacks.onPromptReady({
            loreEntries: result.loreEntries,
            memoryEntries: memoryInjection.entries,
            contextBreakdown
        });
    }

    const { previewBody, requestBody } = buildChatRequestPayload({
        providerId,
        model,
        messages,
        temperature: temp,
        topP,
        stream,
        reasoningEffort,
        maxTokens,
        stopString
    });

    // Save for preview
    lastPrompt = JSON.parse(JSON.stringify(previewBody));

    // Final abort check before API call
    if (controller?.signal?.aborted) {
        if (onError) onError(new DOMException('Aborted', 'AbortError'));
        return;
    }

    // Call LLM API
    try {
        logger.debug('[GenerationService] Final Request:', requestBody);
        await executeRequest({
            providerId,
            apiUrl,
            apiKey,
            requestBody,
            stream,
            controller,
            requestReasoning,
            tagStart,
            tagEnd,
            requestType: 'chat',
            callbacks: { onUpdate, onComplete, onError }
        });
    } catch (e) {
        console.error("Generation error:", e);
        sendMessageNotification(
            t('error_generation') || "Generation Error",
            e.message,
            null,
            char?.id,
            null, // sessionId unknown here in catch block context easily without refactor
            null  // msgId
        );
        if (onError) onError(e);
    }
}

export async function calculateContext({ char, history, authorsNote, summary }) {
    const apiConfig = getEffectiveApiConfig();
    const activePreset = loadActivePreset(char, char?.sessionId);

    const promptOptions = getPromptWorkerOptions(char, activePreset);

    const anData = authorsNote;

    const { sessionVars } = loadSessionVars(char);
    const globalRegexes = loadGlobalRegexes();

    try {
        const safeContextLimit = getSafeContextLimit(apiConfig.contextSize, apiConfig.maxTokens);
        const safeHistory = trimHistoryForContextWindow(history, safeContextLimit);

        const payload = buildPromptWorkerPayload({
            char,
            history: safeHistory,
            summary,
            activePreset,
            promptOptions,
            authorsNote: anData,
            globalRegexes,
            sessionVars,
            apiConfig
        });

        const result = await processPromptAsync(payload);
        const memoryInjection = await buildPromptMemoryInjection({
            char,
            history: safeHistory,
            summary,
            safeContext: safeContextLimit,
            result
        });

        // Calculate vector lorebook tokens for accurate breakdown display
        let vectorLoreTokens = 0;
        try {
            const vectorResults = await vectorSearchLorebooks(safeHistory || history, '', char, char?.sessionId);
            if (vectorResults.length > 0) {
                const { vectorEntries } = mergeLateVectorLoreEntries(result, vectorResults);
                vectorLoreTokens = estimateVectorLoreTokens(vectorEntries);
            }
        } catch (e) {
            console.warn('[calculateContext] Vector search failed:', e);
        }

        const resolvedCutoff = resolvePromptCutoffIndex(result);

        const contextBreakdown = buildMergedContextBreakdown(result.contextBreakdown, {
            vectorLoreTokens,
            memoryTokens: memoryInjection.tokens || 0
        });

        return {
            cutoffIndex: resolvedCutoff,
            contextBreakdown
        };
    } catch (e) {
        console.error("Calculate context worker error", e);
        return {
            cutoffIndex: 0,
            contextBreakdown: null
        };
    }
}

export async function generateSummary({ history, prompt, controller, apiConfigOverride = null }) {
    const effectiveConfig = {
        ...getEffectiveApiConfig(),
        ...(apiConfigOverride || {})
    };
    const { providerId, apiKey, apiUrl, model, temp } = effectiveConfig;

    if (!apiUrl || !model) {
        throw new Error("API Not Configured");
    }

    const defaultPrompt = "Summarize the following roleplay conversation concisely, focusing on the current situation and key events:\n\n{{history}}";
    const template = prompt || defaultPrompt;

    let finalPrompt = template.replace('{{history}}', history);
    if (!template.includes('{{history}}')) {
        finalPrompt = `${template}\n\n${history}`;
    }

    let result = "";

    const { requestBody } = buildSummaryRequestPayload({
        providerId,
        model,
        prompt: finalPrompt,
        temperature: temp
    });

    await executeRequest({
        providerId,
        apiUrl,
        apiKey,
        requestBody,
        controller,
        callbacks: {
            onComplete: (text) => { result = text; }
        }
    });

    return result;
}

function normalizeMessageIdList(entry) {
    if (!entry || typeof entry !== 'object') return [];
    if (Array.isArray(entry.messageIds)) return [...new Set(entry.messageIds.filter(Boolean))];
    const ids = [];
    if (entry.messageRange?.startMessageId) ids.push(entry.messageRange.startMessageId);
    if (entry.messageRange?.endMessageId && entry.messageRange.endMessageId !== entry.messageRange.startMessageId) ids.push(entry.messageRange.endMessageId);
    return [...new Set(ids.filter(Boolean))];
}

function buildSummaryExcerpt(summary) {
    if (!summary) return '';
    if (typeof summary === 'string') return summary.trim().slice(0, 800);
    if (typeof summary === 'object') {
        if (typeof summary.content === 'string') return summary.content.trim().slice(0, 800);
        return ['timeline', 'characterArcs', 'conflictsThreads', 'notHappenedYet', 'notes']
            .map(key => summary[key])
            .filter(value => typeof value === 'string' && value.trim())
            .join('\n\n')
            .slice(0, 800);
    }
    return '';
}

function escapeRegex(string) {
    return String(string || '').replace(/[/\-\\^$*+?.()|[\]{}]/g, '\\$&');
}

const GLAZE_BOUNDARIES = '[\\s.,!?;:"\'\u201C\u201D\u2018\u2019\u00AB\u00BB(){}\\[\\]—–]';

function tryCreateRegex(pattern, flags = 'g') {
    try {
        return new RegExp(pattern, flags);
    } catch {
        return null;
    }
}

function normalizeHybridText(text = '') {
    return String(text || '')
        .toLowerCase()
        .replace(/[^\p{L}\p{N}\s-]+/gu, ' ')
        .replace(/\s+/g, ' ')
        .trim();
}

function uniqueStrings(values = [], limit = 32) {
    const seen = new Set();
    const result = [];
    for (const value of values) {
        const raw = String(value || '').trim();
        const normalized = normalizeHybridText(raw);
        if (!normalized || seen.has(normalized)) continue;
        seen.add(normalized);
        result.push(raw);
        if (result.length >= limit) break;
    }
    return result;
}

function extractMemoryRetrievalHints(entry) {
    const hints = [];
    if (entry?.title) hints.push(String(entry.title));
    if (Array.isArray(entry?.keys)) hints.push(...entry.keys.map(v => String(v)));
    if (Array.isArray(entry?.glazeKeys)) hints.push(...entry.glazeKeys.map(v => String(v)));
    const content = String(entry?.content || '');
    if (content) {
        const lines = content.split(/\r?\n/).map(line => line.trim()).filter(Boolean).slice(0, 8);
        hints.push(...lines);
    }
    return uniqueStrings(hints, 32);
}

function checkKeyMatch(key, text, { glaze = false, caseSensitive = false } = {}) {
    if (!key || !text) return false;
    const sourceText = String(text || '');
    const sourceKey = String(key || '');
    const flags = caseSensitive ? '' : 'i';
    if (glaze) {
        const escaped = escapeRegex(sourceKey);
        const regex = tryCreateRegex(`(?:^|${GLAZE_BOUNDARIES})${escaped}(?:$|${GLAZE_BOUNDARIES})`, flags);
        return regex ? regex.test(sourceText) : false;
    }
    const regex = tryCreateRegex(`\\b${escapeRegex(sourceKey)}\\b`, flags);
    if (regex && regex.test(sourceText)) return true;
    const haystack = caseSensitive ? sourceText : sourceText.toLowerCase();
    const needle = caseSensitive ? sourceKey : sourceKey.toLowerCase();
    return haystack.includes(needle);
}

async function vectorSearchMemoryEntries(entries, history = [], currentText = '') {
    const config = getEmbeddingConfig();
    if (!config.enabled || !isEmbeddingConfigured()) return [];
    const vectorEntries = entries.filter(entry => entry?.vectorSearch);
    if (!vectorEntries.length) return [];

    const allEmbeddings = await db.getEmbeddingsBySource('memory_entry');
    const embeddingMap = new Map(allEmbeddings.map(e => [e.id, e]));
    const candidates = vectorEntries
        .map(entry => {
            const emb = embeddingMap.get(entry.id);
            // NEW: Support both multi-vector (vectors) and legacy (vector)
            if (emb && (emb.vectors || emb.vector)) {
                const candidate = { ...entry, retrievalHints: emb.retrievalHints || [] };
                if (emb.vectors) {
                    candidate.vectors = emb.vectors;  // Multi-vector
                } else if (emb.vector) {
                    candidate.vector = emb.vector;  // Legacy single vector
                }
                return candidate;
            }
            return null;
        })
        .filter(Boolean);
    if (!candidates.length) return [];

    const recentHistory = history.slice(-(config.scanDepth || 5));
    const focusedQueryParts = recentHistory.filter(m => m.role === 'user').map(m => m.content).filter(Boolean);
    if (currentText && currentText.trim()) focusedQueryParts.push(currentText.trim());
    const queryText = focusedQueryParts.join('\n').trim();
    if (!queryText) return [];

    const queryVectorsData = await getEmbeddings([queryText]);
    if (!queryVectorsData || !queryVectorsData[0] || !queryVectorsData[0][0]?.vector) return [];

    // Extract the actual vector from the first chunk
    const queryVector = queryVectorsData[0][0].vector;
    return findTopK(queryVector, candidates, candidates.length, 0)
        .filter(result => result.score >= (config.threshold || 0.6))
        .slice(0, config.topK || 5)
        .map(result => ({ ...result, vectorScore: result.score, vector: undefined }));
}

async function ensureMemoryEntryEmbedding(entry, charId, sessionId) {
    if (!entry?.id || !entry.vectorSearch || !isEmbeddingConfigured()) return;
    const config = getEmbeddingConfig();
    if (!config.enabled) return;
    const text = (config.target === 'keys'
        ? [...(entry.keys || []), ...(entry.glazeKeys || [])].join(', ')
        : String(entry.content || '')).trim();
    if (!text) return;
    const existing = await db.getEmbedding(entry.id);
    const retrievalHints = extractMemoryRetrievalHints(entry);
    const textHash = JSON.stringify({ text, retrievalHints });
    if (existing && existing.textHash === textHash) return;
    const vectorsData = await getEmbeddings([text]);
    if (!vectorsData || !vectorsData[0]) return;
    await db.saveEmbedding({
        id: entry.id,
        sourceType: 'memory_entry',
        sourceId: `memorybook_${charId}_${sessionId}`,
        vectors: vectorsData[0],  // NEW: array of {text, vector} chunks
        vector: null,  // Legacy field set to null
        textHash,
        retrievalHints,
        updatedAt: Date.now()
    });
}

export async function indexMemoryEntryForSession(entry, charId, sessionId) {
    await ensureMemoryEntryEmbedding(entry, charId, sessionId);
}

export async function deleteMemoryEntryIndex(entryId) {
    if (!entryId) return;
    await db.deleteEmbedding(entryId);
}

async function buildMemoryInjection({ char, history, summary, safeContext, cutoffOriginalIndex = -1 }) {
    const charId = char?.id;
    const sessionId = char?.sessionId;
    if (!charId || !sessionId) return { messages: [], entries: [], tokens: 0, injectionTarget: 'summary_block', macroContent: '' };

    const chatData = await db.getChat(charId);
    const memoryBook = chatData?.memoryBooks?.[sessionId];
    const settings = memoryBook?.settings || {};
    const activeEntries = (Array.isArray(memoryBook?.entries) ? memoryBook.entries : [])
        .filter(entry => entry && (entry.status || 'active') === 'active' && (entry.content || '').trim());

    if (!settings.enabled || !activeEntries.length) return { messages: [], entries: [], tokens: 0, injectionTarget: settings.injectionTarget === 'summary_macro' ? 'summary_macro' : 'summary_block', macroContent: '' };

    const recentHistory = Array.isArray(history) ? history.slice(-12) : [];
    const historyText = recentHistory.map(item => item?.content || item?.text || '').filter(Boolean).join('\n').toLowerCase();

    const inPromptMessageIds = new Set();
    if (cutoffOriginalIndex >= 0 && Array.isArray(history)) {
        for (const m of history) {
            if ((m.chatId ?? -1) >= cutoffOriginalIndex && m.messageId) {
                inPromptMessageIds.add(m.messageId);
            }
        }
    } else {
        recentHistory.forEach(item => {
            if (item?.messageId) inPromptMessageIds.add(item.messageId);
        });
    }

    const recentLabels = new Set();
    recentHistory.forEach(item => {
        (Array.isArray(item?.contextRefs) ? item.contextRefs : []).forEach(ref => {
            if (ref?.label) recentLabels.add(String(ref.label).toLowerCase());
        });
    });

    const uniqueWords = [...new Set(historyText.match(/[\p{L}\p{N}_-]{4,}/gu) || [])].slice(0, 40);
    const currentText = recentHistory[recentHistory.length - 1]?.content || '';
    const keywordMatchedIds = new Set();
    const scanText = `${recentHistory.map(item => item?.content || '').join('\n')}\n${currentText}`;
    const keyMatchMode = ['plain', 'glaze', 'both'].includes(settings.keyMatchMode) ? settings.keyMatchMode : 'plain';

    activeEntries.forEach(entry => {
        const directKeys = Array.isArray(entry.keys) ? entry.keys : [];
        const plainMatch = keyMatchMode !== 'glaze' && directKeys.some(key => checkKeyMatch(key, scanText));
        const glazeMatch = keyMatchMode !== 'plain' && directKeys.some(key => checkKeyMatch(key, scanText, { glaze: true }));
        if (plainMatch || glazeMatch) {
            keywordMatchedIds.add(entry.id);
        }
    });

    const vectorResults = await vectorSearchMemoryEntries(activeEntries, history, currentText).catch(() => []);
    const vectorScores = new Map(vectorResults.map(item => [item.id, item.vectorScore || item.score || 0]));

    const eligibleEntries = activeEntries.filter(entry => {
        const messageIds = normalizeMessageIdList(entry);
        if (!messageIds.length) return true;
        return !messageIds.some(id => inPromptMessageIds.has(id));
    });

    const scoredEntries = eligibleEntries.map((entry, index) => {
        const haystack = `${entry.title || ''}\n${entry.content || ''}`.toLowerCase();
        const messageIds = normalizeMessageIdList(entry);
        let score = 0;
        if (messageIds.length > 0) score += 2;
        if (keywordMatchedIds.has(entry.id)) score += 6;
        if (vectorScores.has(entry.id)) score += Math.max(0, (vectorScores.get(entry.id) || 0) * 5);
        (Array.isArray(entry.contextRefs) ? entry.contextRefs : []).forEach(ref => {
            const label = String(ref?.label || '').toLowerCase();
            if (label && recentLabels.has(label)) score += 3;
        });
        uniqueWords.forEach(word => {
            if (haystack.includes(word)) score += 1;
        });
        score += Math.min(3, index / Math.max(eligibleEntries.length, 1));
        return { entry, score };
    });

    const topEntries = scoredEntries
        .filter(item => item.score > 0)
        .sort((a, b) => b.score - a.score)
        .slice(0, Math.max(1, Math.min(5, settings.maxInjectedEntries || 3)))
        .map(item => item.entry);

    if (!topEntries.length) return { messages: [], entries: [], tokens: 0, injectionTarget: settings.injectionTarget === 'summary_macro' ? 'summary_macro' : 'summary_block', macroContent: '' };

    const summaryExcerpt = buildSummaryExcerpt(summary);
    const macroContent = topEntries
        .map(entry => (entry.content || '').trim())
        .filter(Boolean)
        .join('\n\n');
    const content = [
        summaryExcerpt ? `Summary excerpt:\n${summaryExcerpt}` : '',
        'Memory context:',
        ...topEntries.map(entry => `- ${(entry.title || 'Memory').trim()}: ${(entry.content || '').trim()}`)
    ].filter(Boolean).join('\n\n');
    const tokens = estimateTokens(content);
    if (!content || tokens <= 0 || tokens >= Math.max(256, Math.floor(safeContext * 0.35))) {
        return { messages: [], entries: [], tokens: 0, injectionTarget: settings.injectionTarget === 'summary_macro' ? 'summary_macro' : 'summary_block', macroContent: '' };
    }

    return {
        messages: [{
            role: 'system',
            content,
            blockName: 'Memory Book',
            isMemory: true,
            sources: [{ source: 'memory', tokens }],
            _allSources: [{ source: 'memory', tokens }]
        }],
        entries: topEntries,
        tokens,
        injectionTarget: settings.injectionTarget === 'summary_macro' ? 'summary_macro' : 'summary_block',
        macroContent
    };
}

function findSummaryInsertIndex(messages) {
    return messages.findIndex(msg => Array.isArray(msg?.sources) && msg.sources.some(source => source?.source === 'summary'));
}

function injectMemoryIntoSummaryMacro(messages, memoryInjection) {
    if (!memoryInjection?.macroContent) return messages;

    const summaryIndex = findSummaryInsertIndex(messages);
    if (summaryIndex === -1) return null;

    const summaryMessage = messages[summaryIndex];
    const existingContent = String(summaryMessage?.content || '').trim();
    const appendedContent = existingContent
        ? `${existingContent}\n\n${memoryInjection.macroContent}`
        : memoryInjection.macroContent;

    const nextSources = Array.isArray(summaryMessage?.sources) ? [...summaryMessage.sources] : [];
    const memorySource = nextSources.find(source => source?.source === 'memory');
    if (memorySource) memorySource.tokens += memoryInjection.tokens || 0;
    else if ((memoryInjection.tokens || 0) > 0) nextSources.push({ source: 'memory', tokens: memoryInjection.tokens || 0 });

    const nextAllSources = Array.isArray(summaryMessage?._allSources) ? [...summaryMessage._allSources] : [];
    if ((memoryInjection.tokens || 0) > 0) nextAllSources.push({ source: 'memory', tokens: memoryInjection.tokens || 0 });

    return [
        ...messages.slice(0, summaryIndex),
        {
            ...summaryMessage,
            content: appendedContent,
            sources: nextSources,
            _allSources: nextAllSources
        },
        ...messages.slice(summaryIndex + 1)
    ];
}

function injectMemoryMessages(messages, memoryInjection, settings = {}) {
    if (!memoryInjection?.messages?.length) return messages;

    const injectionTarget = settings.injectionTarget === 'summary_macro' ? 'summary_macro' : 'summary_block';
    if (injectionTarget === 'summary_macro') {
        const macroInjected = injectMemoryIntoSummaryMacro(messages, memoryInjection);
        if (macroInjected) {
            return macroInjected;
        }
    }

    const firstHistoryIndex = messages.findIndex(m => m.isHistory);
    if (firstHistoryIndex === -1) {
        return [...messages, ...memoryInjection.messages];
    }
    return [
        ...messages.slice(0, firstHistoryIndex),
        ...memoryInjection.messages,
        ...messages.slice(firstHistoryIndex)
    ];
}

function combineLoreSources(messages = []) {
    const sourceMap = new Map();
    for (const item of messages.flatMap(msg => msg._allSources || msg.sources || [])) {
        if (!item?.source) continue;
        sourceMap.set(item.source, (sourceMap.get(item.source) || 0) + (item.tokens || 0));
    }
    return [...sourceMap.entries()].map(([source, tokens]) => ({ source, tokens }));
}

function limitVectorLoreEntries(vectorEntries = [], keywordEntries = []) {
    const maxInjectedEntries = Math.max(1, Math.min(100, Number(lorebookState.globalSettings?.maxInjectedEntries || 5)));
    const remainingSlots = Math.max(0, maxInjectedEntries - keywordEntries.length);
    if (remainingSlots <= 0) return [];

    return [...vectorEntries]
        .sort((a, b) => (b.vectorScore || 0) - (a.vectorScore || 0))
        .slice(0, remainingSlots);
}

function buildVectorLoreBlock(entries, position) {
    const combinedContent = entries.map(msg => msg.content || '').filter(Boolean).join('\n\n');
    if (!combinedContent) return null;
    const combinedSources = combineLoreSources(entries);
    return {
        role: 'system',
        content: combinedContent,
        blockName: position === 'worldInfoAfter' ? 'Vector Lorebook After' : 'Vector Lorebook Before',
        isLorebook: true,
        sources: combinedSources,
        _allSources: combinedSources
    };
}

function resolveLateVectorLorePosition(entry) {
    const rawPosition = entry?.position === 'matchGlobal'
        ? (lorebookState.globalSettings?.injectionPosition || 'worldInfoBefore')
        : (entry?.position || 'worldInfoBefore');

    if (rawPosition === 'worldInfoAfter') return 'worldInfoAfter';
    if (rawPosition === 'lorebooksMacro') return 'worldInfoAfter';
    return 'worldInfoBefore';
}

function injectVectorLoreMessages(messages, loreEntries) {
    if (!Array.isArray(loreEntries) || !loreEntries.length) return messages;

    const beforeEntries = [];
    const afterEntries = [];
    loreEntries.forEach(entry => {
        if (resolveLateVectorLorePosition(entry) === 'worldInfoAfter') afterEntries.push(entry);
        else beforeEntries.push(entry);
    });

    const beforeBlock = buildVectorLoreBlock(beforeEntries, 'worldInfoBefore');
    const afterBlock = buildVectorLoreBlock(afterEntries, 'worldInfoAfter');
    if (!beforeBlock && !afterBlock) return messages;

    const firstHistoryIndex = messages.findIndex(m => m.isHistory);
    const charCardIndex = messages.findIndex(m => m.blockId === 'char_card');
    const afterInsertIndex = firstHistoryIndex === -1 ? messages.length : firstHistoryIndex;
    const beforeInsertIndex = charCardIndex >= 0 ? charCardIndex : afterInsertIndex;

    let nextMessages = [...messages];
    if (afterBlock) {
        nextMessages = [
            ...nextMessages.slice(0, afterInsertIndex),
            afterBlock,
            ...nextMessages.slice(afterInsertIndex)
        ];
    }
    if (beforeBlock) {
        nextMessages = [
            ...nextMessages.slice(0, beforeInsertIndex),
            beforeBlock,
            ...nextMessages.slice(beforeInsertIndex)
        ];
    }
    return nextMessages;
}

export async function generateMemoryDraft({ history, prompt, controller, apiConfigOverride = null }) {
    const effectiveConfig = {
        ...getEffectiveApiConfig(),
        ...(apiConfigOverride || {})
    };
    const { providerId, apiKey, apiUrl, model, temp } = effectiveConfig;

    // Memory drafts need enough output budget for long summaries even when the
    // provider has a small default completion limit.
    const explicitOverrideMaxTokens = Number(apiConfigOverride?.maxTokens);
    const hasExplicitOverride = Number.isFinite(explicitOverrideMaxTokens) && explicitOverrideMaxTokens > 0;
    const configuredMaxTokens = Number(effectiveConfig.maxTokens);
    const memoryDraftMaxTokens = hasExplicitOverride
        ? Math.max(200, Math.round(explicitOverrideMaxTokens))
        : (Number.isFinite(configuredMaxTokens) && configuredMaxTokens > 0
            ? Math.max(1200, Math.round(configuredMaxTokens))
            : 2000);

    if (!apiUrl || !model) {
        throw new Error("API Not Configured");
    }

    const defaultPrompt = [
        'Create exactly one concise long-term memory entry from the following roleplay segment.',
        'Preserve the original language of the source segment. Do not translate it.',
        'Use only facts that are explicitly supported by the segment.',
        'Do not infer completed outcomes, registrations, approvals, or decisions unless the text clearly states them.',
        'Focus on durable facts, developments, or relationship changes that should persist beyond immediate context.',
        'Do not copy the dialogue verbatim.',
        'Return only the memory entry text with no preface, label, or explanation.',
        '',
        '{{history}}'
    ].join('\n');
    const template = prompt || defaultPrompt;

    let finalPrompt = template.replace('{{history}}', history);
    if (!template.includes('{{history}}')) {
        finalPrompt = `${template}\n\n${history}`;
    }

    let result = "";
    
    let requestError = null;
    const { previewBody, requestBody } = buildMemoryDraftRequestPayload({
        providerId,
        model,
        prompt: finalPrompt,
        temperature: temp,
        maxTokens: memoryDraftMaxTokens
    });

    lastPrompt = JSON.parse(JSON.stringify(previewBody));
    
    await executeRequest({
        providerId,
        apiUrl,
        apiKey,
        requestBody,
        stream: false,
        controller,
        requestType: 'memory_draft',
        callbacks: {
            onUpdate: (chunk, reasoningChunk, effectiveText) => {
                if (effectiveText) result = effectiveText;
                else if (chunk) result += chunk;
            },
            onComplete: (text) => { if (text) result = text; },
            onError: (err) => { requestError = err; }
        }
    });
    
    if (requestError) throw requestError;

    return result;
}
