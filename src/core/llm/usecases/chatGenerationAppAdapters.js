import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';

export function createGenerationAppAdapters() {
    return {
        notifyGenerationStarted: ({ charId, sessionId }) => {
            publishAppEvent(APP_EVENTS.domain.generation.started, { charId, sessionId });
        },
        notifyGenerationEnded: ({ charId, sessionId }) => {
            publishAppEvent(APP_EVENTS.domain.generation.ended, { charId, sessionId });
        },
        notifyChatUpdated: () => {
            publishAppEvent(APP_EVENTS.domain.chat.updated);
        }
    };
}
