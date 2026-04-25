import { executeFetchRequest, validateFetchResponse } from '@/core/llm/transport/requestExecution.js';
import { completeJsonResponse, getStreamingResponseMode } from '@/core/llm/transport/responseHandling.js';
import { finalizeStreamResponse } from '@/core/llm/transport/requestOutcome.js';
import { consumeStreamingSseResponse } from '@/core/llm/transport/streamingSse.js';

export async function executeFetchChatCompletions({
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
    debugKey,
    streamAccumulator,
    onUpdate,
    onComplete,
    onError
}) {
    requestLifecycle.startConnectTimeout();

    const response = await executeFetchRequest({
        requestUrl,
        headers: requestLifecycle.headers,
        requestBody,
        controller
    });

    requestLifecycle.throwIfAborted();
    requestLifecycle.clearConnectTimeout();

    await validateFetchResponse(response, debugKey);

    if (!stream) {
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
            requestType,
            debugKey,
            onComplete,
            onError
        });
        return;
    }

    const { contentType, supportsStreamingBody, canStreamSse } = getStreamingResponseMode(response);

    if (!canStreamSse) {
        if (!supportsStreamingBody) {
            console.warn('[transport] Streaming body is unavailable on this platform/runtime, falling back to non-streaming response handling.');
        } else {
            console.warn('[transport] Stream requested but provider returned a non-SSE response, falling back to non-streaming handling.', { contentType });
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
            requestType,
            debugKey,
            onComplete,
            onError
        });
        return;
    }

    await consumeStreamingSseResponse({
        responseBody: response.body,
        debugKey,
        controller: requestLifecycle.createStreamingTimeoutController(),
        streamTimeout: requestLifecycle.streamTimeout,
        throwIfAborted: requestLifecycle.throwIfAborted,
        streamAccumulator,
        onUpdate
    });

    await finalizeStreamResponse({
        requestType,
        debugKey,
        streamAccumulator,
        onComplete,
        onError
    });
}
