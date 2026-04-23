import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { PipelineContext } from './chatPipelineContext.js';

export async function stepVectorSearch(ctx, deps) {
    const { vectorSearchLorebooks, mergeLateVectorLoreEntries } = deps;
    ctx.logStep('vectorSearch');

    if (ctx.isAborted) return;

    let newVectorEntries = [];
    try {
        const vectorResults = await vectorSearchLorebooks(
            ctx.safeHistory || ctx.history,
            ctx.text,
            ctx.char,
            ctx.char?.sessionId
        );
        if (vectorResults.length > 0) {
            ({ vectorEntries: newVectorEntries } = mergeLateVectorLoreEntries(ctx.result, vectorResults));
        }
    } catch (e) {
        ctx._vectorSearchError = e;
        return;
    }

    ctx._newVectorEntries = newVectorEntries;
}

export async function stepMemoryInjection(ctx, deps) {
    const { buildPromptMemoryInjection, injectMemoryMessages } = deps;
    ctx.logStep('memoryInjection');

    if (ctx.isAborted) return;

    const memoryInjection = await buildPromptMemoryInjection({
        char: ctx.char,
        history: ctx.safeHistory || ctx.history,
        summary: ctx.summary,
        safeContext: ctx.safeContext,
        result: ctx.result
    });

    ctx.memoryInjection = memoryInjection;
    ctx.memoryTokens = memoryInjection.tokens || 0;
    ctx.memoryEntries = memoryInjection.entries || [];

    if (memoryInjection.messages.length > 0) {
        ctx.messages = injectMemoryMessages(ctx.messages, memoryInjection, {
            injectionTarget: memoryInjection.injectionTarget
        });
    }
}

export async function stepLateVectorLoreInjection(ctx, deps) {
    const { injectLateVectorLoreMessages } = deps;
    ctx.logStep('lateVectorLoreInjection');

    if (ctx.isAborted) return;

    const newVectorEntries = ctx._newVectorEntries || [];
    if (newVectorEntries.length > 0) {
        ({ messages: ctx.messages, vectorLoreTokens: ctx.vectorLoreTokens } = injectLateVectorLoreMessages({
            messages: ctx.messages,
            newVectorEntries,
            safeContext: ctx.safeContext
        }));
    }
}

export function stepContextLimitGuard(ctx, deps) {
    const { t, showBottomSheet, closeBottomSheet } = deps;
    ctx.logStep('contextLimitGuard');

    if (ctx.isAborted) return;

    if (ctx.result.staticTokens >= ctx.safeContext) {
        showBottomSheet({
            title: t('error_context_limit') || 'Context Limit Exceeded',
            bigInfo: {
                icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;color:#ff4444"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>',
                description: t('msg_context_limit') || 'The preset prompts exceed the context limit. Please increase Context Size or reduce prompt length.',
                glossaryChip: { term: 'context', hint: t('context_limit_glossary_hint') || 'Learn more:', label: t('context_limit_glossary_chip') || 'Context' },
                buttonText: t('btn_ok') || 'OK',
                onButtonClick: () => closeBottomSheet()
            }
        });
        ctx.abort();
    }
}

export function stepPromptReady(ctx, deps) {
    const { buildMergedContextBreakdown } = deps;
    ctx.logStep('promptReady');

    if (ctx.isAborted) return;

    ctx.contextBreakdown = buildMergedContextBreakdown(ctx.result.contextBreakdown, {
        vectorLoreTokens: ctx.vectorLoreTokens,
        memoryTokens: ctx.memoryTokens,
        memoryReserve: ctx.memoryReserve
    });

    const { onPromptReady } = ctx.callbacks;
    if (onPromptReady) {
        onPromptReady({
            loreEntries: ctx.loreEntries,
            memoryEntries: ctx.memoryEntries,
            contextBreakdown: ctx.contextBreakdown
        });
    }

    publishAppEvent(APP_EVENTS.domain.generation.promptReady, {
        debugKey: ctx.requestConfig?.debugKey,
        charId: ctx.char?.id,
        sessionId: ctx.char?.sessionId,
        loreEntryCount: ctx.loreEntries?.length || 0,
        memoryEntryCount: ctx.memoryEntries?.length || 0,
        contextBreakdown: ctx.contextBreakdown
    });
}

export async function stepRequestExecution(ctx, deps) {
    const { executeFinalChatRequest, setLastPrompt } = deps;
    ctx.logStep('requestExecution');

    if (ctx.isAborted) {
        const { onError } = ctx.callbacks;
        if (onError) onError(new DOMException('Aborted', 'AbortError'));
        return;
    }

    const { requestConfig } = ctx;
    publishAppEvent(APP_EVENTS.domain.generation.requestDispatched, {
        debugKey: requestConfig?.debugKey,
        charId: ctx.char?.id,
        sessionId: ctx.char?.sessionId,
        messageCount: ctx.messages?.length || 0,
        requestType: 'chat'
    });

    await executeFinalChatRequest({
        char: ctx.char,
        ...requestConfig,
        messages: ctx.messages,
        callbacks: ctx.callbacks,
        onPreviewReady: (previewBody) => {
            setLastPrompt(JSON.parse(JSON.stringify(previewBody)));
        }
    });
}

export const PIPELINE_STEPS = [
    { name: 'vectorSearch', fn: stepVectorSearch },
    { name: 'memoryInjection', fn: stepMemoryInjection },
    { name: 'lateVectorLoreInjection', fn: stepLateVectorLoreInjection },
    { name: 'contextLimitGuard', fn: stepContextLimitGuard },
    { name: 'promptReady', fn: stepPromptReady },
    { name: 'requestExecution', fn: stepRequestExecution }
];
