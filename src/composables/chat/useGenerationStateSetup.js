export function applyGenerationGuidanceState({
    currentMessages,
    msgIndex,
    guidanceText,
    guidanceType
}) {
    if (msgIndex === -1 || !currentMessages.value[msgIndex]) {
        return;
    }

    const msg = currentMessages.value[msgIndex];
    msg.guidanceText = guidanceText;
    msg.guidanceType = guidanceType;

    if (msg.swipesMeta && msg.swipesMeta[msg.swipeId || 0]) {
        msg.swipesMeta[msg.swipeId || 0].guidanceText = null;
        msg.swipesMeta[msg.swipeId || 0].guidanceType = null;
    }
}

export function setupGenerationState({
    char,
    msgId,
    genId,
    controller,
    startTime,
    currentMessages,
    activeChatChar,
    setGenerationState,
    getGenerationState,
    smartScroll
}) {
    const initialUIUpdate = (text, reasoning, isTyping, textDelta) => {
        const idx = currentMessages.value.findIndex(message => message.id === msgId);
        if (idx === -1) {
            return;
        }

        const message = currentMessages.value[idx];
        if (textDelta) {
            message.text = message.text.replace(/class="stream-char"/g, 'class="stream-char-done"');
            message.text += `<span class="stream-char">${textDelta}</span>`;
        } else {
            message.text = text;
        }
        message.reasoning = reasoning;
        message.isTyping = isTyping;
        smartScroll();
    };

    setGenerationState(char.id, {
        genId,
        controller,
        startTime,
        msgId,
        timerId: null,
        onUIUpdate: initialUIUpdate
    });

    getGenerationState(char.id).timerId = setInterval(() => {
        if (activeChatChar && activeChatChar.id === char.id) {
            const idx = currentMessages.value.findIndex(message => message.id === msgId);
            if (idx !== -1) {
                const elapsed = ((Date.now() - startTime) / 1000).toFixed(1) + 's';
                currentMessages.value[idx].genTime = elapsed;
            }
        }
    }, 100);
}
