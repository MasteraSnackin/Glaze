import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';

export function createGenerationAppAdapters() {
    return {
        notifyGenerationStarted: ({ charId, sessionId, genId, type }) => {
            publishAppEvent(APP_EVENTS.domain.generation.started, { charId, sessionId, genId, type });
        },
        notifyGenerationEnded: ({ charId, sessionId, genId, type }) => {
            publishAppEvent(APP_EVENTS.domain.generation.ended, { charId, sessionId, genId, type });
        },
        notifyChatUpdated: () => {
            publishAppEvent(APP_EVENTS.domain.chat.updated);
        }
    };
}
