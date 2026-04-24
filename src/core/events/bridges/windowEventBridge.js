import { publishAppEvent, subscribeAppEvent } from '@/core/events/eventHub.js';
import { LEGACY_WINDOW_EVENT_MAP } from '@/core/events/eventNames.js';

let bridgeCleanup = null;
export const EVENT_BRIDGE_MARKER = '__fromAppEventBridge';

function dispatchLegacyWindowEvent(legacyName, detail) {
    if (detail === undefined) {
        const event = new Event(legacyName);
        event[EVENT_BRIDGE_MARKER] = true;
        window.dispatchEvent(event);
        return;
    }

    const event = new CustomEvent(legacyName, { detail });
    event[EVENT_BRIDGE_MARKER] = true;
    window.dispatchEvent(event);
}

export function initWindowEventBridge() {
    if (typeof window === 'undefined' || bridgeCleanup) return bridgeCleanup;

    const unsubscribers = Object.entries(LEGACY_WINDOW_EVENT_MAP).map(([appEventName, legacyName]) => {
        return subscribeAppEvent(appEventName, ({ detail }) => {
            dispatchLegacyWindowEvent(legacyName, detail);
        });
    });

    bridgeCleanup = () => {
        unsubscribers.forEach(unsubscribe => unsubscribe());
        bridgeCleanup = null;
    };

    return bridgeCleanup;
}
