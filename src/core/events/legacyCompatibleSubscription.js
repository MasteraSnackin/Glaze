import { subscribeAppEvent } from '@/core/events/eventHub.js';
import { EVENT_BRIDGE_MARKER } from '@/core/events/bridges/windowEventBridge.js';

/**
 * Subscribe to both the internal event hub and the legacy window event.
 * Bridged window events are ignored so the listener only fires once.
 *
 * @param {{ appEventName: string, legacyEventName: string, listener: (event: { detail: any }) => void }} options
 * @returns {() => void}
 */
export function subscribeLegacyCompatibleEvent({ appEventName, legacyEventName, listener }) {
    const unsubscribeAppEvent = subscribeAppEvent(appEventName, ({ detail }) => {
        listener({ detail });
    });

    const onLegacyEvent = (event) => {
        if (event?.[EVENT_BRIDGE_MARKER]) return;
        listener(event);
    };

    window.addEventListener(legacyEventName, onLegacyEvent);

    return () => {
        unsubscribeAppEvent();
        window.removeEventListener(legacyEventName, onLegacyEvent);
    };
}
