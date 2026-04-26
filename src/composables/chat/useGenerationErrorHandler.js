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
    const { getChatData, db } = persistence;
    const { notifyGenerationEnded } = app;
    const state = getGenerationState(char.id);
    if (!state || state.genId !== genId) return;

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
            const data = await getChatData(char.id);
            if (data && data.sessions[sessionId]) {
                const dbIdx = data.sessions[sessionId].findIndex(m => m.id === msgId);
                if (dbIdx !== -1) {
                    const msg = data.sessions[sessionId][dbIdx];
                    msg.text = formatError(error, rawStreamText);
                    msg.isError = true;
                    msg.isTyping = false;
                    if (msg.swipes && msg.swipes.length > 0) {
                        msg.swipes[msg.swipeId || 0] = msg.text;
                    }
                    await db.saveChat(char.id, data);
                }
            }
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
