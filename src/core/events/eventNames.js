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
