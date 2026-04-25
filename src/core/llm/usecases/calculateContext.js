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
import { buildMemoryInjection } from '@/core/llm/usecases/memoryContextInjection.js';
import { vectorSearchLorebooks } from '@/core/states/lorebookState.js';
import { mergeLateVectorLoreEntries, estimateVectorLoreTokens } from '@/core/llm/usecases/vectorLoreInjection.js';
import { executeChatContextCalculation } from './contextCalculation.js';

function buildContextCalculationResult(result, { vectorLoreTokens = 0, memoryTokens = 0, memoryReserve = 0 } = {}) {
    if (!result?.contextBreakdown) {
        return { cutoffIndex: result?.cutoffIndex ?? -1, contextBreakdown: null };
    }
    const actualMemory = memoryTokens || memoryReserve;
    return {
        cutoffIndex: result.cutoffIndex ?? -1,
        cutoffOriginalIndex: result.cutoffOriginalIndex ?? result.cutoffIndex ?? -1,
        contextBreakdown: {
            ...result.contextBreakdown,
            memory: memoryTokens,
            memoryReserve: memoryReserve || result.contextBreakdown.memoryReserve || 0,
            vectorLore: (result.contextBreakdown.vectorLore || 0) + vectorLoreTokens,
            summaryBase: result.contextBreakdown.summary || 0,
            summary: (result.contextBreakdown.summary || 0) + actualMemory,
            fixedBase: (result.contextBreakdown.fixedBase || 0) + actualMemory,
            fixedTotal: result.contextBreakdown.fixedTotal || 0,
            totalUsed: result.contextBreakdown.totalUsed || 0,
            remaining: Math.max(0, result.contextBreakdown.remaining || 0)
        }
    };
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
            getMemoryReserveEstimate,
            buildPromptWorkerPayload,
            processPromptAsync,
            buildPromptMemoryInjection: buildMemoryInjection,
            vectorSearchLorebooks,
            mergeLateVectorLoreEntries,
            estimateVectorLoreTokens,
            buildContextCalculationResult
        }
    });
}
