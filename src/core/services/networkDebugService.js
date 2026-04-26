const ENABLED_KEY = 'gz_debug_network_capture';
import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';

export function isNetworkDebugEnabled() {
    return localStorage.getItem(ENABLED_KEY) === 'true';
}

export function setNetworkDebugEnabled(enabled) {
    localStorage.setItem(ENABLED_KEY, enabled ? 'true' : 'false');
}

export function startNetworkTrace({ debugKey, requestType = 'unknown', apiUrl, stream, requestBody, headers }) {

    publishAppEvent(APP_EVENTS.debug.requestTraceStarted, {
        debugKey,
        requestType,
        apiUrl,
        stream,
        requestBody,
        headers
    });
}

export function updateNetworkTrace({ debugKey, patch = {} } = {}) {
    publishAppEvent(APP_EVENTS.debug.requestTraceUpdated, { debugKey, patch });
}

export function appendNetworkTraceLine({ debugKey, line } = {}) {
    publishAppEvent(APP_EVENTS.debug.requestTraceLineAppended, { debugKey, line });
}

export function finishNetworkTrace({ debugKey, rawResponse, text, reasoning, error } = {}) {
    publishAppEvent(APP_EVENTS.debug.requestTraceFinished, {
        debugKey,
        rawResponse,
        text,
        reasoning,
        error
    });
}
