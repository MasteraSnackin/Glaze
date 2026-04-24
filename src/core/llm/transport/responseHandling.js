import { completeStructuredResponse } from '@/core/llm/transport/requestOutcome.js';

export function getStreamingResponseMode(response) {
    const contentType = (response.headers.get('content-type') || '').toLowerCase();
    const supportsStreamingBody = !!response.body && typeof response.body.getReader === 'function';
    const isSseResponse = contentType.includes('text/event-stream');

    return {
        contentType,
        supportsStreamingBody,
        isSseResponse,
        canStreamSse: supportsStreamingBody && isSseResponse
    };
}

export async function completeJsonResponse({
    response,
    data,
    throwIfAborted,
    contextLabel,
    logLabel,
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
}) {
    const resolvedData = data ?? await response.json();
    throwIfAborted();

    await completeStructuredResponse({
        data: resolvedData,
        contextLabel,
        logLabel,
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
}
