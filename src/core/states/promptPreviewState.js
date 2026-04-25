const MAX_PROMPT_PREVIEWS = 10;

const promptPreviews = new Map();
let activePromptPreviewKey = null;

function clone(value) {
    if (value === undefined) return undefined;
    return JSON.parse(JSON.stringify(value));
}

function trimPromptPreviews() {
    while (promptPreviews.size > MAX_PROMPT_PREVIEWS) {
        const oldestKey = promptPreviews.keys().next().value;
        if (!oldestKey) break;
        promptPreviews.delete(oldestKey);
    }
}

export function setPromptPreview({ debugKey, prompt }) {
    if (!debugKey) return;
    promptPreviews.delete(debugKey);
    promptPreviews.set(debugKey, clone(prompt));
    activePromptPreviewKey = debugKey;
    trimPromptPreviews();
}

export function getPromptPreview(debugKey) {
    if (!debugKey) return null;
    return clone(promptPreviews.get(debugKey) || null);
}

export function getLastPromptPreview() {
    if (!activePromptPreviewKey) return null;
    return getPromptPreview(activePromptPreviewKey);
}

export function getActivePromptPreviewKey() {
    return activePromptPreviewKey;
}

export function clearPromptPreview(debugKey = activePromptPreviewKey) {
    if (!debugKey) return;
    promptPreviews.delete(debugKey);
    if (activePromptPreviewKey === debugKey) {
        activePromptPreviewKey = promptPreviews.size
            ? Array.from(promptPreviews.keys()).at(-1)
            : null;
    }
}
