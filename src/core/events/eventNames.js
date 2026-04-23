export const APP_EVENTS = {
    nav: {
        openApiSheet: 'nav.openApiSheet'
    },
    domain: {
        chat: {
            updated: 'domain.chat.updated'
        },
        character: {
            updated: 'domain.character.updated'
        },
        generation: {
            started: 'domain.generation.started',
            ended: 'domain.generation.ended',
            promptReady: 'domain.generation.promptReady',
            requestDispatched: 'domain.generation.requestDispatched'
        },
        lorebook: {
            regexScriptsChanged: 'domain.lorebook.regexScriptsChanged'
        },
        sync: {
            dataRefreshed: 'domain.sync.dataRefreshed'
        },
        settings: {
            apiContextChanged: 'domain.settings.apiContextChanged',
            changed: 'domain.settings.changed'
        }
    },
    debug: {
        promptPreviewUpdated: 'debug.promptPreviewUpdated',
        requestTraceStarted: 'debug.requestTraceStarted',
        requestTraceUpdated: 'debug.requestTraceUpdated',
        requestTraceLineAppended: 'debug.requestTraceLineAppended',
        requestTraceFinished: 'debug.requestTraceFinished'
    },
    ui: {
        header: {
            setupChat: 'ui.header.setupChat',
            showLbBanner: 'ui.header.showLbBanner',
            reset: 'ui.header.reset',
            updateAvatar: 'ui.header.updateAvatar'
        },
        chatSearchToggle: 'ui.chatSearchToggle',
        chatSearch: 'ui.chatSearch',
        fsEditorClosed: 'ui.fsEditorClosed'
    }
};

export const LEGACY_WINDOW_EVENT_MAP = {
    [APP_EVENTS.nav.openApiSheet]: 'open-api-sheet',
    [APP_EVENTS.domain.chat.updated]: 'chat-updated',
    [APP_EVENTS.domain.character.updated]: 'character-updated',
    [APP_EVENTS.domain.generation.started]: 'chat-generation-started',
    [APP_EVENTS.domain.generation.ended]: 'chat-generation-ended',
    [APP_EVENTS.domain.generation.promptReady]: 'chat-generation-prompt-ready',
    [APP_EVENTS.domain.generation.requestDispatched]: 'chat-generation-request-dispatched',
    [APP_EVENTS.domain.lorebook.regexScriptsChanged]: 'regex-scripts-changed',
    [APP_EVENTS.domain.sync.dataRefreshed]: 'sync-data-refreshed',
    [APP_EVENTS.domain.settings.apiContextChanged]: 'api-context-settings-changed',
    [APP_EVENTS.domain.settings.changed]: 'settings-changed',
    [APP_EVENTS.ui.header.setupChat]: 'header-setup-chat',
    [APP_EVENTS.ui.header.showLbBanner]: 'header-show-lb-banner',
    [APP_EVENTS.ui.header.reset]: 'header-reset',
    [APP_EVENTS.ui.header.updateAvatar]: 'header-update-avatar',
    [APP_EVENTS.ui.chatSearchToggle]: 'header-chat-search-toggle',
    [APP_EVENTS.ui.chatSearch]: 'header-chat-search',
    [APP_EVENTS.ui.fsEditorClosed]: 'fs-editor-closed'
};
