export function useTypingStateCleanup({ currentMessages, getChatData, db }) {
    return {
        async clearTypingStateForMessage({ charId, sessionId, msgId, errorLabel = '[generation]' }) {
            const idx = currentMessages.value.findIndex(m => m.id === msgId);
            if (idx !== -1) {
                currentMessages.value[idx].isTyping = false;
            }

            try {
                const data = await getChatData(charId);
                if (data && data.sessions[sessionId]) {
                    const dbIdx = data.sessions[sessionId].findIndex(m => m.id === msgId);
                    if (dbIdx !== -1) {
                        data.sessions[sessionId][dbIdx].isTyping = false;
                        await db.saveChat(charId, data);
                    }
                }
            } catch (dbErr) {
                console.error(`${errorLabel} Failed to clear isTyping in DB:`, dbErr);
            }
        }
    };
}
