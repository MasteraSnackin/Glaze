function applyCompletionToMessage({
    msg,
    response,
    finalReasoning,
    duration,
    meta,
    guidanceText,
    guidanceType,
    estimateTokens,
    char,
    sessionId,
    addMessageStats,
    addRegenerationStats,
    triggerAutoSyncCheck,
    includeInitialGuidanceMeta = true
}) {
    msg.text = response;
    msg.reasoning = finalReasoning;
    msg.genTime = duration;
    msg.tokens = estimateTokens(response);
    msg.isTyping = false;

    if (meta?.partialError) {
        msg.isPartial = true;
        msg.partialErrorMsg = meta.partialError;
    }

    if (!msg.swipes) msg.swipes = [];
    if (!msg.swipesMeta) msg.swipesMeta = [];

    if (msg.swipes.length === 1 && msg.swipes[0] === '') {
        msg.swipes[0] = response;
        msg.swipesMeta[0] = includeInitialGuidanceMeta
            ? {
                genTime: duration,
                reasoning: finalReasoning,
                tokens: msg.tokens,
                guidanceText: msg.guidanceText,
                guidanceType: msg.guidanceType
            }
            : {
                genTime: duration,
                reasoning: finalReasoning,
                tokens: msg.tokens
            };
        addMessageStats(char.id, sessionId, msg.tokens, response.length, msg.timestamp);
        triggerAutoSyncCheck();
    } else {
        msg.swipes[msg.swipeId || 0] = response;
        if (!msg.swipesMeta[msg.swipeId || 0]) msg.swipesMeta[msg.swipeId || 0] = {};
        msg.swipesMeta[msg.swipeId || 0].genTime = duration;
        msg.swipesMeta[msg.swipeId || 0].reasoning = finalReasoning;
        msg.swipesMeta[msg.swipeId || 0].tokens = msg.tokens;
        msg.swipesMeta[msg.swipeId || 0].guidanceText = guidanceText;
        msg.swipesMeta[msg.swipeId || 0].guidanceType = guidanceType;
        addRegenerationStats(char.id, sessionId, msg.tokens, response.length);
    }
}

