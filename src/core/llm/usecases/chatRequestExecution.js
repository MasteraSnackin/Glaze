import { buildChatRequestPayload } from '@/core/llm/assemblers/requestAssemblers.js';
import { executeRequest } from '@/core/services/llmApi.js';
import { sendMessageNotification } from '@/core/services/notificationService.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { logger } from '@/utils/logger.js';

function getTranslation(key) {
    return translations[currentLang.value]?.[key] || key;
}

export async function executeFinalChatRequest({
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
    callbacks,
    onPreviewReady
}) {
    const { onUpdate, onComplete, onError } = callbacks;
    const { previewBody, requestBody } = buildChatRequestPayload({
        providerId,
        model,
        messages,
        temperature,
        topP,
        stream,
        reasoningEffort,
        maxTokens,
        stopString
    });

    onPreviewReady?.(previewBody);

    if (controller?.signal?.aborted) {
        if (onError) onError(new DOMException('Aborted', 'AbortError'));
        return;
    }

    try {
        logger.debug('[GenerationService] Final Request:', requestBody);
        await executeRequest({
            providerId,
            apiUrl,
            apiKey,
            requestBody,
            stream,
            controller,
            requestReasoning,
            tagStart,
            tagEnd,
            requestType: 'chat',
            callbacks: { onUpdate, onComplete, onError }
        });
    } catch (error) {
        console.error('Generation error:', error);
        sendMessageNotification(
            getTranslation('error_generation') || 'Generation Error',
            error.message,
            null,
            char?.id,
            null,
            null
        );
        if (onError) onError(error);
    }
}
