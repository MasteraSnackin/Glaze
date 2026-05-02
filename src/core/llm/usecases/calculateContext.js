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
    const hasMemoryInjection = memoryTokens > 0;
    const actualMemory = hasMemoryInjection ? memoryTokens : 0;
    const effectiveReserve = hasMemoryInjection ? 0 : (memoryReserve || result.contextBreakdown.memoryReserve || 0);

    const newFixedBase = (result.contextBreakdown.fixedBase || 0) + actualMemory;
    const newFixedTotal = newFixedBase + (result.contextBreakdown.lorebookReserve || 0) + effectiveReserve;
    const newHistory = result.contextBreakdown.history || 0;
    const newTotalUsed = newFixedBase + (result.contextBreakdown.lorebookReserve || 0) + effectiveReserve + newHistory;
    const contextSize = result.contextBreakdown.contextSize || result.contextBreakdown.safeContext || 0;

    return {
        cutoffIndex: result.cutoffIndex ?? -1,
        cutoffOriginalIndex: result.cutoffOriginalIndex ?? result.cutoffIndex ?? -1,
        contextBreakdown: {
            ...result.contextBreakdown,
            memory: memoryTokens || 0,
            memoryReserve: effectiveReserve,
            vectorLore: (result.contextBreakdown.vectorLore || 0) + vectorLoreTokens,
            summaryBase: result.contextBreakdown.summary || 0,
            summary: (result.contextBreakdown.summary || 0) + actualMemory,
            fixedBase: newFixedBase,
            fixedTotal: newFixedTotal,
            totalUsed: newTotalUsed,
            remaining: Math.max(0, contextSize - newTotalUsed)
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
