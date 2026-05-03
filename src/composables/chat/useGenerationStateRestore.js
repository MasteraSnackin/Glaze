function rollbackPendingSwipe(message, { restoreSwipeMeta = false } = {}) {
    if (!message?.swipes || message.swipes.length <= 1) {
        return false;
    }

    const currentSwipeId = message.swipeId || 0;
    message.swipes.splice(currentSwipeId, 1);
    if (message.swipesMeta) message.swipesMeta.splice(currentSwipeId, 1);

    let newSwipeId = currentSwipeId - 1;
    if (newSwipeId < 0) newSwipeId = 0;

    message.swipeId = newSwipeId;
    message.text = message.swipes[newSwipeId] || '';

    if (restoreSwipeMeta) {
        if (message.swipesMeta && message.swipesMeta[newSwipeId]) {
            message.guidanceText = message.swipesMeta[newSwipeId].guidanceText || null;
            message.guidanceType = message.swipesMeta[newSwipeId].guidanceType || 'GENERATION';
            message.reasoning = message.swipesMeta[newSwipeId].reasoning;
            message.genTime = message.swipesMeta[newSwipeId].genTime;
        } else {
            message.guidanceText = null;
            message.guidanceType = 'GENERATION';
        }
    }

    return true;
}

export async function restoreGenerationState({
    currentMessages,
    persistence,
    getGenerationState,
    clearPersistedGeneration,
    char,
    sessionId,
    msgId,
    isError = false,
    expectedGenId = null,
    onAbort = null,
    restorePromptMetaOnMessages,
    clearBackgroundUpdateTimer,
    updateSessionMessage
}) {
    const { db } = persistence;
    if (typeof clearBackgroundUpdateTimer === 'function') {
        clearBackgroundUpdateTimer();
    }

    const generationState = getGenerationState(char.id);
    if (!generationState) return;
    if (expectedGenId !== null && generationState.genId !== expectedGenId) return;

    if (typeof generationState?.clearStreamFlushTimer === 'function') {
        generationState.clearStreamFlushTimer();
    }
    if (typeof generationState?.streamFlush === 'function') {
        generationState.streamFlush();
    }

    const timerId = generationState?.timerId;
    if (timerId) clearTimeout(timerId);
    clearPersistedGeneration(char.id, sessionId);

    const idx = currentMessages.value.findIndex(m => m.id === msgId);
    if (idx !== -1) {
        restorePromptMetaOnMessages(currentMessages.value);
        currentMessages.value[idx].isTyping = false;

            if (!isError) {
            const msg = currentMessages.value[idx];
            const revertedSwipe = rollbackPendingSwipe(msg, { restoreSwipeMeta: true });

            if (revertedSwipe) {
                await updateSessionMessage(char, idx, msg);
            } else {
                currentMessages.value.splice(idx, 1);
                const charId = char.id;
                const sessionCopy = JSON.parse(JSON.stringify(currentMessages.value));
                await db.patchChatData(charId, (data) => {
                    if (data && sessionId && data.sessions[sessionId]) {
                        data.sessions[sessionId] = sessionCopy;
                    }
                });
            }
        }
    } else {
        const charId = char.id;
        await db.patchChatData(charId, (data) => {
            if (!data || !data.sessions[sessionId]) return;
            restorePromptMetaOnMessages(data.sessions[sessionId]);
            const dbIdx = data.sessions[sessionId].findIndex(m => m.id === msgId);
            if (dbIdx !== -1) {
                data.sessions[sessionId][dbIdx].isTyping = false;

                if (!isError) {
                    const msg = data.sessions[sessionId][dbIdx];
                    const revertedSwipe = rollbackPendingSwipe(msg);
                    if (!revertedSwipe) {
                        data.sessions[sessionId].splice(dbIdx, 1);
                    }
                }
            }
        });
    }

    if (onAbort) onAbort(isError);
}
