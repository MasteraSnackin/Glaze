import { cleanText } from '@/utils/textFormatter.js';
import { finishNetworkTrace } from '@/core/services/networkDebugService.js';
import { extractOpenAiMessage, normalizeReasoningOutput } from '@/core/llm/transport/responseNormalizer.js';
import { logger } from '../../../utils/logger.js';

export function completeStructuredResponse({
    data,
    contextLabel,
    logLabel,
    requestReasoning,
    hasInlineTags,
    tagStart,
    tagEnd,
    headerModel,
    headerInline,
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

    const cleanedText = cleanText(normalized.text);
    finishNetworkTrace({ rawResponse: data, text: cleanedText, reasoning: normalized.reasoning });
    if (onComplete) onComplete(cleanedText, normalized.reasoning, { allReasoning: normalized.allReasoning });
}

export function finalizeStreamResponse({ streamAccumulator, onComplete }) {
    const finalResult = streamAccumulator.finalize();
    const finalText = cleanText(finalResult.text);

    logger.debug('Stream finished:', finalResult.text);

    finishNetworkTrace({
        rawResponse: {
            mode: 'sse',
            eventCount: null
        },
        text: finalText,
        reasoning: finalResult.reasoning
    });

    if (onComplete) onComplete(finalText, finalResult.reasoning, { allReasoning: finalResult.allReasoning });
}

export function handleAbortOutcome({ timedOut, streamAccumulator, onComplete, onError, abortError }) {
    const partial = streamAccumulator.getPartial();
    const hasPartialContent = partial.text.length > 0 || (partial.reasoning && partial.reasoning.length > 0);
    const allReasoning = !partial.text.trim() && !!partial.reasoning?.trim();

    if (timedOut) {
        if (hasPartialContent) {
            finishNetworkTrace({ text: cleanText(partial.text), reasoning: partial.reasoning, error: 'Generation timed out' });
            if (onComplete) onComplete(cleanText(partial.text), partial.reasoning, { partialError: 'Generation timed out', allReasoning });
        } else {
            finishNetworkTrace({ error: 'Generation timed out - no response from server' });
            if (onError) onError(new Error('Generation timed out - no response from server'));
        }
        return;
    }

    if (hasPartialContent) {
        finishNetworkTrace({ text: cleanText(partial.text), reasoning: partial.reasoning, error: 'Generation aborted' });
        if (onComplete) onComplete(cleanText(partial.text), partial.reasoning, { allReasoning });
        return;
    }

    finishNetworkTrace({ error: abortError });
    if (onError) onError(abortError);
}

export function handleRequestFailure({ error, streamAccumulator, onComplete, onError }) {
    const partial = streamAccumulator.getPartial();
    const hasPartialContent = partial.text.length > 0 || (partial.reasoning && partial.reasoning.length > 0);
    const allReasoning = !partial.text.trim() && !!partial.reasoning?.trim();

    if (hasPartialContent) {
        console.warn('Network error during stream, saving partial response:', error);
        const errorMsg = error.message || 'Stream Error';
        finishNetworkTrace({ text: cleanText(partial.text), reasoning: partial.reasoning, error: errorMsg });
        if (onComplete) onComplete(cleanText(partial.text), partial.reasoning, { partialError: errorMsg });
        return;
    }

    finishNetworkTrace({ error });
    if (onError) onError(error);
}
