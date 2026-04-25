import { buildChatRequestPayload } from '@/core/llm/assemblers/requestAssemblers.js';
import { runGenerationHook } from '@/core/extensions/extensionRegistry.js';
import { executeRequest } from '@/core/llm/transport/requestOrchestrator.js';
import { sendMessageNotification } from '@/core/services/notificationService.js';
import { buildReasoningHeaders, getNotificationBody } from '@/core/llm/usecases/reasoningHeaders.js';
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
    debugKey,
    controller,
    requestReasoning,
    tagStart,
    tagEnd,
    callbacks,
    onPreviewReady
}) {
    const { onUpdate, onComplete, onError } = callbacks;
    const requestAssembly = await runGenerationHook('beforeRequestAssembly', {
        requestType: 'chat',
        debugKey,
        char,
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

    const {
        providerId: effectiveProviderId = providerId,
        model: effectiveModel = model,
        messages: effectiveMessages = messages,
        temperature: effectiveTemperature = temperature,
        topP: effectiveTopP = topP,
        stream: effectiveStream = stream,
        reasoningEffort: effectiveReasoningEffort = reasoningEffort,
        maxTokens: effectiveMaxTokens = maxTokens,
        stopString: effectiveStopString = stopString
    } = requestAssembly || {};

    const { previewBody, requestBody } = buildChatRequestPayload({
        providerId: effectiveProviderId,
        model: effectiveModel,
        messages: effectiveMessages,
        temperature: effectiveTemperature,
        topP: effectiveTopP,
        stream: effectiveStream,
        reasoningEffort: effectiveReasoningEffort,
        maxTokens: effectiveMaxTokens,
        stopString: effectiveStopString
    });

    const requestEnvelope = await runGenerationHook('beforeRequestSend', {
        requestType: 'chat',
        debugKey,
        char,
        providerId: effectiveProviderId,
        apiUrl,
        apiKey,
        model: effectiveModel,
        previewBody,
        requestBody,
        stream: effectiveStream,
        controller,
        requestReasoning,
        tagStart,
        tagEnd
    });

    const {
        providerId: requestProviderId = effectiveProviderId,
        apiUrl: requestApiUrl = apiUrl,
        apiKey: requestApiKey = apiKey,
        model: requestModel = effectiveModel,
        previewBody: finalPreviewBody = previewBody,
        requestBody: finalRequestBody = requestBody,
        stream: requestStream = effectiveStream,
        controller: requestController = controller,
        requestReasoning: finalRequestReasoning = requestReasoning,
        tagStart: finalTagStart = tagStart,
        tagEnd: finalTagEnd = tagEnd
    } = requestEnvelope || {};

    onPreviewReady?.(finalPreviewBody);

    if (requestController?.signal?.aborted) {
        if (onError) onError(new DOMException('Aborted', 'AbortError'));
        return;
    }

    try {
        const reasoningHeaders = buildReasoningHeaders();
        logger.debug('[GenerationService] Final Request:', finalRequestBody);
        await executeRequest({
            providerId: requestProviderId,
            apiUrl: requestApiUrl,
            apiKey: requestApiKey,
            requestBody: finalRequestBody,
            stream: requestStream,
            controller: requestController,
            requestReasoning: finalRequestReasoning,
            tagStart: finalTagStart,
            tagEnd: finalTagEnd,
            debugKey,
            requestType: 'chat',
            headerModel: reasoningHeaders.headerModel,
            headerInline: reasoningHeaders.headerInline,
            notificationBody: getNotificationBody(),
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
