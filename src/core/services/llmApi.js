import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { getProviderById } from '@/core/llm/providers/providerRegistry.js';
import { completeStructuredResponse, finalizeStreamResponse, handleAbortOutcome, handleRequestFailure } from '@/core/llm/transport/requestOutcome.js';
import { executeFetchRequest, executeNativeNonStreamingRequest, shouldUseNativeNonStreamingRequest, validateFetchResponse } from '@/core/llm/transport/requestExecution.js';
import { createRequestLifecycle } from '@/core/llm/transport/requestLifecycle.js';
import { completeJsonResponse, getStreamingResponseMode } from '@/core/llm/transport/responseHandling.js';
import { setupRequestRuntimePolicy } from '@/core/llm/transport/requestRuntimePolicy.js';
import { createStreamAccumulator } from '@/core/llm/transport/streamAccumulator.js';
import { consumeStreamingSseResponse } from '@/core/llm/transport/streamingSse.js';
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

        // Connection timeout — abort if server doesn't respond
        requestLifecycle.startConnectTimeout();

        const response = await executeFetchRequest({
            requestUrl,
            headers: requestLifecycle.headers,
            requestBody,
            controller
        });

        requestLifecycle.throwIfAborted();

        requestLifecycle.clearConnectTimeout();

        await validateFetchResponse(response);

        if (stream) {
            const { contentType, supportsStreamingBody, canStreamSse } = getStreamingResponseMode(response);

            if (!canStreamSse) {
                if (!supportsStreamingBody) {
                    console.warn('[llmApi] Streaming body is unavailable on this platform/runtime, falling back to non-streaming response handling.');
                } else {
                    console.warn('[llmApi] Stream requested but provider returned a non-SSE response, falling back to non-streaming handling.', { contentType });
                }

                await completeJsonResponse({
                    response,
                    throwIfAborted: requestLifecycle.throwIfAborted,
                    contextLabel: 'API response structure (stream fallback)',
                    logLabel: 'LLM Response (stream fallback):',
                    requestReasoning,
                    hasInlineTags,
                    tagStart,
                    tagEnd,
                    headerModel,
                    headerInline,
                    onComplete
                });
                return;
            }

            await consumeStreamingSseResponse({
                responseBody: response.body,
                controller: requestLifecycle.createStreamingTimeoutController(),
                streamTimeout: requestLifecycle.streamTimeout,
                throwIfAborted: requestLifecycle.throwIfAborted,
                requestReasoning,
                streamAccumulator,
                onUpdate
            });

            finalizeStreamResponse({
                streamAccumulator,
                onComplete
            });

        } else {
            await completeJsonResponse({
                response,
                throwIfAborted: requestLifecycle.throwIfAborted,
                contextLabel: 'API response structure',
                logLabel: 'LLM Response:',
                requestReasoning,
                hasInlineTags,
                tagStart,
                tagEnd,
                headerModel,
                headerInline,
                onComplete
            });
        }
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
