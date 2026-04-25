export const APP_EVENTS = {
    nav: {
        openApiSheet: 'nav.openApiSheet',
        navigateTo: 'nav.navigateTo',
        openCharacterEditor: 'nav.openCharacterEditor',
        openChat: 'nav.openChat',
        openOnboarding: 'nav.openOnboarding',
        openBackupSheet: 'nav.openBackupSheet',
        openSyncSheet: 'nav.openSyncSheet',
        openConflictSheet: 'nav.openConflictSheet',
        openConnections: 'nav.openConnections',
        openFsRequest: 'nav.openFsRequest',
        openGlossary: 'nav.openGlossary',
        openHolocards: 'nav.openHolocards',
        openImageViewer: 'nav.openImageViewer',
        openItemEditor: 'nav.openItemEditor',
        openLorebookEntry: 'nav.openLorebookEntry',
        openNotificationsSheet: 'nav.openNotificationsSheet',
        openPersonaEditor: 'nav.openPersonaEditor',
        openPresetSheet: 'nav.openPresetSheet',
        triggerOpenImage: 'nav.triggerOpenImage'
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
            changed: 'domain.settings.changed',
            languageChanged: 'domain.settings.languageChanged'
        }
    },
    debug: {
        promptPreviewUpdated: 'debug.promptPreviewUpdated',
        requestTraceStarted: 'debug.requestTraceStarted',
        requestTraceUpdated: 'debug.requestTraceUpdated',
        requestTraceLineAppended: 'debug.requestTraceLineAppended',
        requestTraceFinished: 'debug.requestTraceFinished',
        vueError: 'debug.vueError'
    },
    ui: {
        header: {
            setupChat: 'ui.header.setupChat',
            setupEditor: 'ui.header.setupEditor',
            setupGeneration: 'ui.header.setupGeneration',
            setupSubmenu: 'ui.header.setupSubmenu',
            showLbBanner: 'ui.header.showLbBanner',
            reset: 'ui.header.reset',
            updateAvatar: 'ui.header.updateAvatar',
            updateSession: 'ui.header.updateSession',
            scrollHidden: 'ui.header.scrollHidden',
            forceUpdate: 'ui.header.forceUpdate',
            viewChanged: 'ui.header.viewChanged'
        },
        chatSearchToggle: 'ui.chatSearchToggle',
        chatSearch: 'ui.chatSearch',
        fsEditorClosed: 'ui.fsEditorClosed',
        backNavigation: 'ui.backNavigation',
        glossary: {
            back: 'ui.glossary.back',
            headerUpdate: 'ui.glossary.headerUpdate',
            toggle: 'ui.glossary.toggle'
        },
        headerSearch: 'ui.headerSearch',
        changeGenerationTab: 'ui.changeGenerationTab'
    }
};

export const LEGACY_WINDOW_EVENT_MAP = {
    [APP_EVENTS.nav.openApiSheet]: 'open-api-sheet',
    [APP_EVENTS.nav.navigateTo]: 'navigate-to',
    [APP_EVENTS.nav.openCharacterEditor]: 'open-character-editor',
    [APP_EVENTS.nav.openChat]: 'open-chat',
    [APP_EVENTS.nav.openOnboarding]: 'open-onboarding',
    [APP_EVENTS.nav.openBackupSheet]: 'open-backup-sheet',
    [APP_EVENTS.nav.openSyncSheet]: 'open-sync-sheet',
    [APP_EVENTS.nav.openConflictSheet]: 'open-conflict-sheet',
    [APP_EVENTS.nav.openConnections]: 'open-connections',
    [APP_EVENTS.nav.openFsRequest]: 'open-fs-request',
    [APP_EVENTS.nav.openGlossary]: 'open-glossary',
    [APP_EVENTS.nav.openHolocards]: 'open-holocards',
    [APP_EVENTS.nav.openImageViewer]: 'open-image-viewer',
    [APP_EVENTS.nav.openItemEditor]: 'open-item-editor',
    [APP_EVENTS.nav.openLorebookEntry]: 'open-lorebook-entry',
    [APP_EVENTS.nav.openNotificationsSheet]: 'open-notifications-sheet',
    [APP_EVENTS.nav.openPersonaEditor]: 'open-persona-editor',
    [APP_EVENTS.nav.openPresetSheet]: 'open-preset-sheet',
    [APP_EVENTS.nav.triggerOpenImage]: 'trigger-open-image',
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
    [APP_EVENTS.domain.settings.languageChanged]: 'language-changed',
    [APP_EVENTS.debug.vueError]: 'vue-error',
    [APP_EVENTS.ui.header.setupChat]: 'header-setup-chat',
    [APP_EVENTS.ui.header.setupEditor]: 'header-setup-editor',
    [APP_EVENTS.ui.header.setupGeneration]: 'header-setup-generation',
    [APP_EVENTS.ui.header.setupSubmenu]: 'header-setup-submenu',
    [APP_EVENTS.ui.header.showLbBanner]: 'header-show-lb-banner',
    [APP_EVENTS.ui.header.reset]: 'header-reset',
    [APP_EVENTS.ui.header.updateAvatar]: 'header-update-avatar',
    [APP_EVENTS.ui.header.updateSession]: 'header-update-session',
    [APP_EVENTS.ui.header.scrollHidden]: 'header-scroll-hidden',
    [APP_EVENTS.ui.header.forceUpdate]: 'header-force-update',
    [APP_EVENTS.ui.header.viewChanged]: 'header-view-changed',
    [APP_EVENTS.ui.chatSearchToggle]: 'header-chat-search-toggle',
    [APP_EVENTS.ui.chatSearch]: 'header-chat-search',
    [APP_EVENTS.ui.fsEditorClosed]: 'fs-editor-closed',
    [APP_EVENTS.ui.glossary.back]: 'gl-back',
    [APP_EVENTS.ui.glossary.headerUpdate]: 'gl-header-update',
    [APP_EVENTS.ui.glossary.toggle]: 'toggle-glossary',
    [APP_EVENTS.ui.headerSearch]: 'header-search',
    [APP_EVENTS.ui.changeGenerationTab]: 'change-generation-tab'
};
