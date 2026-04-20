import { cleanText } from '@/utils/textFormatter.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { startNetworkTrace, updateNetworkTrace, appendNetworkTraceLine, finishNetworkTrace } from '@/core/services/networkDebugService.js';
import { getProviderById } from '@/core/llm/providers/providerRegistry.js';
import { completeStructuredResponse, finalizeStreamResponse, handleAbortOutcome, handleRequestFailure } from '@/core/llm/transport/requestOutcome.js';
import { executeFetchRequest, executeNativeNonStreamingRequest, shouldUseNativeNonStreamingRequest, validateFetchResponse } from '@/core/llm/transport/requestExecution.js';
import { setupRequestRuntimePolicy } from '@/core/llm/transport/requestRuntimePolicy.js';
import { createStreamAccumulator } from '@/core/llm/transport/streamAccumulator.js';
import { consumeSseDataLines, getTrailingSseDataLine } from '@/core/llm/transport/sseParser.js';
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

    // Timeout configuration (configurable via localStorage for future settings UI)
    const CONNECT_TIMEOUT = parseInt(localStorage.getItem('gz_api_connect_timeout')) || 90000;
    const STREAM_TIMEOUT = parseInt(localStorage.getItem('gz_api_stream_timeout')) || 120000;
    let connectTimer = null;
    let streamTimer = null;
    let timedOut = false;
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

    const createAbortError = () => {
        const error = new Error('Generation aborted');
        error.name = 'AbortError';
        return error;
    };

    const throwIfAborted = () => {
        if (controller?.signal?.aborted) {
            throw createAbortError();
        }
    };

    const headers = {
        'Content-Type': 'application/json'
    };
    Object.assign(headers, provider.buildAuthHeaders(apiKey));

    startNetworkTrace({
        requestType,
        apiUrl,
        stream,
        requestBody,
        headers
    });

    try {
        logger.debug("LLM Request Body:", JSON.stringify(requestBody, null, 2));

        // Bypass Mixed Content/Cleartext restrictions on Native for local HTTP
        // Use CapacitorHttp only for non-streaming requests.
        // For streaming, we fall through to standard fetch (requires android:usesCleartextTraffic="true")
        if (shouldUseNativeNonStreamingRequest({ apiUrl, stream })) {
            const data = await executeNativeNonStreamingRequest({
                requestUrl,
                headers,
                requestBody,
                connectTimeout: CONNECT_TIMEOUT,
                streamTimeout: STREAM_TIMEOUT
            });
            throwIfAborted();

            completeStructuredResponse({
                data,
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
        connectTimer = setTimeout(() => { timedOut = true; if (controller) controller.abort(); }, CONNECT_TIMEOUT);

        const response = await executeFetchRequest({
            requestUrl,
            headers,
            requestBody,
            controller
        });

        throwIfAborted();

        clearTimeout(connectTimer);
        connectTimer = null;

        await validateFetchResponse(response);

        if (stream) {
            const contentType = (response.headers.get('content-type') || '').toLowerCase();
            const supportsStreamingBody = !!response.body && typeof response.body.getReader === 'function';
            const isSseResponse = contentType.includes('text/event-stream');

            if (!supportsStreamingBody || !isSseResponse) {
                if (!supportsStreamingBody) {
                    console.warn('[llmApi] Streaming body is unavailable on this platform/runtime, falling back to non-streaming response handling.');
                } else {
                    console.warn('[llmApi] Stream requested but provider returned a non-SSE response, falling back to non-streaming handling.', { contentType });
                }

                const data = await response.json();
                throwIfAborted();

                completeStructuredResponse({
                    data,
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

            const reader = response.body.getReader();
            const decoder = new TextDecoder("utf-8");
            let pendingLineBuffer = '';

            const resetStreamTimer = () => {
                if (streamTimer) clearTimeout(streamTimer);
                streamTimer = setTimeout(() => { timedOut = true; if (controller) controller.abort(); }, STREAM_TIMEOUT);
            };
            resetStreamTimer();

            while (true) {
                throwIfAborted();
                const { done, value } = await reader.read();
                if (done) break;
                resetStreamTimer();
                throwIfAborted();

                const chunk = decoder.decode(value, { stream: true });
                const parsedChunk = consumeSseDataLines(pendingLineBuffer, chunk);
                pendingLineBuffer = parsedChunk.remaining;

                for (const dataStr of parsedChunk.dataLines) {
                    appendNetworkTraceLine(dataStr);
                    throwIfAborted();

                    try {
                        const json = JSON.parse(dataStr);

                        if (json.error) {
                            throw new Error("API Stream Error: " + (json.error.message || JSON.stringify(json.error)));
                        }

                        if (!json.choices || !json.choices.length) continue;

                        const delta = json.choices[0].delta;
                        if (delta && (delta.content || delta.reasoning_content)) {
                            const content = delta.content || "";
                            const reasoning = (requestReasoning && delta.reasoning_content) || null;

                            if (content) logger.debug(content);

                            const { effectiveText, effectiveReasoning, textDelta } = streamAccumulator.consumeDelta({
                                content,
                                reasoning
                            });

                            if (onUpdate) onUpdate(content, reasoning, effectiveText, effectiveReasoning, textDelta);
                        }
                    } catch (e) {
                        if (e.message && e.message.startsWith("API Stream Error")) {
                            throw e;
                        }
                        console.warn("Error parsing stream chunk", e);
                    }
                }
            }

            const trailingDataLine = getTrailingSseDataLine(pendingLineBuffer);
            if (trailingDataLine) {
                appendNetworkTraceLine(trailingDataLine);
            }

            if (streamTimer) { clearTimeout(streamTimer); streamTimer = null; }
            throwIfAborted();

            finalizeStreamResponse({
                streamAccumulator,
                onComplete
            });

        } else {
            const data = await response.json();
            throwIfAborted();

            completeStructuredResponse({
                data,
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
                timedOut,
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
        if (connectTimer) clearTimeout(connectTimer);
        if (streamTimer) clearTimeout(streamTimer);
        await runtimePolicy.cleanup();
    }
}
