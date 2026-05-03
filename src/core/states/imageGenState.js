const imageGenStates = {};

export function setImageGenState(msgId, state) {
    imageGenStates[msgId] = state;
    return imageGenStates[msgId];
}

export function getImageGenState(msgId) {
    return imageGenStates[msgId] || null;
}

export function hasImageGenState(msgId) {
    return !!imageGenStates[msgId];
}

export function clearImageGenState(msgId) {
    delete imageGenStates[msgId];
}

export function abortImageGenForMessage(msgId) {
    const state = imageGenStates[msgId];
    if (!state) return false;
    if (state.controller) {
        try {
            state.controller.abort();
        } catch (_e) {}
    }
    delete imageGenStates[msgId];
    return true;
}
