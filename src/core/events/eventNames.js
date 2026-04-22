export const APP_EVENTS = {
    nav: {
        openApiSheet: 'nav.openApiSheet'
    },
    domain: {
        chat: {
            updated: 'domain.chat.updated'
        },
        generation: {
            started: 'domain.generation.started',
            ended: 'domain.generation.ended'
        },
        sync: {
            dataRefreshed: 'domain.sync.dataRefreshed'
        },
        settings: {
            apiContextChanged: 'domain.settings.apiContextChanged'
        }
    }
};

export const LEGACY_WINDOW_EVENT_MAP = {
    [APP_EVENTS.nav.openApiSheet]: 'open-api-sheet',
    [APP_EVENTS.domain.chat.updated]: 'chat-updated',
    [APP_EVENTS.domain.generation.started]: 'chat-generation-started',
    [APP_EVENTS.domain.generation.ended]: 'chat-generation-ended',
    [APP_EVENTS.domain.sync.dataRefreshed]: 'sync-data-refreshed',
    [APP_EVENTS.domain.settings.apiContextChanged]: 'api-context-settings-changed'
};