export async function handleGenerationComplete({
    response,
    finalReasoning,
    meta,
    char,
    sessionId,
    msgId,
    genId,
    startTime,
    controller,
    guidanceText,
    guidanceType,
    activeChatChar,
    isGenerating,
    currentMessages,
    displayMessages,
    getGenerationState,
    clearGenerationState,
    clearPersistedGeneration,
    clearBackgroundUpdateTimer,
    clearTypingStateForMessage,
    getChatData,
    db,
    cleanText,
    estimateTokens,
    updateSessionMessage,
    processMessageImages,
    userAvatar,
    isItemVisible,
    scrollToIndex,
    smartScroll,
    sendMessageNotification,
    runMemoryAutomationAfterStableTurn,
    addMessageStats,
    addRegenerationStats,
    triggerAutoSyncCheck
}) {
    const ensureCleanup = () => {
        const currentState = getGenerationState(char.id);
        if (currentState && currentState.timerId) clearInterval(currentState.timerId);
        if (typeof clearBackgroundUpdateTimer === 'function') {
            clearBackgroundUpdateTimer();
        }
        clearPersistedGeneration(char.id, sessionId);
        clearGenerationState(char.id);
        if (activeChatChar && activeChatChar.id === char.id) isGenerating.value = false;
    };

    const ensureStaleCleanup = () => {
        if (typeof clearBackgroundUpdateTimer === 'function') {
            clearBackgroundUpdateTimer();
        }
        clearPersistedGeneration(char.id, sessionId);
    };

    try {
        const currentState = getGenerationState(char.id);
        if (typeof clearBackgroundUpdateTimer === 'function') {
            clearBackgroundUpdateTimer();
        }

        if (!currentState || currentState.genId !== genId) {
            await clearTypingStateForMessage({ charId: char.id, sessionId, msgId });
            ensureStaleCleanup();
            window.dispatchEvent(new CustomEvent('chat-generation-ended', { detail: { charId: char.id, sessionId } }));
            return;
        }

        if (currentState.timerId) clearInterval(currentState.timerId);
        clearPersistedGeneration(char.id, sessionId);

        const hasCompletionPayload = !!(response || finalReasoning || meta?.partialError);
        if (controller.signal.aborted && !hasCompletionPayload) {
            await clearTypingStateForMessage({ charId: char.id, sessionId, msgId });
            ensureCleanup();
            window.dispatchEvent(new CustomEvent('chat-generation-ended', { detail: { charId: char.id, sessionId } }));
            return;
        }

        let wasVisible = false;
        let displayIndex = -1;
        const foundIndex = currentMessages.value.findIndex(m => m.id === currentState.msgId);

        if (foundIndex !== -1) {
            displayIndex = displayMessages.value.findIndex(m => m.type === 'message' && m.originalIndex === foundIndex);
            if (displayIndex !== -1) {
                wasVisible = isItemVisible(displayIndex);
            }
        }

        clearGenerationState(char.id);
        if (activeChatChar && activeChatChar.id === char.id) isGenerating.value = false;

        const now = new Date();
        const cleanedResponse = cleanText(response);
        const time = now.getHours() + ':' + String(now.getMinutes()).padStart(2, '0');
        const duration = ((Date.now() - startTime) / 1000).toFixed(2) + 's';

        if (activeChatChar && activeChatChar.id === char.id && foundIndex !== -1) {
            const msg = currentMessages.value[foundIndex];
            msg.time = time;
            applyCompletionToMessage({
                msg,
                response: cleanedResponse,
                finalReasoning,
                duration,
                meta,
                guidanceText,
                guidanceType,
                estimateTokens,
                char,
                sessionId,
                addMessageStats,
                addRegenerationStats,
                triggerAutoSyncCheck,
                includeInitialGuidanceMeta: true
            });

            updateSessionMessage(char, foundIndex, msg);

            processMessageImages(msg.text, (updatedText) => {
                msg.text = updatedText;
                msg.swipes[msg.swipeId || 0] = updatedText;
                if (!updatedText.includes('imggen-loading')) {
                    updateSessionMessage(char, foundIndex, msg);
                }
            }, {
                charAvatar: char.avatar || null,
                userAvatar,
                messages: currentMessages.value,
                currentMsgIndex: foundIndex
            }).then(finalText => {
                if (finalText !== msg.text) {
                    msg.text = finalText;
                    msg.swipes[msg.swipeId || 0] = finalText;
                    updateSessionMessage(char, foundIndex, msg);
                }
            }).catch(e => console.error('[ImageGen] processMessageImages failed:', e));

            if (wasVisible) {
                scrollToIndex(displayIndex, 'smooth', 'top');
            } else {
                smartScroll();
            }

            sendMessageNotification(char.name, cleanedResponse, char.avatar, char.id, sessionId, msgId);

            if (guidanceType === 'GENERATION') {
                const autoData = await getChatData(char.id);
                if (autoData) {
                    const autoSessionId = char.sessionId || autoData.currentId;
                    autoData.sessions[autoSessionId] = currentMessages.value;
                    await runMemoryAutomationAfterStableTurn(autoData, autoSessionId, currentMessages.value, { allowImmediate: true });
                }
            }

            window.dispatchEvent(new CustomEvent('chat-generation-ended', { detail: { charId: char.id, sessionId } }));
            return;
        }

        const bgData = await getChatData(char.id);
        if (bgData && bgData.sessions[sessionId]) {
            const bIdx = bgData.sessions[sessionId].findIndex(m => m.id === msgId);
            if (bIdx !== -1) {
                const msg = bgData.sessions[sessionId][bIdx];
                msg.time = time;
                applyCompletionToMessage({
                    msg,
                    response: cleanedResponse,
                    finalReasoning,
                    duration,
                    meta,
                    guidanceText,
                    guidanceType,
                    estimateTokens,
                    char,
                sessionId,
                addMessageStats,
                addRegenerationStats,
                triggerAutoSyncCheck,
                includeInitialGuidanceMeta: false
            });

                processMessageImages(cleanedResponse, (updatedText) => {
                    msg.text = updatedText;
                    msg.swipes[msg.swipeId || 0] = updatedText;
                    if (!updatedText.includes('imggen-loading')) {
                        db.saveChat(char.id, bgData);
                    }
            }, {
                charAvatar: char.avatar || null,
                userAvatar,
                messages: bgData.sessions[sessionId],
                currentMsgIndex: bIdx
            }).then(finalText => {
                    if (finalText !== msg.text) {
                        msg.text = finalText;
                        msg.swipes[msg.swipeId || 0] = finalText;
                        db.saveChat(char.id, bgData);
                    }
                }).catch(e => console.error('[ImageGen] background processMessageImages failed:', e));

                await db.saveChat(char.id, bgData);

                if (guidanceType === 'GENERATION') {
                    await runMemoryAutomationAfterStableTurn(bgData, sessionId, bgData.sessions[sessionId], { allowImmediate: true });
                }

                sendMessageNotification(char.name, cleanedResponse, char.avatar, char.id, sessionId, msgId);

                db.get('gz_unread').then(unread => {
                    const newUnread = unread || {};
                    newUnread[char.id] = true;
                    db.set('gz_unread', newUnread);
                    window.dispatchEvent(new CustomEvent('chat-updated'));
                });

                window.dispatchEvent(new CustomEvent('chat-generation-ended', { detail: { charId: char.id, sessionId } }));
            }
        }
    } catch (completeErr) {
        console.error('[onComplete] Completion handler failed:', completeErr);
        ensureCleanup();
        await clearTypingStateForMessage({
            charId: char.id,
            sessionId,
            msgId,
            errorLabel: '[onComplete]'
        });
        window.dispatchEvent(new CustomEvent('chat-generation-ended', { detail: { charId: char.id, sessionId } }));
    }
}
