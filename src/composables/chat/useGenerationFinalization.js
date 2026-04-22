export function finalizeGenerationState({
    charId,
    sessionId,
    expectedGenId = null,
    getGenerationState,
    clearGenerationState,
    clearPersistedGeneration,
    clearBackgroundUpdateTimer,
    isGenerating,
    activeChatChar
}) {
    const currentState = getGenerationState(charId);
    if (!currentState) return;

    if (currentState.timerId) {
        clearTimeout(currentState.timerId);
        currentState.timerId = null;
    }
    if (typeof currentState.clearStreamFlushTimer === 'function') {
        currentState.clearStreamFlushTimer();
    }
    if (typeof currentState.streamFlush === 'function') {
        currentState.streamFlush();
    }
    if (typeof clearBackgroundUpdateTimer === 'function') {
        clearBackgroundUpdateTimer();
    }
    clearPersistedGeneration(charId, sessionId);
    clearGenerationState(charId, expectedGenId);
    if (activeChatChar && activeChatChar.id === charId) {
        isGenerating.value = false;
    }
}
