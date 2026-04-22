export async function runChatPostPromptPipeline({
    text,
    char,
    history,
    safeHistory,
    summary,
    contextSize,
    maxTokens,
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
    const {
        onUpdate,
        onComplete,
        onError,
        onPromptReady
    } = callbacks;
    const {
        providerId,
        apiUrl,
        apiKey,
        model,
        temperature,
        topP,
        stream,
        reasoningEffort,
        stopString,
        controller,
        requestReasoning,
        tagStart,
        tagEnd
    } = requestConfig;

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
        ({ messages, vectorLoreTokens } = injectLateVectorLoreMessages({
            messages,
            newVectorEntries,
            safeContext
        }));
    }

    if (result.staticTokens >= safeContext) {
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
        if (onError) onError(new Error('Context limit exceeded'));
        return;
    }

    if (onPromptReady) {
        const contextBreakdown = buildMergedContextBreakdown(result.contextBreakdown, {
            vectorLoreTokens,
            memoryTokens: memoryInjection.tokens || 0
        });

        onPromptReady({
            loreEntries: result.loreEntries,
            memoryEntries: memoryInjection.entries,
            contextBreakdown
        });
    }

    await executeFinalChatRequest({
        char,
        providerId,
        apiUrl,
        apiKey,
        model,
        messages,
        temperature,
        topP,
        stream,
        reasoningEffort,
        maxTokens,
        stopString,
        controller,
        requestReasoning,
        tagStart,
        tagEnd,
        callbacks: { onUpdate, onComplete, onError },
        onPreviewReady: (previewBody) => {
            setLastPrompt(JSON.parse(JSON.stringify(previewBody)));
        }
    });
}
