import { getActivePromptPreviewKey, getPromptPreview, getLastPromptPreview } from '@/core/states/promptPreviewState.js';
import { getActiveRequestTraceKey, getRequestTrace, getLastRequestTrace } from '@/core/states/requestTraceState.js';

export function getActiveRequestPreviewKey() {
    return getActivePromptPreviewKey() || getActiveRequestTraceKey() || null;
}

export function getRequestPreviewSnapshot(debugKey = getActiveRequestPreviewKey()) {
    if (!debugKey) {
        const prompt = getLastPromptPreview();
        const trace = getLastRequestTrace();
        return {
            debugKey: null,
            prompt,
            trace
        };
    }

    return {
        debugKey,
        prompt: getPromptPreview(debugKey),
        trace: getRequestTrace(debugKey)
    };
}

export function getLastRequestPreviewSnapshot() {
    return getRequestPreviewSnapshot();
}
