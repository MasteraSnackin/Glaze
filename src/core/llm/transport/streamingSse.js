import { appendNetworkTraceLine } from '@/core/services/networkDebugService.js';
import { consumeSseDataLines, getTrailingSseDataLine } from '@/core/llm/transport/sseParser.js';
import { logger } from '../../../utils/logger.js';

export async function consumeStreamingSseResponse({
    responseBody,
    debugKey,
    controller,
    streamTimeout,
    throwIfAborted,
    streamAccumulator,
    onUpdate,
    abortSignal
}) {
    const reader = responseBody.getReader();
    const decoder = new TextDecoder('utf-8');
    let pendingLineBuffer = '';
    let streamTimer = null;

    const resetStreamTimer = () => {
        if (streamTimer) clearTimeout(streamTimer);
        streamTimer = setTimeout(() => {
            if (controller) controller.abort();
        }, streamTimeout);
    };

    function readChunk() {
        if (abortSignal?.aborted) {
            try { reader.cancel(); } catch (_e) {}
            const error = new Error('Generation aborted');
            error.name = 'AbortError';
            return Promise.reject(error);
        }

        return new Promise((resolve, reject) => {
            let settled = false;

            const onAbort = () => {
                if (settled) return;
                settled = true;
                try { reader.cancel(); } catch (_e) {}
                const error = new Error('Generation aborted');
                error.name = 'AbortError';
                reject(error);
            };

            if (abortSignal && !abortSignal.aborted) {
                abortSignal.addEventListener('abort', onAbort, { once: true });
            }

            reader.read()
                .then(result => {
                    if (settled) return;
                    settled = true;
                    resolve(result);
                })
                .catch(err => {
                    if (settled) return;
                    settled = true;
                    reject(err);
                })
                .finally(() => {
                    if (abortSignal) {
                        abortSignal.removeEventListener('abort', onAbort);
                    }
                });
        });
    }

    try {
        resetStreamTimer();

        while (true) {
            throwIfAborted();
            const { done, value } = await readChunk();
            if (done) break;

            resetStreamTimer();
            throwIfAborted();

            const chunk = decoder.decode(value, { stream: true });
            const parsedChunk = consumeSseDataLines(pendingLineBuffer, chunk);
            pendingLineBuffer = parsedChunk.remaining;

            for (const dataStr of parsedChunk.dataLines) {
                appendNetworkTraceLine({ debugKey, line: dataStr });
                throwIfAborted();

                try {
                    const json = JSON.parse(dataStr);

                    if (json.error) {
                        throw new Error(`API Stream Error: ${json.error.message || JSON.stringify(json.error)}`);
                    }

                    if (!json.choices || !json.choices.length) continue;

                    const delta = json.choices[0].delta;
                    if (delta && (delta.content || delta.reasoning_content)) {
                        const content = delta.content || '';
                        const reasoning = delta.reasoning_content || null;

                        if (content) logger.debug(content);

                        const { effectiveText, effectiveReasoning, textDelta } = streamAccumulator.consumeDelta({
                            content,
                            reasoning
                        });

                        if (onUpdate) onUpdate(content, reasoning, effectiveText, effectiveReasoning, textDelta);
                    }
                } catch (e) {
                    if (e.message && e.message.startsWith('API Stream Error')) {
                        throw e;
                    }
                    console.warn('Error parsing stream chunk', e);
                }
            }
        }

        const trailingDataLine = getTrailingSseDataLine(pendingLineBuffer);
        if (trailingDataLine) {
            appendNetworkTraceLine({ debugKey, line: trailingDataLine });
        }

        throwIfAborted();
    } finally {
        if (streamTimer) clearTimeout(streamTimer);
    }
}
