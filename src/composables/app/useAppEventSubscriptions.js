import { subscribeAppEvent, publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { allPersonas, loadPersonas } from '@/core/states/personaState.js';
import { initTheme } from '@/core/states/themeState.js';
import { initLorebookState } from '@/core/states/lorebookState.js';
import { initPresetState } from '@/core/states/presetState.js';
import { applyApiRuntimeConfig } from '@/core/config/APISettings.js';
import { imageViewerMode } from '@/core/config/APPSettings.js';
import { logger } from '@/utils/logger.js';
import { db } from '@/utils/db.js';

export function useAppEventSubscriptions({
    isDesktop,
    currentView,
    isHeaderEditorMode,
    activeChatCharObj,
    currentChatSessionId,
    chatPreviousView,
    isGlossaryWindowOpen,
    openCharacterEditor,
    onOpenPersonaEditor,
    openChatWrapper,
    openFsEditor,
    waitForComponent,
    chatViewRef,
    connectionsSheetRef,
    lorebookSheetRef,
    backupSheetRef,
    syncSheetRef,
    conflictSheetRef,
    presetViewRef,
    apiViewRef,
    characterListRef,
    headerRef,
    fsEditorVisible,
    closeAndSaveFsEditor,
    handleGlossaryOpen,
    handleGlossaryToggle,
    onGlossaryHeaderUpdate,
    onLanguageChanged,
    isOnboarding
}) {
    const appEventUnsubs = [];

    const onNavigateTo = (detail) => { currentView.value = detail; };
    const onOpenOnboarding = () => {
        isOnboarding.value = true;
    };

    const onTriggerOpenImage = (detail) => {
        const { src, description, onCloseCallback } = detail;
        logger.debug('[App] trigger-open-image. Current Mode:', imageViewerMode.value);
        logger.debug('[App] trigger-open-image. Always using default viewer.');
        publishAppEvent(APP_EVENTS.nav.openImageViewer, { src, description, onCloseCallback });
    };

    const onOpenConnections = (detail) => {
        const { type, id, name } = detail || {};
        waitForComponent(connectionsSheetRef, (comp) => {
            comp.open(type, id, name, activeChatCharObj.value);
        });
    };

    const onOpenItemEditor = (detail) => {
        const { type, id } = detail;
        if (type === 'lorebook') {
            waitForComponent(lorebookSheetRef, (comp) => {
                comp.openLorebook(id);
            });
        } else if (type === 'preset') {
            waitForComponent(presetViewRef, (comp) => {
                comp.openPreset(id);
            });
        } else if (type === 'persona') {
            const index = allPersonas.value.findIndex(p => p.id === id);
            if (index !== -1) {
                const persona = allPersonas.value[index];
                publishAppEvent(APP_EVENTS.nav.openPersonaEditor, { index, persona });
            }
        }
    };

    const onOpenLorebookEntry = (detail) => {
        const { lorebookId, entryId } = detail;
        if (currentView.value === 'view-chat') {
            waitForComponent(chatViewRef, (comp) => {
                comp.openLorebookEntry(lorebookId, entryId);
            });
        }
    };

    const onOpenBackupSheet = () => {
        if (isDesktop.value && currentView.value === 'view-menu') {
            currentView.value = 'view-backup';
        } else {
            waitForComponent(backupSheetRef, (comp) => { comp.open(); });
        }
    };

    const onOpenSyncSheet = () => {
        if (isDesktop.value && currentView.value === 'view-menu') {
            currentView.value = 'view-sync';
        } else {
            waitForComponent(syncSheetRef, (comp) => { comp.open(); });
        }
    };

    const onOpenConflictSheet = () => {
        waitForComponent(conflictSheetRef, (comp) => { comp.open(); });
    };

    const onOpenPresetSheet = (detail) => {
        waitForComponent(presetViewRef, (comp) => {
            const presetId = detail?.presetId;
            if (presetId) {
                comp.openPreset(presetId, true);
            } else {
                comp.open();
            }
        });
    };

    const onOpenApiSheet = () => {
        waitForComponent(apiViewRef, (comp) => { comp.open(); });
    };

    const onHeaderSetupEditor = () => { isHeaderEditorMode.value = true; };
    const onHeaderSetupGeneration = () => { isHeaderEditorMode.value = false; };
    const onHeaderReset = () => { isHeaderEditorMode.value = false; };

    const reloadSyncedData = async () => {
        await Promise.all([
            loadPersonas(),
            initTheme(),
            initLorebookState(true),
            initPresetState(true)
        ]);
        applyApiRuntimeConfig({});
        if (characterListRef.value?.loadCharacters) {
            await characterListRef.value.loadCharacters();
        }
    };

    const onSyncDataRefreshed = async () => {
        await reloadSyncedData();
    };

    const handleOpenChatEvent = async (detail) => {
        logger.debug("[App] Received open-chat event:", detail);
        const data = detail;
        const charId = typeof data === 'object' ? data.charId : data;
        const sessionId = typeof data === 'object' ? data.sessionId : null;
        const msgId = typeof data === 'object' ? data.msgId : null;

        if (!charId) return;

        const chars = await db.getAll('characters');
        const char = chars.find(c => c.id === charId);
        if (char) {
            if (sessionId) char.sessionId = sessionId;
            if (msgId) char.msgId = msgId;
            currentView.value = 'view-dialogs';
            openChatWrapper(char);
        }
    };

    function registerAll() {
        appEventUnsubs.push(subscribeAppEvent(APP_EVENTS.nav.openCharacterEditor, ({ detail }) => openCharacterEditor(detail.index)));
        appEventUnsubs.push(subscribeAppEvent(APP_EVENTS.nav.openPersonaEditor, ({ detail }) => onOpenPersonaEditor(detail)));
        appEventUnsubs.push(subscribeAppEvent(APP_EVENTS.nav.navigateTo, ({ detail }) => onNavigateTo(detail)));
        appEventUnsubs.push(subscribeAppEvent(APP_EVENTS.domain.settings.languageChanged, onLanguageChanged));
        appEventUnsubs.push(subscribeAppEvent(APP_EVENTS.nav.openChat, ({ detail }) => handleOpenChatEvent(detail)));
        appEventUnsubs.push(subscribeAppEvent(APP_EVENTS.nav.openOnboarding, onOpenOnboarding));

        appEventUnsubs.push(subscribeAppEvent(APP_EVENTS.nav.triggerOpenImage, ({ detail }) => onTriggerOpenImage(detail)));
        appEventUnsubs.push(subscribeAppEvent(APP_EVENTS.nav.openFsRequest, ({ detail }) => openFsEditor(detail)));
        appEventUnsubs.push(subscribeAppEvent(APP_EVENTS.nav.openConnections, ({ detail }) => onOpenConnections(detail)));
        appEventUnsubs.push(subscribeAppEvent(APP_EVENTS.nav.openItemEditor, ({ detail }) => onOpenItemEditor(detail)));
        appEventUnsubs.push(subscribeAppEvent(APP_EVENTS.nav.openLorebookEntry, ({ detail }) => onOpenLorebookEntry(detail)));
        appEventUnsubs.push(subscribeAppEvent(APP_EVENTS.nav.openBackupSheet, onOpenBackupSheet));
        appEventUnsubs.push(subscribeAppEvent(APP_EVENTS.nav.openSyncSheet, onOpenSyncSheet));
        appEventUnsubs.push(subscribeAppEvent(APP_EVENTS.nav.openConflictSheet, onOpenConflictSheet));
        appEventUnsubs.push(subscribeAppEvent(APP_EVENTS.nav.openPresetSheet, ({ detail }) => onOpenPresetSheet(detail)));
        appEventUnsubs.push(subscribeAppEvent(APP_EVENTS.nav.openApiSheet, onOpenApiSheet));
        appEventUnsubs.push(subscribeAppEvent(APP_EVENTS.ui.header.setupEditor, onHeaderSetupEditor));
        appEventUnsubs.push(subscribeAppEvent(APP_EVENTS.ui.header.setupGeneration, onHeaderSetupGeneration));
        appEventUnsubs.push(subscribeAppEvent(APP_EVENTS.ui.header.reset, onHeaderReset));
        appEventUnsubs.push(subscribeAppEvent(APP_EVENTS.domain.sync.dataRefreshed, onSyncDataRefreshed));

        appEventUnsubs.push(subscribeAppEvent(APP_EVENTS.domain.character.updated, (e) => {
            const char = e?.detail?.character;
            if (char && activeChatCharObj.value && String(char.id) === String(activeChatCharObj.value.id)) {
                const sessionId = activeChatCharObj.value.sessionId;
                activeChatCharObj.value = { ...char, sessionId };
            } else if (!char && activeChatCharObj.value) {
                const charId = activeChatCharObj.value.id;
                db.getAll('characters').then(chars => {
                    const fresh = chars.find(c => String(c.id) === String(charId));
                    if (fresh) {
                        const sessionId = activeChatCharObj.value.sessionId;
                        activeChatCharObj.value = { ...fresh, sessionId };
                    }
                });
            }
        }));

        appEventUnsubs.push(subscribeAppEvent(APP_EVENTS.nav.openGlossary, handleGlossaryOpen));
        appEventUnsubs.push(subscribeAppEvent(APP_EVENTS.ui.glossary.toggle, handleGlossaryToggle));
        appEventUnsubs.push(subscribeAppEvent(APP_EVENTS.ui.glossary.headerUpdate, ({ detail }) => onGlossaryHeaderUpdate(detail)));
    }

    return {
        appEventUnsubs,
        handleOpenChatEvent,
        registerAll
    };
}
