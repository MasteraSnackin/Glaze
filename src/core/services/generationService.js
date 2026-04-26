import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { runGenerationHook } from '@/core/extensions/extensionRegistry.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { vectorSearchLorebooks } from '@/core/states/lorebookState.js';
import { executeFinalChatRequest } from '@/core/llm/usecases/chatRequestAssembly.js';
import {
    mergeLateVectorLoreEntries,
    injectLateVectorLoreMessages
} from '@/core/llm/usecases/vectorLoreInjection.js';
import { injectMemoryMessages } from '@/core/llm/usecases/memoryMessageInjection.js';
import { runChatPostPromptPipeline } from '@/core/llm/pipeline/postPromptOrchestrator.js';
import { executePreparedChatPrompt } from '@/core/llm/usecases/chatPreparedPromptExecution.js';
import { prepareChatPromptRequest } from '@/core/llm/usecases/chatPreparation.js';
import {
    buildMemoryInjection
} from '@/core/llm/usecases/memoryContextInjection.js';

function buildDebugKey(prefix, ...parts) {
    return [prefix, ...parts.filter(Boolean), Date.now(), Math.random().toString(36).slice(2, 8)].join(':');
}

// --- Helpers ---

function buildMergedContextBreakdown(contextBreakdown, { vectorLoreTokens = 0, memoryTokens = 0, memoryReserve = 0 } = {}) {
    if (!contextBreakdown) return null;

    const actualMemory = memoryTokens || memoryReserve;

    return {
        ...contextBreakdown,
        memory: memoryTokens,
        memoryReserve: memoryReserve || contextBreakdown.memoryReserve || 0,
        vectorLore: (contextBreakdown.vectorLore || 0) + vectorLoreTokens,
        summaryBase: contextBreakdown.summary || 0,
        summary: (contextBreakdown.summary || 0) + actualMemory,
        fixedBase: (contextBreakdown.fixedBase || 0) + actualMemory,
        fixedTotal: (contextBreakdown.fixedTotal || 0),
        totalUsed: (contextBreakdown.totalUsed || 0),
        remaining: Math.max(0, (contextBreakdown.remaining || 0))
    };
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

export async function generateChatResponse({
    text,
    char,
    history,
    authorsNote,
    summary,
    guidanceText,
    type = 'normal',
    debugKey: providedDebugKey,
    controller,
    callbacks
}) {
    const { onUpdate, onComplete, onError } = callbacks;
    const debugKey = providedDebugKey || buildDebugKey('chat', char?.id, char?.sessionId, type);

    await runGenerationHook('beforePromptBuild', {
        requestType: 'chat',
        debugKey,
        char,
        text,
        history,
        authorsNote,
        summary,
        guidanceText,
        type
    });

    const preparedRequest = await prepareChatPromptRequest({
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
                publishAppEvent(APP_EVENTS.nav.openApiSheet);
            }
        }
    });
    if (!preparedPromptExecution) return;

    const extendedPreparedPromptExecution = await runGenerationHook('afterPromptBuild', {
        ...preparedPromptExecution,
        requestType: 'chat',
        debugKey,
        char,
        text,
        summary,
        guidanceText,
        type,
        preparedRequest
    });

    const {
        result,
        safeHistory,
        contextSize,
        maxTokens,
        memoryReserve,
        requestConfig
    } = extendedPreparedPromptExecution;

    await runChatPostPromptPipeline({
        text,
        char,
        history,
        safeHistory,
        summary,
        contextSize,
        maxTokens,
        memoryReserve,
        result,
        requestConfig: {
            ...requestConfig,
            controller,
            debugKey
        },
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
                publishAppEvent(APP_EVENTS.debug.promptPreviewUpdated, { debugKey, prompt });
            }
        }
    });
}
