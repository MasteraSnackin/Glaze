import { shouldUseBatterySaverUI } from '@/core/config/APPSettings.js';

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

const STREAM_FRAME_INTERVAL_MS = 100;
const STREAM_SCROLL_INTERVAL_MS = 180;
const GENERATION_TIMER_INTERVAL_MS = 1000;

function applyMessageStreamUpdate(message, text, reasoning, isTyping, textDelta) {
    if (textDelta) {
        message.text += textDelta;
    } else {
        message.text = text;
    }

    message.reasoning = reasoning;
    message.isTyping = isTyping;
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
    let streamFlushTimer = null;
    let pendingText = null;
    let pendingReasoning = null;
    let pendingTyping = null;
    let pendingTextDelta = null;
    let lastScrollAt = 0;

    const flushPendingUIUpdate = () => {
        streamFlushTimer = null;

        const idx = currentMessages.value.findIndex(message => message.id === msgId);
        if (idx === -1) {
            pendingText = null;
            pendingReasoning = null;
            pendingTyping = null;
            pendingTextDelta = null;
            return;
        }

        const message = currentMessages.value[idx];
        applyMessageStreamUpdate(message, pendingText, pendingReasoning, pendingTyping, pendingTextDelta);

        pendingText = null;
        pendingReasoning = null;
        pendingTyping = null;
        pendingTextDelta = null;

        const now = Date.now();
        if (now - lastScrollAt >= STREAM_SCROLL_INTERVAL_MS) {
            lastScrollAt = now;
            smartScroll();
        }
    };

    const initialUIUpdate = (text, reasoning, isTyping, textDelta) => {
        pendingText = text;
        pendingReasoning = reasoning;
        pendingTyping = isTyping;

        if (textDelta && pendingTextDelta) {
            pendingTextDelta += textDelta;
        } else {
            pendingTextDelta = textDelta || null;
        }

        if (shouldUseBatterySaverUI()) {
            if (streamFlushTimer) return;
            streamFlushTimer = setTimeout(flushPendingUIUpdate, STREAM_FRAME_INTERVAL_MS);
            return;
        }

        flushPendingUIUpdate();
    };

    setGenerationState(char.id, {
        genId,
        controller,
        startTime,
        msgId,
        timerId: null,
        streamFlushTimer: null,
        onUIUpdate: initialUIUpdate
    });

    getGenerationState(char.id).streamFlush = flushPendingUIUpdate;
    getGenerationState(char.id).timerId = setInterval(() => {
        if (activeChatChar && activeChatChar.id === char.id) {
            const idx = currentMessages.value.findIndex(message => message.id === msgId);
            if (idx !== -1) {
                const elapsed = ((Date.now() - startTime) / 1000).toFixed(0) + 's';
                currentMessages.value[idx].genTime = elapsed;
            }
        }
    }, GENERATION_TIMER_INTERVAL_MS);

    getGenerationState(char.id).clearStreamFlushTimer = () => {
        if (!streamFlushTimer) return;
        clearTimeout(streamFlushTimer);
        streamFlushTimer = null;
    };
}
