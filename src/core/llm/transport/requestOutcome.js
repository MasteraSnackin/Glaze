import { cleanText } from '@/utils/textFormatter.js';
import { runGenerationHook } from '@/core/extensions/extensionRegistry.js';
import { finishNetworkTrace } from '@/core/services/networkDebugService.js';
import { extractOpenAiMessage, normalizeReasoningOutput } from '@/core/llm/transport/responseNormalizer.js';
import { logger } from '../../../utils/logger.js';

async function applyNormalizedResponseExtensions({
    requestType,
    debugKey,
    text,
    reasoning,
    meta = undefined,
    rawResponse = undefined
}) {
    const hookResult = await runGenerationHook('afterResponseNormalize', {
        requestType,
        debugKey,
        text,
        reasoning,
        meta,
        rawResponse
    });

    if (!hookResult || typeof hookResult !== 'object') {
        return { text, reasoning, meta, rawResponse };
    }

    return {
        text: hookResult.text === undefined ? text : hookResult.text,
        reasoning: hookResult.reasoning === undefined ? reasoning : hookResult.reasoning,
        meta: hookResult.meta === undefined ? meta : hookResult.meta,
        rawResponse: hookResult.rawResponse === undefined ? rawResponse : hookResult.rawResponse
    };
}

export async function completeStructuredResponse({
    data,
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
    onComplete
}) {
    logger.debug(logLabel, data);

    const { content, reasoningContent } = extractOpenAiMessage(data, contextLabel);
    const normalized = normalizeReasoningOutput({
        content,
        requestReasoning,
        rawReasoning: reasoningContent,
        hasInlineTags,
        tagStart,
        tagEnd,
        headerModel,
        headerInline
    });

    const extended = await applyNormalizedResponseExtensions({
        requestType,
        debugKey,
        text: normalized.text,
        reasoning: normalized.reasoning,
        rawResponse: data
    });

    const cleanedText = cleanText(extended.text || '');
    finishNetworkTrace({ debugKey, rawResponse: extended.rawResponse, text: cleanedText, reasoning: extended.reasoning });
    if (onComplete) onComplete(cleanedText, extended.reasoning, extended.meta);
}

export async function finalizeStreamResponse({ requestType, debugKey, streamAccumulator, onComplete }) {
    const finalResult = streamAccumulator.finalize();
    const extended = await applyNormalizedResponseExtensions({
        requestType,
        debugKey,
        text: finalResult.text,
        reasoning: finalResult.reasoning,
        rawResponse: {
            mode: 'sse',
            eventCount: null
        }
    });
    const finalText = cleanText(extended.text || '');

    logger.debug('Stream finished:', finalResult.text);

    finishNetworkTrace({
        debugKey,
        rawResponse: extended.rawResponse,
        text: finalText,
        reasoning: extended.reasoning
    });

    if (onComplete) onComplete(finalText, extended.reasoning, extended.meta);
}

export async function handleAbortOutcome({ requestType, debugKey, timedOut, streamAccumulator, onComplete, onError, abortError }) {
    const partial = streamAccumulator.getPartial();

    if (timedOut) {
        if (partial.text.length > 0) {
            const extended = await applyNormalizedResponseExtensions({
                requestType,
                debugKey,
                text: partial.text,
                reasoning: partial.reasoning,
                meta: { partialError: 'Generation timed out' }
            });
            const partialText = cleanText(extended.text || '');
            finishNetworkTrace({ debugKey, text: partialText, reasoning: extended.reasoning, error: 'Generation timed out' });
            if (onComplete) onComplete(partialText, extended.reasoning, extended.meta);
        } else {
            finishNetworkTrace({ debugKey, error: 'Generation timed out - no response from server' });
            if (onError) onError(new Error('Generation timed out - no response from server'));
        }
        return;
    }

    if (partial.text.length > 0) {
        const extended = await applyNormalizedResponseExtensions({
            requestType,
            debugKey,
            text: partial.text,
            reasoning: partial.reasoning
        });
        const partialText = cleanText(extended.text || '');
        finishNetworkTrace({ debugKey, text: partialText, reasoning: extended.reasoning, error: 'Generation aborted' });
        if (onComplete) onComplete(partialText, extended.reasoning, extended.meta);
        return;
    }

    finishNetworkTrace({ debugKey, error: abortError });
    if (onError) onError(abortError);
}

export async function handleRequestFailure({ requestType, debugKey, error, streamAccumulator, onComplete, onError }) {
    const partial = streamAccumulator.getPartial();
    if (partial.text.length > 0) {
        console.warn('Network error during stream, saving partial response:', error);
        const errorMsg = error.message || 'Stream Error';
        const extended = await applyNormalizedResponseExtensions({
            requestType,
            debugKey,
            text: partial.text,
            reasoning: partial.reasoning,
            meta: { partialError: errorMsg }
        });
        const partialText = cleanText(extended.text || '');
        finishNetworkTrace({ debugKey, text: partialText, reasoning: extended.reasoning, error: errorMsg });
        if (onComplete) onComplete(partialText, extended.reasoning, extended.meta);
        return;
    }

    finishNetworkTrace({ debugKey, error });
    if (onError) onError(error);
}
