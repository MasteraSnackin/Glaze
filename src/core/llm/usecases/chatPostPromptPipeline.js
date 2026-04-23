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
        showBottomSheet({
            title: t('title_error') || 'Error',
            bigInfo: {
                icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;color:#ff9500"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>',
                description: t('msg_vector_generation_failed') || 'The embedding model did not respond during generation, so vector lorebook retrieval could not complete.',
                buttonText: t('btn_ok') || 'OK',
                onButtonClick: () => closeBottomSheet()
            }
        });
        const { onError } = callbacks;
        if (onError) onError(e);
        return;
    }

    if (ctx._aborted && ctx.stepLog.some(s => s.step === 'contextLimitGuard')) {
        const { onError } = callbacks;
        if (onError) onError(new Error('Context limit exceeded'));
        return;
    }

    return ctx;
}
