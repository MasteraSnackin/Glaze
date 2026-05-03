import { getApiReasoningTags } from '@/core/config/APISettings.js';
import {
    getEffectiveApiConfig,
    loadActivePreset,
    loadSessionVars,
    loadGlobalRegexes,
    getSafeContextLimit,
    trimHistoryForContextWindow
} from '@/core/llm/usecases/promptConfigReaders.js';
import {
    getPromptWorkerOptions,
    buildPromptWorkerPayload,
    getMemoryReserveEstimate
} from '@/core/llm/usecases/promptPayloadBuilder.js';
import { processPromptAsync } from '@/core/llm/usecases/promptWorkerLifecycle.js';

export async function prepareChatPromptRequest({
    text,
    char,
    history,
    authorsNote,
    summary,
    guidanceText,
    type = 'normal'
}) {
    const apiConfig = getEffectiveApiConfig();
    const activePreset = loadActivePreset(char, char?.sessionId);
    const reasoningTags = getApiReasoningTags();
    const tagStart = activePreset?.reasoningStart || reasoningTags.start;
    const tagEnd = activePreset?.reasoningEnd || reasoningTags.end;
    const promptOptions = getPromptWorkerOptions(char, activePreset);
    const stopString = activePreset?.stopString || '';

    let { requestReasoning, reasoningEffort, maxTokens, contextSize } = apiConfig;
    if (activePreset && typeof activePreset.reasoningEnabled === 'boolean') {
        if (activePreset.reasoningEnabled === true) {
            requestReasoning = true;
        }
    }
    if (activePreset && activePreset.reasoningEffort) {
        reasoningEffort = activePreset.reasoningEffort;
    }

    const { varsKey, sessionVars } = loadSessionVars(char);
    sessionVars.reasoningPrefix = tagStart;
    sessionVars.reasoningSuffix = tagEnd;
    localStorage.setItem(varsKey, JSON.stringify(sessionVars));

    const globalRegexes = loadGlobalRegexes();
    const safeContextLimit = getSafeContextLimit(contextSize, maxTokens);
    const safeHistory = trimHistoryForContextWindow(history, safeContextLimit);
    const memoryReserve = await getMemoryReserveEstimate(char, safeContextLimit);
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
        apiConfig,
        memoryReserve
    });

    return {
        text,
        char,
        history,
        authorsNote,
        summary,
        guidanceText,
        type,
        apiConfig,
        activePreset,
        tagStart,
        tagEnd,
        stopString,
        requestReasoning,
        reasoningEffort,
        maxTokens,
        contextSize,
        varsKey,
        sessionVars,
        safeContextLimit,
        safeHistory,
        memoryReserve,
        payload
    };
}

export async function runPreparedChatPrompt(prepared) {
    const result = await processPromptAsync(prepared.payload);

    if (result?.needsVarsSave) {
        localStorage.setItem(prepared.varsKey, JSON.stringify(result.sessionVars));
    }

    return {
        ...prepared,
        result
    };
}
