import { PipelineContext, validateStepOrder } from './chatPipelineContext.js';
import { PIPELINE_STEPS, stepVectorSearch } from './chatPipelineSteps.js';

export { PipelineContext };

export async function runChatPostPromptPipeline({
    text,
    char,
    history,
    safeHistory,
    summary,
    contextSize,
    maxTokens,
    memoryReserve = 0,
    result,
    requestConfig,
    callbacks,
    deps
}) {
    const {
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
        setLastPrompt
    } = deps;

    const ctx = new PipelineContext({
        text,
        char,
        history,
        safeHistory,
        summary,
        contextSize,
        maxTokens,
        memoryReserve,
        result,
        controller: requestConfig?.controller,
        callbacks
    });

    ctx.requestConfig = requestConfig;

    const pipelineDeps = {
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
        setLastPrompt
    };

    for (const step of PIPELINE_STEPS) {
        if (ctx.isAborted) break;
        await step.fn(ctx, pipelineDeps);
    }

    if (ctx._vectorSearchError) {
        const e = ctx._vectorSearchError;
        console.warn('[generateChatResponse] Vector search failed:', e);
        // Degrade gracefully: generation can continue without vector lorebook
        // results when the embedding provider is temporarily unavailable.
    }

    if (ctx._aborted && ctx.stepLog.some(s => s.step === 'contextLimitGuard')) {
        const { onError } = callbacks;
        if (onError) onError(new Error('Context limit exceeded'));
        return;
    }

    return ctx;
}
