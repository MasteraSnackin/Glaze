export function buildGenerationAuthorsNote({ getEffectivePreset, charId, sessionId, anContent }) {
    const effectivePreset = getEffectivePreset(charId, sessionId ? `${charId}_${sessionId}` : null);
    const anBlock = effectivePreset?.blocks?.find(block => block.id === 'authors_note');
    const normalizedContent = typeof anContent === 'object' && anContent !== null
        ? anContent.content
        : anContent;

    if (!anBlock || !anBlock.enabled || !normalizedContent) {
        return null;
    }

    return {
        content: normalizedContent,
        role: anBlock.role || 'system',
        enabled: true,
        depth: anBlock.depth !== undefined ? anBlock.depth : 0,
        insertion_mode: anBlock.insertion_mode || 'relative'
    };
}

export async function ensureGenerationPlaceholderMessage({
    msgIndex,
    text,
    guidanceText,
    guidanceType,
    currentMessages,
    createBaseMessageMeta,
    genMsgId,
    charId,
    sessionId,
    getChatData,
    db,
    scrollToBottom
}) {
    if (msgIndex !== -1 || text) {
        return msgIndex;
    }

    const now = new Date();
    const time = now.getHours() + ':' + String(now.getMinutes()).padStart(2, '0');
    const msg = {
        id: genMsgId(),
        role: 'char',
        text: '',
        time,
        timestamp: Date.now(),
        swipes: [''],
        swipeId: 0,
        isTyping: true,
        guidanceText,
        guidanceType,
        ...createBaseMessageMeta()
    };

    currentMessages.value.push(msg);
    const nextMsgIndex = currentMessages.value.length - 1;
    const data = await getChatData(charId);
    if (data) {
        data.sessions[sessionId] = currentMessages.value;
        await db.saveChat(charId, data);
    }
    scrollToBottom();

    return nextMsgIndex;
}

export function buildGenerationHistory(currentMessages) {
    return currentMessages.value
        .map((message, index) => ({ ...message, originalIndex: index }))
        .filter(message => !message.isTyping && !message.isHidden)
        .map(message => ({
            role: message.role === 'user' ? 'user' : 'assistant',
            content: message.text || '',
            text: message.text || '',
            image: (message.image && !message.imageHidden) ? message.image : null,
            chatId: message.originalIndex,
            messageId: message.id || null,
            contextRefs: Array.isArray(message.contextRefs) ? message.contextRefs : []
        }));
}
