const listenersByEvent = new Map();

function getEventListeners(eventName) {
    if (!listenersByEvent.has(eventName)) {
        listenersByEvent.set(eventName, new Set());
    }
    return listenersByEvent.get(eventName);
}

/**
 * Publish an internal application event.
 *
 * @param {string} eventName
 * @param {any} [detail]
 * @returns {{ name: string, detail: any }}
 */
export function publishAppEvent(eventName, detail) {
    const event = { name: eventName, detail };
    const listeners = listenersByEvent.get(eventName);
    if (!listeners || listeners.size === 0) {
        return event;
    }

    for (const listener of [...listeners]) {
        try {
            listener(event);
        } catch (error) {
            console.error(`[eventHub] listener failed for ${eventName}`, error);
        }
    }

    return event;
}

/**
 * Publish a cancelable application event.
 * Listeners can call event.preventDefault() to signal the action should be cancelled.
 *
 * @param {string} eventName
 * @param {any} [detail]
 * @returns {{ name: string, detail: any, defaultPrevented: boolean, preventDefault: () => void }}
 */
export function publishCancelableAppEvent(eventName, detail) {
    const event = { name: eventName, detail, defaultPrevented: false, preventDefault() { event.defaultPrevented = true; } };
    const listeners = listenersByEvent.get(eventName);
    if (!listeners || listeners.size === 0) {
        return event;
    }

    for (const listener of [...listeners]) {
        try {
            listener(event);
            if (event.defaultPrevented) break;
        } catch (error) {
            console.error(`[eventHub] listener failed for ${eventName}`, error);
        }
    }

    return event;
}

/**
 * Subscribe to an internal application event.
 *
 * @param {string} eventName
 * @param {(event: { name: string, detail: any }) => void} listener
 * @returns {() => void}
 */
export function subscribeAppEvent(eventName, listener) {
    const listeners = getEventListeners(eventName);
    listeners.add(listener);
    return () => unsubscribeAppEvent(eventName, listener);
}

/**
 * Unsubscribe from an internal application event.
 *
 * @param {string} eventName
 * @param {(event: { name: string, detail: any }) => void} listener
 */
export function unsubscribeAppEvent(eventName, listener) {
    const listeners = listenersByEvent.get(eventName);
    if (!listeners) return;

    listeners.delete(listener);
    if (listeners.size === 0) {
        listenersByEvent.delete(eventName);
    }
}
