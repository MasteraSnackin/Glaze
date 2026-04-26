import { Capacitor, CapacitorHttp } from '@capacitor/core';
import { updateNetworkTrace, finishNetworkTrace } from '@/core/services/networkDebugService.js';

export function shouldUseNativeNonStreamingRequest({ apiUrl, stream }) {
    return Capacitor.isNativePlatform() && apiUrl.startsWith('http:') && !apiUrl.includes('https:') && !stream;
}

export function shouldUseAbortableFetchRequest({ apiUrl, stream, requestType }) {
    return requestType === 'chat' && Capacitor.isNativePlatform() && apiUrl.startsWith('http:') && !apiUrl.includes('https:');
}

export function shouldUseAbortableXhrRequest({ apiUrl, stream, requestType }) {
    return requestType === 'chat' && !stream && Capacitor.isNativePlatform() && apiUrl.startsWith('http:') && !apiUrl.includes('https:');
}

export async function executeNativeNonStreamingRequest({
    requestUrl,
    headers,
    requestBody,
    debugKey,
    connectTimeout,
    streamTimeout
}) {
    const response = await CapacitorHttp.post({
        url: requestUrl,
        headers,
        data: requestBody,
        responseType: 'json',
        connectTimeout,
        readTimeout: streamTimeout
    });

    if (response.status >= 400) {
        const errorData = typeof response.data === 'object'
            ? JSON.stringify(response.data)
            : String(response.data || '');
        updateNetworkTrace({ debugKey, patch: { responseStatus: response.status } });
        finishNetworkTrace({ debugKey, rawResponse: response.data, error: `API Error: ${response.status} ${errorData}` });
        throw new Error(`API Error: ${response.status} ${errorData}`);
    }

    updateNetworkTrace({ debugKey, patch: { responseStatus: response.status } });
    return response.data;
}

export async function executeFetchRequest({
    requestUrl,
    headers,
    requestBody,
    controller
}) {
    return fetch(requestUrl, {
        method: 'POST',
        headers,
        body: JSON.stringify(requestBody),
        signal: controller ? controller.signal : undefined
    });
}

export async function executeAbortableJsonRequest({
    requestUrl,
    headers,
    requestBody,
    controller,
    debugKey
}) {
    return new Promise((resolve, reject) => {
        const xhr = new XMLHttpRequest();
        let settled = false;

        const cleanupAbortListener = () => {
            if (controller?.signal && onAbort) {
                controller.signal.removeEventListener('abort', onAbort);
            }
        };

        const finalizeReject = (error) => {
            if (settled) return;
            settled = true;
            cleanupAbortListener();
            reject(error);
        };

        const finalizeResolve = (value) => {
            if (settled) return;
            settled = true;
            cleanupAbortListener();
            resolve(value);
        };

        const onAbort = () => {
            try {
                xhr.abort();
            } catch (_e) {}
            const error = new Error('Generation aborted');
            error.name = 'AbortError';
            finalizeReject(error);
        };

        if (controller?.signal?.aborted) {
            onAbort();
            return;
        }

        xhr.open('POST', requestUrl, true);
        Object.entries(headers || {}).forEach(([key, value]) => {
            xhr.setRequestHeader(key, value);
        });
        xhr.responseType = 'text';

        xhr.onload = () => {
            const status = xhr.status;
            let data = null;
            const rawText = xhr.responseText || '';

            try {
                data = rawText ? JSON.parse(rawText) : null;
            } catch (parseError) {
                finishNetworkTrace({ debugKey, rawResponse: rawText, error: `Invalid JSON response: ${parseError.message}` });
                finalizeReject(parseError);
                return;
            }

            updateNetworkTrace({
                debugKey,
                patch: {
                    responseStatus: status
                }
            });

            if (status >= 400) {
                finishNetworkTrace({ debugKey, rawResponse: data ?? rawText, error: `API Error: ${status} ${rawText}` });
                finalizeReject(new Error(`API Error: ${status} ${rawText}`));
                return;
            }

            finalizeResolve(data);
        };

        xhr.onerror = () => {
            finalizeReject(new Error('Network request failed'));
        };

        xhr.onabort = () => {
            const error = new Error('Generation aborted');
            error.name = 'AbortError';
            finalizeReject(error);
        };

        controller?.signal?.addEventListener('abort', onAbort, { once: true });

        try {
            xhr.send(JSON.stringify(requestBody));
        } catch (error) {
            finalizeReject(error);
        }
    });
}

export async function validateFetchResponse(response, debugKey) {
    if (!response.ok) {
        let errText = '';
        try { errText = await response.text(); } catch (e) {}
        updateNetworkTrace({
            debugKey,
            patch: {
                responseStatus: response.status,
                responseHeaders: Object.fromEntries(response.headers.entries())
            }
        });
        finishNetworkTrace({ debugKey, rawResponse: errText, error: `API Error: ${response.status} ${errText}` });
        throw new Error(`API Error: ${response.status} ${errText}`);
    }

    updateNetworkTrace({
        debugKey,
        patch: {
            responseStatus: response.status,
            responseHeaders: Object.fromEntries(response.headers.entries())
        }
    });
}
