import { ref, computed } from 'vue';

export function useMessageSelection(currentMessages, { getChatData, db, addDeletedStats, reconcileSessionMemoryState, debouncedUpdateContextCutoff, getActiveChatChar } = {}) {
    const selectedMessages = ref(new Set());
    const isSelectionMode = computed(() => selectedMessages.value.size > 0);

    const selectionIncludesLast = computed(() => {
        if (selectedMessages.value.size === 0 || !currentMessages.value.length) return false;
        const msgs = currentMessages.value;
        for (let i = msgs.length - 1; i >= msgs.length - selectedMessages.value.size; i--) {
            if (i < 0 || !msgs[i] || !selectedMessages.value.has(msgs[i].id)) return false;
        }
        return true;
    });

    function toggleSelection(msgId) {
        if (selectedMessages.value.has(msgId)) {
            selectedMessages.value.delete(msgId);
        } else {
            selectedMessages.value.add(msgId);
        }
    }

    function clearSelection() {
        selectedMessages.value = new Set();
    }

    async function deleteSelectedMessages() {
        if (selectedMessages.value.size === 0) return;

        const lastMsg = currentMessages.value[currentMessages.value.length - 1];
        if (!lastMsg || !selectedMessages.value.has(lastMsg.id)) return;

        const newMsgs = currentMessages.value.filter(msg => msg && !selectedMessages.value.has(msg.id));
        const count = currentMessages.value.length - newMsgs.length;
        currentMessages.value = newMsgs;

        const activeChatChar = getActiveChatChar ? getActiveChatChar() : null;
        if (activeChatChar) {
            if (count > 0) {
                const sid = activeChatChar.sessionId || (await getChatData(activeChatChar.id)).currentId;
                addDeletedStats(activeChatChar.id, sid, count);
            }

            let chatData = await getChatData(activeChatChar.id);
            const sessionId = activeChatChar.sessionId || chatData.currentId;
            reconcileSessionMemoryState(chatData, sessionId, currentMessages.value);
            chatData.sessions[sessionId] = currentMessages.value;
            await db.saveChat(activeChatChar.id, chatData);
            debouncedUpdateContextCutoff();
        }

        clearSelection();
    }

    async function toggleHideSelectedMessages() {
        if (selectedMessages.value.size === 0) return;

        for (const msg of currentMessages.value) {
            if (msg && selectedMessages.value.has(msg.id)) {
                msg.isHidden = !msg.isHidden;
            }
        }

        const activeChatChar = getActiveChatChar ? getActiveChatChar() : null;
        if (activeChatChar) {
            let chatData = await getChatData(activeChatChar.id);
            const sessionId = activeChatChar.sessionId || chatData.currentId;
            chatData.sessions[sessionId] = currentMessages.value;
            await db.saveChat(activeChatChar.id, chatData);
            debouncedUpdateContextCutoff();
        }

        clearSelection();
    }

    return {
        selectedMessages,
        isSelectionMode,
        selectionIncludesLast,
        toggleSelection,
        clearSelection,
        deleteSelectedMessages,
        toggleHideSelectedMessages
    };
}
