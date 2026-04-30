import { PipelineContext, validateStepOrder } from './pipelineContext.js';
import { PIPELINE_STEPS, stepVectorSearch } from './steps.js';

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
    }

    if (ctx._aborted && ctx.stepLog.some(s => s.step === 'contextLimitGuard')) {
        const { onError } = callbacks;
        if (onError) onError(new Error('Context limit exceeded'));
        return;
    }

    if (ctx.isAborted) {
        const { onError } = callbacks;
        if (onError) {
            const abortErr = new DOMException('Aborted', 'AbortError');
            if (ctx.controller?.userAborted) {
                abortErr.userAborted = true;
            }
            onError(abortErr);
        }
        return;
    }

    return ctx;
}
