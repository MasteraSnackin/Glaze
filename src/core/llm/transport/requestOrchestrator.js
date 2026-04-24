import { getProviderById } from '@/core/llm/providers/providerRegistry.js';
import { completeStructuredResponse, handleAbortOutcome, handleRequestFailure } from '@/core/llm/transport/requestOutcome.js';
import { executeNativeNonStreamingRequest, shouldUseNativeNonStreamingRequest } from '@/core/llm/transport/requestExecution.js';
import { executeFetchChatCompletions } from '@/core/llm/transport/completionsClient.js';
import { createRequestLifecycle } from '@/core/llm/transport/requestLifecycle.js';
import { completeJsonResponse } from '@/core/llm/transport/responseHandling.js';
import { setupRequestRuntimePolicy } from '@/core/llm/transport/requestRuntimePolicy.js';
import { createStreamAccumulator } from '@/core/llm/transport/streamAccumulator.js';
import { logger } from '@/utils/logger.js';

export async function executeRequest({
    providerId,
    apiUrl,
    apiKey,
    requestBody,
    stream,
    debugKey,
    controller,
    requestReasoning,
    tagStart,
    tagEnd,
    requestType,
    headerModel,
    headerInline,
    notificationBody,
    callbacks
}) {
    const { onUpdate, onComplete, onError } = callbacks;
    const provider = getProviderById(providerId);
    const requestUrl = provider.buildChatCompletionsUrl(apiUrl);

    const hasInlineTags = !!tagStart && !!tagEnd;
    const runtimePolicy = await setupRequestRuntimePolicy({
        notificationTitle: 'Glaze',
        notificationBody: notificationBody || 'Generating...'
    });

    const streamAccumulator = createStreamAccumulator({
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
        debugKey,
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
                debugKey: requestLifecycle.debugKey,
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
                requestType,
                debugKey: requestLifecycle.debugKey,
                onComplete,
                onError
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
            requestType,
            debugKey: requestLifecycle.debugKey,
            streamAccumulator,
            onUpdate,
            onComplete,
            onError
        });
    } catch (e) {
        if (e.name === 'AbortError') {
            await handleAbortOutcome({
                requestType,
                debugKey: requestLifecycle.debugKey,
                timedOut: requestLifecycle.timedOut,
                streamAccumulator,
                onComplete,
                onError,
                abortError: e
            });
            return;
        }

        await handleRequestFailure({
            requestType,
            debugKey: requestLifecycle.debugKey,
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
