import { Capacitor, CapacitorHttp } from '@capacitor/core';
import { cleanText } from '@/utils/textFormatter.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { startNetworkTrace, updateNetworkTrace, appendNetworkTraceLine, finishNetworkTrace } from '@/core/services/networkDebugService.js';
import { getProviderById } from '@/core/llm/providers/providerRegistry.js';
import { setupRequestRuntimePolicy } from '@/core/llm/transport/requestRuntimePolicy.js';
import { extractOpenAiMessage, normalizeReasoningOutput } from '@/core/llm/transport/responseNormalizer.js';
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

    const completeStructuredResponse = ({ data, contextLabel, logLabel }) => {
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
        if (onComplete) onComplete(cleanedText, normalized.reasoning);
    };

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
        if (Capacitor.isNativePlatform() && apiUrl.startsWith('http:') && !apiUrl.includes('https:') && !stream) {
            const response = await CapacitorHttp.post({
                url: requestUrl,
                headers: headers,
                data: requestBody,
                responseType: 'json',
                connectTimeout: CONNECT_TIMEOUT,
                readTimeout: STREAM_TIMEOUT
            });

            if (response.status >= 400) {
                const errorData = typeof response.data === 'object' ? JSON.stringify(response.data) : String(response.data || '');
                updateNetworkTrace({ responseStatus: response.status });
                finishNetworkTrace({ rawResponse: response.data, error: `API Error: ${response.status} ${errorData}` });
                throw new Error(`API Error: ${response.status} ${errorData}`);
            }

            const data = response.data;
            updateNetworkTrace({ responseStatus: response.status });
            throwIfAborted();

            completeStructuredResponse({
                data,
                contextLabel: 'API response structure (Native)',
                logLabel: 'LLM Response (Native):'
            });

            // Exit function, finally block will still run for cleanup
            return;
        }

        // Connection timeout — abort if server doesn't respond
        connectTimer = setTimeout(() => { timedOut = true; if (controller) controller.abort(); }, CONNECT_TIMEOUT);

        const response = await fetch(requestUrl, {
            method: 'POST',
            headers: headers,
            body: JSON.stringify(requestBody),
            signal: controller ? controller.signal : undefined
        });

        throwIfAborted();

        clearTimeout(connectTimer);
        connectTimer = null;

        if (!response.ok) {
            let errText = "";
            try { errText = await response.text(); } catch (e) { }
            updateNetworkTrace({ responseStatus: response.status, responseHeaders: Object.fromEntries(response.headers.entries()) });
            finishNetworkTrace({ rawResponse: errText, error: `API Error: ${response.status} ${errText}` });
            throw new Error(`API Error: ${response.status} ${errText}`);
        }

        updateNetworkTrace({
            responseStatus: response.status,
            responseHeaders: Object.fromEntries(response.headers.entries())
        });

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
                    logLabel: 'LLM Response (stream fallback):'
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

            // Final processing for onComplete
            const finalResult = streamAccumulator.finalize();
            const finalText = finalResult.text;
            const finalReasoning = finalResult.reasoning;

            logger.debug("Stream finished:", finalText);

            finishNetworkTrace({
                rawResponse: {
                    mode: 'sse',
                    eventCount: null
                },
                text: cleanText(finalText),
                reasoning: finalReasoning
            });

            if (onComplete) onComplete(cleanText(finalText), finalReasoning);

        } else {
            const data = await response.json();
            throwIfAborted();

            completeStructuredResponse({
                data,
                contextLabel: 'API response structure',
                logLabel: 'LLM Response:'
            });
        }
    } catch (e) {
        if (e.name === 'AbortError') {
            if (timedOut) {
                // Timeout-induced abort — treat as error, not user cancellation
                const partial = streamAccumulator.getPartial();
                if (partial.text.length > 0) {
                    finishNetworkTrace({ text: cleanText(partial.text), reasoning: partial.reasoning, error: 'Generation timed out' });
                    if (onComplete) onComplete(cleanText(partial.text), partial.reasoning, { partialError: "Generation timed out" });
                } else {
                    finishNetworkTrace({ error: 'Generation timed out — no response from server' });
                    if (onError) onError(new Error("Generation timed out — no response from server"));
                }
                return;
            }

            // User-initiated abort — save partial text if available
            const partial = streamAccumulator.getPartial();
            if (partial.text.length > 0) {
                finishNetworkTrace({ text: cleanText(partial.text), reasoning: partial.reasoning, error: 'Generation aborted' });
                if (onComplete) onComplete(cleanText(partial.text), partial.reasoning);
            } else {
                finishNetworkTrace({ error: e });
                if (onError) onError(e);
            }
            return;
        }

        // Network error (connection abort, DNS failure, etc.) — save partial text cleanly
        const partial = streamAccumulator.getPartial();
        if (partial.text.length > 0) {
            console.warn("Network error during stream, saving partial response:", e);
            const errorMsg = e.message || "Stream Error";
            finishNetworkTrace({ text: cleanText(partial.text), reasoning: partial.reasoning, error: errorMsg });
            if (onComplete) onComplete(cleanText(partial.text), partial.reasoning, { partialError: errorMsg });
            return;
        }

        finishNetworkTrace({ error: e });
        if (onError) onError(e);
    } finally {
        if (connectTimer) clearTimeout(connectTimer);
        if (streamTimer) clearTimeout(streamTimer);
        await runtimePolicy.cleanup();
    }
}
