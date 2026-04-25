import { Capacitor, CapacitorHttp } from '@capacitor/core';
import { updateNetworkTrace, finishNetworkTrace } from '@/core/services/networkDebugService.js';

export function shouldUseNativeNonStreamingRequest({ apiUrl, stream }) {
    return Capacitor.isNativePlatform() && apiUrl.startsWith('http:') && !apiUrl.includes('https:') && !stream;
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
