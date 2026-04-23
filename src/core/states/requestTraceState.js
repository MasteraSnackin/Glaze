const STORAGE_KEY = 'gz_last_network_trace';
const MAX_TRACE_LINES = 200;
const MAX_REQUEST_TRACES = 10;
const PERSIST_DEBOUNCE_MS = 1000;

const requestTraces = new Map();
let activeRequestTraceKey = null;
let persistTimer = null;

function clone(value) {
    if (value === undefined) return undefined;
    return JSON.parse(JSON.stringify(value));
}

function trimRequestTraces() {
    while (requestTraces.size > MAX_REQUEST_TRACES) {
        const oldestKey = requestTraces.keys().next().value;
        if (!oldestKey) break;
        requestTraces.delete(oldestKey);
    }
}

function persistActiveTrace() {
    try {
        if (activeRequestTraceKey && requestTraces.has(activeRequestTraceKey)) {
            localStorage.setItem(STORAGE_KEY, JSON.stringify({
                activeKey: activeRequestTraceKey,
                trace: requestTraces.get(activeRequestTraceKey)
            }));
        } else {
            localStorage.removeItem(STORAGE_KEY);
        }
    } catch (e) {
        console.warn('[networkDebug] Failed to persist trace', e);
    }
}

function schedulePersist() {
    if (persistTimer) return;
    persistTimer = setTimeout(() => {
        persistTimer = null;
        persistActiveTrace();
    }, PERSIST_DEBOUNCE_MS);
}

function maskHeaders(headers = {}) {
    const masked = { ...headers };
    if (masked.Authorization) masked.Authorization = 'Bearer ***';
    if (masked.authorization) masked.authorization = 'Bearer ***';
    return masked;
}

function resolveTraceKey(debugKey = activeRequestTraceKey) {
    return debugKey || null;
}

export function getRequestTrace(debugKey) {
    const traceKey = resolveTraceKey(debugKey);
    if (!traceKey) return null;
    return clone(requestTraces.get(traceKey) || null);
}

export function getLastRequestTrace() {
    return getRequestTrace(activeRequestTraceKey);
}

export function getActiveRequestTraceKey() {
    return activeRequestTraceKey;
}

export function clearRequestTrace(debugKey = activeRequestTraceKey) {
    const traceKey = resolveTraceKey(debugKey);
    if (!traceKey) return;

    requestTraces.delete(traceKey);
    if (activeRequestTraceKey === traceKey) {
        activeRequestTraceKey = requestTraces.size
            ? Array.from(requestTraces.keys()).at(-1)
            : null;
    }

    if (persistTimer) {
        clearTimeout(persistTimer);
        persistTimer = null;
    }
    persistActiveTrace();
}

export function startRequestTrace({ debugKey, requestType = 'unknown', apiUrl, stream, requestBody, headers }) {
    if (!debugKey) return;

    requestTraces.delete(debugKey);
    requestTraces.set(debugKey, {
        requestType,
        apiUrl,
        stream: !!stream,
        startedAt: Date.now(),
        completedAt: null,
        durationMs: null,
        request: clone(requestBody),
        requestHeaders: maskHeaders(headers),
        responseStatus: null,
        responseHeaders: null,
        rawResponse: null,
        streamLines: [],
        parsed: {
            text: '',
            reasoning: '',
            error: null
        }
    });
    activeRequestTraceKey = debugKey;
    trimRequestTraces();
    persistActiveTrace();
}

export function updateRequestTrace({ debugKey, patch = {} }) {
    const traceKey = resolveTraceKey(debugKey);
    if (!traceKey || !requestTraces.has(traceKey)) return;

    const nextPatch = clone(patch);
    if (nextPatch.responseHeaders) {
        nextPatch.responseHeaders = maskHeaders(nextPatch.responseHeaders);
    }

    Object.assign(requestTraces.get(traceKey), nextPatch);
    activeRequestTraceKey = traceKey;
    schedulePersist();
}

export function appendRequestTraceLine({ debugKey, line }) {
    const traceKey = resolveTraceKey(debugKey);
    if (!traceKey || !requestTraces.has(traceKey) || !line) return;

    const trace = requestTraces.get(traceKey);
    trace.streamLines.push(String(line));
    if (trace.streamLines.length > MAX_TRACE_LINES) {
        trace.streamLines = trace.streamLines.slice(-MAX_TRACE_LINES);
    }
    activeRequestTraceKey = traceKey;
    schedulePersist();
}

export function finishRequestTrace({ debugKey, rawResponse, text, reasoning, error } = {}) {
    const traceKey = resolveTraceKey(debugKey);
    if (!traceKey || !requestTraces.has(traceKey)) return;

    const trace = requestTraces.get(traceKey);
    if (rawResponse !== undefined) trace.rawResponse = clone(rawResponse);
    if (text !== undefined) trace.parsed.text = text || '';
    if (reasoning !== undefined) trace.parsed.reasoning = reasoning || '';
    if (error !== undefined) {
        trace.parsed.error = error
            ? (typeof error === 'string' ? error : (error.message || String(error)))
            : null;
    }

    trace.completedAt = Date.now();
    trace.durationMs = Math.max(0, trace.completedAt - (trace.startedAt || trace.completedAt));
    activeRequestTraceKey = traceKey;

    if (persistTimer) {
        clearTimeout(persistTimer);
        persistTimer = null;
    }
    persistActiveTrace();
}

export function hydratePersistedRequestTrace() {
    try {
        const raw = localStorage.getItem(STORAGE_KEY);
        if (!raw) return;

        const parsed = JSON.parse(raw);
        const activeKey = parsed?.activeKey;
        const trace = parsed?.trace;
        if (!activeKey || !trace) return;

        requestTraces.set(activeKey, trace);
        activeRequestTraceKey = activeKey;
        trimRequestTraces();
    } catch (e) {
        activeRequestTraceKey = null;
    }
}
