import { startNetworkTrace } from '@/core/services/networkDebugService.js';

export function createRequestLifecycle({
    provider,
    apiKey,
    controller,
    requestType,
    apiUrl,
    stream,
    requestBody
}) {
    const connectTimeout = parseInt(localStorage.getItem('gz_api_connect_timeout')) || 90000;
    const streamTimeout = parseInt(localStorage.getItem('gz_api_stream_timeout')) || 120000;
    let connectTimer = null;
    let timedOut = false;

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

    return {
        headers,
        connectTimeout,
        streamTimeout,
        throwIfAborted,
        get timedOut() {
            return timedOut;
        },
        startConnectTimeout() {
            connectTimer = setTimeout(() => {
                timedOut = true;
                if (controller) controller.abort();
            }, connectTimeout);
        },
        clearConnectTimeout() {
            if (!connectTimer) return;
            clearTimeout(connectTimer);
            connectTimer = null;
        },
        createStreamingTimeoutController() {
            if (!controller) return null;

            return {
                abort() {
                    timedOut = true;
                    controller.abort();
                }
            };
        }
    };
}
