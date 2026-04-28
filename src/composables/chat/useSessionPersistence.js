import { watch, onBeforeUnmount } from 'vue';

export function useSessionPersistence({
    getActiveChatChar,
    activeChar,
    currentMessages,
    inputValue,
    messagesContainer,
    db,
    getChatData,
    getScrollAnchor,
    clearMessageNotifications
}) {
    const buildCrashBufferKey = (charId, sessionId) => `gz_chat_recovery_${charId}_${sessionId}`;

    function writeCrashBuffer(activeChatChar) {
        if (!activeChatChar?.id || !activeChatChar?.sessionId) return;
        try {
            localStorage.setItem(buildCrashBufferKey(activeChatChar.id, activeChatChar.sessionId), JSON.stringify({
                messages: currentMessages.value,
                draft: inputValue.value,
                authorsNote: activeChatChar.authors_note,
                summary: activeChatChar.summary,
                lastScrollAnchor: getScrollAnchor(),
                savedAt: Date.now()
            }));
        } catch (e) {
            console.warn('[chat] Failed to write crash buffer:', e);
        }
    }

    function clearCrashBuffer(charId, sessionId) {
        if (!charId || !sessionId) return;
        try {
            localStorage.removeItem(buildCrashBufferKey(charId, sessionId));
        } catch (_e) {}
    }

    function asyncSaveCurrentSessionState() {
        const activeChatChar = getActiveChatChar();
        if (activeChatChar && messagesContainer.value) {
            writeCrashBuffer(activeChatChar);
            const charContext = activeChatChar;
            const sessionId = charContext.sessionId;
            const inputValueDraft = inputValue.value;
            const currentAnchor = getScrollAnchor();
            const messagesSnapshot = currentMessages.value;

            db.patchChatData(charContext.id, (data) => {
                data.lastScrollAnchor = currentAnchor;
                data.draft = inputValueDraft;

                if (sessionId) {
                    const msgs = JSON.parse(JSON.stringify(messagesSnapshot));
                    for (let i = msgs.length - 1; i >= 0; i--) {
                        const msg = msgs[i];
                        if (msg.isEditing) {
                            msg.isEditing = false;
                            delete msg.editText;
                        }

                        if (msg.isError) {
                            if (msg.swipes && msg.swipes.length > 1) {
                                const errorSwipeId = msg.swipeId || 0;
                                msg.swipes.splice(errorSwipeId, 1);
                                if (msg.swipesMeta) msg.swipesMeta.splice(errorSwipeId, 1);

                                let newSwipeId = errorSwipeId - 1;
                                if (newSwipeId < 0) newSwipeId = 0;

                                msg.swipeId = newSwipeId;
                                msg.text = msg.swipes[newSwipeId] || "";

                                msg.isError = false;

                                if (msg.swipesMeta && msg.swipesMeta[newSwipeId]) {
                                    msg.reasoning = msg.swipesMeta[newSwipeId].reasoning;
                                    msg.genTime = msg.swipesMeta[newSwipeId].genTime;
                                } else {
                                    msg.reasoning = null;
                                    msg.genTime = null;
                                }
                            }
                        }
                    }
                    data.sessions[sessionId] = msgs;
                }

                if (charContext.authors_note !== undefined) {
                    if (!data.authorsNotes) data.authorsNotes = {};
                    data.authorsNotes[sessionId] = charContext.authors_note;
                }
                if (charContext.summary !== undefined) {
                    if (!data.summaries) data.summaries = {};
                    data.summaries[sessionId] = charContext.summary;
                }
            });
            clearCrashBuffer(charContext.id, sessionId);
        }
    }

    function applyImageAutoHide() {
        const autoHide = localStorage.getItem('gz_api_auto_hide_images') === 'true';
        const threshold = parseInt(localStorage.getItem('gz_api_auto_hide_images_n') || '1', 10);

        const activeChatChar = getActiveChatChar();
        if (!autoHide || threshold <= 0 || !activeChatChar) return;

        let changed = false;
        let assistantCount = 0;

        for (let i = currentMessages.value.length - 1; i >= 0; i--) {
            const msg = currentMessages.value[i];
            if (msg.role === 'char' || msg.role === 'assistant') {
                assistantCount++;
            } else if (msg.role === 'user' && msg.image) {
                if (assistantCount >= threshold && !msg.imageHidden) {
                    msg.imageHidden = true;
                    changed = true;
                }
            }
        }

        if (changed) {
            const charId = activeChatChar.id;
            const sessionId = activeChatChar.sessionId;
            const messageSnapshot = currentMessages.value;
            getChatData(activeChatChar.id).then(data => {
                if (data && sessionId && data.sessions?.[sessionId]) {
                    data.sessions[sessionId] = messageSnapshot;
                    db.saveChat(charId, data);
                }
            });
        }
    }

    function onVisibilityChange() {
        const activeChatChar = getActiveChatChar();
        if (document.visibilityState === 'hidden' && activeChatChar) {
            writeCrashBuffer(activeChatChar);
            const charId = activeChatChar.id;
            const sessionId = activeChatChar.sessionId;
            const messagesSnapshot = currentMessages.value;
            const draft = inputValue.value;
            const authorsNote = activeChatChar.authors_note;
            const summary = activeChatChar.summary;
            db.patchChatData(charId, (data) => {
                if (sessionId) {
                    data.sessions[sessionId] = JSON.parse(JSON.stringify(messagesSnapshot));
                }
                data.draft = draft;
                if (authorsNote !== undefined) {
                    if (!data.authorsNotes) data.authorsNotes = {};
                    data.authorsNotes[sessionId] = authorsNote;
                }
                if (summary !== undefined) {
                    if (!data.summaries) data.summaries = {};
                    data.summaries[sessionId] = summary;
                }
            });
        } else if (document.visibilityState === 'visible' && activeChatChar) {
            clearMessageNotifications(activeChatChar.id);
        }
    }

    function onPageHide() {
        const activeChatChar = getActiveChatChar();
        if (activeChatChar) {
            writeCrashBuffer(activeChatChar);
        }
        asyncSaveCurrentSessionState();
    }

    watch(activeChar, async (newVal) => {
        if (!newVal) return;

        const chatData = await getChatData(newVal.id);
        if (!chatData) return;
        const sessionId = chatData.currentId;
        let changed = false;

        if (newVal.summary !== undefined) {
            if (!chatData.summaries) chatData.summaries = {};
            let currentSum = chatData.summaries[sessionId];
            if (typeof currentSum === 'string') {
                currentSum = { content: currentSum, depth: 4, role: 'system', insertion_mode: 'relative', prefix: 'Summary: ' };
            } else if (!currentSum) {
                currentSum = { content: '', depth: 4, role: 'system', insertion_mode: 'relative', prefix: 'Summary: ' };
            }
            if (currentSum.content !== newVal.summary) {
                chatData.summaries[sessionId] = { ...currentSum, content: newVal.summary };
                changed = true;
            }
        }

        if (newVal.authors_note !== undefined) {
            if (!chatData.authorsNotes) chatData.authorsNotes = {};
            const storedAn = chatData.authorsNotes[sessionId];
            const currentAN = typeof storedAn === 'string' ? storedAn : storedAn?.content || '';
            if (currentAN !== newVal.authors_note) {
                chatData.authorsNotes[sessionId] = newVal.authors_note;
                changed = true;
            }
        }

        if (changed) await db.saveChat(newVal.id, chatData);
    }, { deep: true });

    onBeforeUnmount(() => {
        const activeChatChar = getActiveChatChar();
        if (activeChatChar && messagesContainer.value) {
            const charId = activeChatChar.id;
            const sessionId = activeChatChar.sessionId;
            const currentAnchor = getScrollAnchor();
            const draft = inputValue.value;
            const messagesSnapshot = currentMessages.value;
            const authorsNote = activeChatChar.authors_note;
            const summary = activeChatChar.summary;
            db.patchChatData(charId, (data) => {
                data.lastScrollAnchor = currentAnchor;
                data.draft = draft;
                if (sessionId) {
                    data.sessions[sessionId] = JSON.parse(JSON.stringify(messagesSnapshot));
                }
                if (authorsNote !== undefined) {
                    if (!data.authorsNotes) data.authorsNotes = {};
                    data.authorsNotes[sessionId] = authorsNote;
                }
                if (summary !== undefined) {
                    if (!data.summaries) data.summaries = {};
                    data.summaries[sessionId] = summary;
                }
            });
        }
    });

    if (typeof window !== 'undefined') {
        window.addEventListener('beforeunload', onPageHide);
        window.addEventListener('pagehide', onPageHide);
    }

    onBeforeUnmount(() => {
        if (typeof window !== 'undefined') {
            window.removeEventListener('beforeunload', onPageHide);
            window.removeEventListener('pagehide', onPageHide);
        }
    });

    return {
        asyncSaveCurrentSessionState,
        applyImageAutoHide,
        onVisibilityChange,
        onPageHide,
        buildCrashBufferKey,
        clearCrashBuffer
    };
}
