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

function getGenerationTimerInterval() {
    return shouldUseBatterySaverUI() ? 1000 : 100;
}

function formatGenerationElapsed(startTime) {
    const elapsedSeconds = (Date.now() - startTime) / 1000;
    return shouldUseBatterySaverUI()
        ? elapsedSeconds.toFixed(0) + 's'
        : elapsedSeconds.toFixed(1) + 's';
}

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
    let generationTimer = null;
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

        if (shouldUseBatterySaverUI()) {
            const now = Date.now();
            if (now - lastScrollAt >= STREAM_SCROLL_INTERVAL_MS) {
                lastScrollAt = now;
                smartScroll();
            }
            return;
        }

        smartScroll();
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

    const clearGenerationTimer = () => {
        if (!generationTimer) return;
        clearTimeout(generationTimer);
        generationTimer = null;
    };

    const scheduleGenerationTimer = () => {
        clearGenerationTimer();
        generationTimer = setTimeout(() => {
            generationTimer = null;

            if (activeChatChar && activeChatChar.id === char.id) {
                const idx = currentMessages.value.findIndex(message => message.id === msgId);
                if (idx !== -1) {
                    currentMessages.value[idx].genTime = formatGenerationElapsed(startTime);
                }
            }

            const state = getGenerationState(char.id);
            if (state && state.genId === genId) {
                scheduleGenerationTimer();
            }
        }, getGenerationTimerInterval());
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
    getGenerationState(char.id).timerId = generationTimer;
    getGenerationState(char.id).restartGenerationTimer = () => {
        scheduleGenerationTimer();
        getGenerationState(char.id).timerId = generationTimer;
    };
    scheduleGenerationTimer();
    getGenerationState(char.id).timerId = generationTimer;

    getGenerationState(char.id).clearStreamFlushTimer = () => {
        if (!streamFlushTimer) return;
        clearTimeout(streamFlushTimer);
        streamFlushTimer = null;
    };

    getGenerationState(char.id).clearGenerationTimer = clearGenerationTimer;
}
