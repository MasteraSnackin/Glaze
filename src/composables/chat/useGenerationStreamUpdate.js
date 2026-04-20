export function createGenerationStreamUpdater({
    char,
    sessionId,
    msgId,
    genId,
    getGenerationState,
    getChatData,
    db,
    onRawText
}) {
    let backgroundUpdateTimer = null;
    let backgroundPendingText = null;
    let backgroundPendingReasoning = null;

    const clearBackgroundUpdateTimer = () => {
        if (backgroundUpdateTimer) {
            clearTimeout(backgroundUpdateTimer);
            backgroundUpdateTimer = null;
        }
    };

    const onUpdate = async (chunk, reasoningChunk, effectiveText, effectiveReasoning, textDelta) => {
        if (typeof onRawText === 'function') {
            onRawText(effectiveText, chunk);
        }

        const state = getGenerationState(char.id);
        if (state && state.genId === genId && state.onUIUpdate) {
            state.onUIUpdate(effectiveText, effectiveReasoning, true, textDelta);
            return;
        }

        if (!state || state.genId !== genId) {
            return;
        }

        backgroundPendingText = effectiveText;
        backgroundPendingReasoning = effectiveReasoning;
        if (backgroundUpdateTimer) {
            return;
        }

        backgroundUpdateTimer = setTimeout(async () => {
            backgroundUpdateTimer = null;
            if (backgroundPendingText === null) return;

            const latestState = getGenerationState(char.id);
            if (!latestState || latestState.genId !== genId) return;

            const data = await getChatData(char.id);
            if (data && data.sessions[sessionId]) {
                const dbMsg = data.sessions[sessionId].find(m => m.id === msgId);
                if (dbMsg) {
                    dbMsg.text = backgroundPendingText;
                    dbMsg.reasoning = backgroundPendingReasoning;
                    await db.saveChat(char.id, data);
                }
            }
        }, 2000);
    };

    return {
        onUpdate,
        clearBackgroundUpdateTimer
    };
}
