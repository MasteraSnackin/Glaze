import { finalizeGenerationState } from './useGenerationFinalization.js';

export async function handleGenerationError({
    error,
    char,
    sessionId,
    msgId,
    genId,
    rawStreamText,
    activeChatChar,
    isGenerating,
    currentMessages,
    getGenerationState,
    clearGenerationState,
    clearPersistedGeneration,
    restoreState,
    clearBackgroundUpdateTimer,
    clearTypingStateForMessage,
    persistence,
    app,
    formatError,
    sendMessageNotification
}) {
    const { patchChatData } = persistence;
    const { notifyGenerationEnded } = app;
    const state = getGenerationState(char.id);
    if (!state || state.genId !== genId) {
        if (error?.name === 'AbortError' && error?.userAborted) {
            const idx = currentMessages.value.findIndex(m => m.id === msgId);
            if (idx !== -1) {
                const msg = currentMessages.value[idx];
                const isEmptyPlaceholder = !msg.text?.trim() && msg.swipes?.length === 1 && !msg.swipes[0]?.trim();
                if (isEmptyPlaceholder) {
                    currentMessages.value.splice(idx, 1);
                    try {
                        await patchChatData(char.id, draft => {
                            if (sessionId && draft.sessions[sessionId]) {
                                draft.sessions[sessionId] = currentMessages.value;
                            }
                        });
                    } catch (dbErr) {
                        console.error('[onError-stale] Failed to remove empty placeholder from DB:', dbErr);
                    }
                } else {
                    msg.isTyping = false;
                }
            }
        } else {
            await clearTypingStateForMessage({
                charId: char.id,
                sessionId,
                msgId,
                errorLabel: '[onError-stale]'
            });
        }
        notifyGenerationEnded({ charId: char.id, sessionId, genId, type: 'chat' });
        return;
    }

    if (typeof state.clearStreamFlushTimer === 'function') {
        state.clearStreamFlushTimer();
    }
    if (typeof state.streamFlush === 'function') {
        state.streamFlush();
    }

    if (typeof clearBackgroundUpdateTimer === 'function') {
        clearBackgroundUpdateTimer();
    }

    const ensureTypingCleared = async () => {
        await clearTypingStateForMessage({
            charId: char.id,
            sessionId,
            msgId,
            errorLabel: '[onError]'
        });
    };

    try {
        if (error?.name === 'AbortError' && error?.userAborted) {
            await restoreState(false);
            finalizeGenerationState({
                charId: char.id,
                sessionId,
                expectedGenId: genId,
                getGenerationState,
                clearGenerationState,
                clearPersistedGeneration,
                clearBackgroundUpdateTimer,
                isGenerating,
                activeChatChar
            });
            notifyGenerationEnded({ charId: char.id, sessionId, genId, type: 'chat' });
            return;
        }

        if (error.message === 'Context limit exceeded') {
            await restoreState(false);
            finalizeGenerationState({
                charId: char.id,
                sessionId,
                expectedGenId: genId,
                getGenerationState,
                clearGenerationState,
                clearPersistedGeneration,
                clearBackgroundUpdateTimer,
                isGenerating,
                activeChatChar
            });
            notifyGenerationEnded({ charId: char.id, sessionId, genId, type: 'chat' });
            return;
        }

        await restoreState(true);
        finalizeGenerationState({
            charId: char.id,
            sessionId,
            expectedGenId: genId,
            getGenerationState,
            clearGenerationState,
            clearPersistedGeneration,
            clearBackgroundUpdateTimer,
            isGenerating,
            activeChatChar
        });

        sendMessageNotification(
            `Error - ${char.name}`,
            error.message || 'Generation failed',
            char.avatar,
            char.id,
            sessionId,
            msgId
        );

        const idx = currentMessages.value.findIndex(m => m.id === msgId);
        if (idx !== -1) {
            const msg = currentMessages.value[idx];
            msg.text = formatError(error, rawStreamText);
            msg.isError = true;
            if (msg.swipes && msg.swipes.length > 0) {
                msg.swipes[msg.swipeId || 0] = msg.text;
            }
        } else {
            await patchChatData(char.id, draft => {
                if (sessionId && draft.sessions[sessionId]) {
                    const dbIdx = draft.sessions[sessionId].findIndex(m => m.id === msgId);
                    if (dbIdx !== -1) {
                        const msg = draft.sessions[sessionId][dbIdx];
                        msg.text = formatError(error, rawStreamText);
                        msg.isError = true;
                        msg.isTyping = false;
                        if (msg.swipes && msg.swipes.length > 0) {
                            msg.swipes[msg.swipeId || 0] = msg.text;
                        }
                    }
                }
            });
        }

        notifyGenerationEnded({ charId: char.id, sessionId, genId, type: 'chat' });
    } catch (handlerErr) {
        console.error('[onError] Error handler failed:', handlerErr);
        await ensureTypingCleared();
        finalizeGenerationState({
            charId: char.id,
            sessionId,
            expectedGenId: genId,
            getGenerationState,
            clearGenerationState,
            clearPersistedGeneration,
            clearBackgroundUpdateTimer,
            isGenerating,
            activeChatChar
        });
        notifyGenerationEnded({ charId: char.id, sessionId, genId, type: 'chat' });
    }
}
