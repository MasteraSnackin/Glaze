import { runPreparedChatPrompt } from '@/core/llm/usecases/chatPreparation.js';

export async function executePreparedChatPrompt({
    preparedRequest,
    onError,
    deps
}) {
    const {
        t,
        showBottomSheet,
        closeBottomSheet,
        openApiSheet
    } = deps;
    const {
        apiConfig,
        tagStart,
        tagEnd,
        stopString,
        requestReasoning,
        reasoningEffort,
        maxTokens,
        contextSize,
        varsKey,
        safeHistory,
        controller
    } = preparedRequest;
    const {
        providerId,
        apiKey,
        apiUrl,
        model,
        stream,
        temp,
        topP
    } = apiConfig;

    if (!apiUrl || !model) {
        showBottomSheet({
            title: t('section_connection') || 'Connection',
            bigInfo: {
                icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;"><path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.04.24.24.41.48.41h3.84c.24 0 .43-.17.47-.41l.36-2.54c.59-.24 1.13-.57 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"/></svg>',
                description: t('api_not_configured') || 'API Not Configured',
                buttonText: t('btn_configure') || 'Configure',
                onButtonClick: () => {
                    closeBottomSheet();
                    openApiSheet();
                }
            }
        });
        if (onError) onError(new Error('API Not Configured'));
        return null;
    }

    let result;
    try {
        ({ result } = await runPreparedChatPrompt(preparedRequest));
    } catch (e) {
        console.error('Worker error:', e);
        if (onError) onError(e);
        return null;
    }

    if (controller?.signal?.aborted) {
        if (onError) onError(new DOMException('Aborted', 'AbortError'));
        return null;
    }

    if (result.needsVarsSave) {
        localStorage.setItem(varsKey, JSON.stringify(result.sessionVars));
    }

    return {
        result,
        safeHistory,
        contextSize,
        maxTokens,
        memoryReserve: preparedRequest.memoryReserve || 0,
        requestConfig: {
            providerId,
            apiUrl,
            apiKey,
            model,
            temperature: temp,
            topP,
            stream,
            reasoningEffort,
            stopString,
            controller,
            requestReasoning,
            tagStart,
            tagEnd
        }
    };
}
