import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { getProviderById } from '@/core/llm/providers/providerRegistry.js';
import { completeStructuredResponse, handleAbortOutcome, handleRequestFailure } from '@/core/llm/transport/requestOutcome.js';
import { executeNativeNonStreamingRequest, shouldUseNativeNonStreamingRequest } from '@/core/llm/transport/requestExecution.js';
import { executeFetchChatCompletions } from '@/core/llm/transport/chatCompletionsClient.js';
import { createRequestLifecycle } from '@/core/llm/transport/requestLifecycle.js';
import { completeJsonResponse } from '@/core/llm/transport/responseHandling.js';
import { setupRequestRuntimePolicy } from '@/core/llm/transport/requestRuntimePolicy.js';
import { createStreamAccumulator } from '@/core/llm/transport/streamAccumulator.js';
import { logger } from '../../utils/logger.js';

export async function executeRequest({
    providerId,
    apiUrl,
    apiKey,
    requestBody,
    stream,
    controller,
    requestReasoning,
    tagStart,
    tagEnd,
    requestType,
    callbacks
}) {
    const { onUpdate, onComplete, onError } = callbacks;
    const t = (key) => translations[currentLang.value]?.[key] || key;
    const headerModel = `<span style="color: var(--vk-blue); font-weight: 700; font-size: 0.85em; text-transform: uppercase; letter-spacing: 0.5px;">${t('reasoning_model')}</span>`;
    const headerInline = `<span style="color: var(--vk-blue); font-weight: 700; font-size: 0.85em; text-transform: uppercase; letter-spacing: 0.5px;">${t('reasoning_inline')}</span>`;
    const provider = getProviderById(providerId);
    const requestUrl = provider.buildChatCompletionsUrl(apiUrl);

    const hasInlineTags = !!tagStart && !!tagEnd;
    const runtimePolicy = await setupRequestRuntimePolicy({
        notificationTitle: 'Glaze',
        notificationBody: translations[currentLang.value]['model_typing'] || 'Generating...'
    });

    const streamAccumulator = createStreamAccumulator({
        requestReasoning,
        tagStart,
        tagEnd,
        hasInlineTags,
        headerModel,
        headerInline
    });

    const requestLifecycle = createRequestLifecycle({
        provider,
        apiKey,
        controller,
        requestType,
        apiUrl,
        stream,
        requestBody
    });

    try {
        logger.debug("LLM Request Body:", JSON.stringify(requestBody, null, 2));

        // Bypass Mixed Content/Cleartext restrictions on Native for local HTTP
        // Use CapacitorHttp only for non-streaming requests.
        // For streaming, we fall through to standard fetch (requires android:usesCleartextTraffic="true")
        if (shouldUseNativeNonStreamingRequest({ apiUrl, stream })) {
            const data = await executeNativeNonStreamingRequest({
                requestUrl,
                headers: requestLifecycle.headers,
                requestBody,
                connectTimeout: requestLifecycle.connectTimeout,
                streamTimeout: requestLifecycle.streamTimeout
            });
            requestLifecycle.throwIfAborted();

            await completeJsonResponse({
                data,
                throwIfAborted: requestLifecycle.throwIfAborted,
                contextLabel: 'API response structure (Native)',
                logLabel: 'LLM Response (Native):',
                requestReasoning,
                hasInlineTags,
                tagStart,
                tagEnd,
                headerModel,
                headerInline,
                onComplete
            });

            // Exit function, finally block will still run for cleanup
            return;
        }

        await executeFetchChatCompletions({
            requestUrl,
            requestBody,
            controller,
            requestLifecycle,
            stream,
            requestReasoning,
            hasInlineTags,
            tagStart,
            tagEnd,
            headerModel,
            headerInline,
            streamAccumulator,
            onUpdate,
            onComplete
        });
    } catch (e) {
        if (e.name === 'AbortError') {
            handleAbortOutcome({
                timedOut: requestLifecycle.timedOut,
                streamAccumulator,
                onComplete,
                onError,
                abortError: e
            });
            return;
        }

        handleRequestFailure({
            error: e,
            streamAccumulator,
            onComplete,
            onError
        });
    } finally {
        requestLifecycle.clearConnectTimeout();
        await runtimePolicy.cleanup();
    }
}
