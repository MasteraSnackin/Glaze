<script setup>
import { ref, reactive, computed, watch, nextTick, defineAsyncComponent } from 'vue';
import AppHeader from '@/components/layout/AppHeader.vue';
import BottomNavigation from '@/components/layout/BottomNavigation.vue';
import DialogList from '@/views/DialogList.vue';
import BottomSheet from '@/components/ui/BottomSheet.vue';
import FabButton from '@/components/ui/FabButton.vue';
import DesktopDropdown from '@/components/ui/DesktopDropdown.vue';

const CharacterList = defineAsyncComponent(() => import('@/views/CharacterList.vue'));
const MenuView = defineAsyncComponent(() => import('@/views/Menu/MenuView.vue'));
const PresetView = defineAsyncComponent(() => import('@/views/PresetView.vue'));
const ChatView = defineAsyncComponent(() => import('@/views/ChatView.vue'));
const ThemeSettingsView = defineAsyncComponent(() => import('@/views/Menu/Settings/ThemeSettingsView.vue'));
const SettingsView = defineAsyncComponent(() => import('@/views/Menu/Settings/SettingsView.vue'));
const OnboardingView = defineAsyncComponent(() => import('@/views/OnboardingView.vue'));
const ApiView = defineAsyncComponent(() => import('@/views/ApiView.vue'));

const Editor = defineAsyncComponent(() => import('@/components/editors/GenericEditor.vue'));
const FullScreenEditor = defineAsyncComponent(() => import('@/components/editors/FullScreenEditor.vue'));

const ImageViewer = defineAsyncComponent(() => import('@/components/media/ImageViewer.vue'));
import AppToast from '@/components/ui/AppToast.vue';
import MagicDrawer from '@/components/chat/MagicDrawer.vue';
import DesktopLeftSidebar from '@/components/layout/DesktopLeftSidebar.vue';
import DesktopRightSidebar from '@/components/layout/DesktopRightSidebar.vue';
import WindowView from '@/components/ui/WindowView.vue';

const ConnectionsSheet = defineAsyncComponent(() => import('@/components/sheets/ConnectionsSheet.vue'));
const LorebookSheet = defineAsyncComponent(() => import('@/components/sheets/LorebookSheet.vue'));
const BackupSheet = defineAsyncComponent(() => import('@/components/sheets/BackupSheet.vue'));
const NotificationsSheet = defineAsyncComponent(() => import('@/components/sheets/NotificationsSheet.vue'));
const SyncSheet = defineAsyncComponent(() => import('@/components/sheets/SyncSheet.vue'));
const ConflictSheet = defineAsyncComponent(() => import('@/components/sheets/ConflictSheet.vue'));
const GlossaryView = defineAsyncComponent(() => import('@/components/sheets/GlossarySheet.vue'));
const DragDropOverlay = defineAsyncComponent(() => import('@/components/ui/DragDropOverlay.vue'));
const ToolsView = defineAsyncComponent(() => import('@/views/ToolsView.vue'));
const PersonasView = defineAsyncComponent(() => import('@/views/PersonasView.vue'));
const RegexSheet = defineAsyncComponent(() => import('@/components/sheets/RegexSheet.vue'));

import { isKeyboardOpen } from '@/core/services/keyboardHandler.js';
import { themeState } from '@/core/states/themeState.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { bottomSheetState, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { sidebarState } from '@/core/states/sidebarState.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { publishAppEvent } from '@/core/events/eventHub.js';

import { useAppNavigation } from '@/composables/app/useAppNavigation.js';
import { useEditorController, characterEditorConfig, personaEditorConfig } from '@/composables/app/useEditorController.js';
import { useGlossaryPopup } from '@/composables/app/useGlossaryPopup.js';
import { useAppEventSubscriptions } from '@/composables/app/useAppEventSubscriptions.js';
import { useAppInit } from '@/composables/app/useAppInit.js';

// --- Template refs ---
const headerRef = ref(null);
const headerContainer = ref(null);
const footerContainer = ref(null);
const dialogListRef = ref(null);
const characterListRef = ref(null);
const chatViewRef = ref(null);
const connectionsSheetRef = ref(null);
const lorebookSheetRef = ref(null);
const backupSheetRef = ref(null);
const syncSheetRef = ref(null);
const conflictSheetRef = ref(null);
const presetViewRef = ref(null);
const apiViewRef = ref(null);
const isDataLoaded = ref(false);

// --- Categories (must be before useAppInit which uses them) ---
const activeCategories = reactive({
    'view-dialogs': 'all',
    'view-characters': 'all'
});

const categories = {
    'view-dialogs': [
        { id: 'all', i18n: 'cat_all_dialogs' },
        { id: 'personal', i18n: 'cat_personal' },
        { id: 'groups', i18n: 'cat_groups' }
    ],
    'view-characters': [
        { id: 'all', i18n: 'cat_all_chars' },
        { id: 'anime', i18n: 'cat_anime' },
        { id: 'games', i18n: 'cat_games' }
    ]
};

// --- Composables ---
const nav = useAppNavigation();
const editor = useEditorController({
    currentView: nav.currentView,
    currentChatSessionId: nav.currentChatSessionId,
    waitForComponent,
    chatViewRef
});
const glossary = useGlossaryPopup({ isDesktop: nav.isDesktop });

const events = useAppEventSubscriptions({
    isDesktop: nav.isDesktop,
    currentView: nav.currentView,
    isHeaderEditorMode: nav.isHeaderEditorMode,
    activeChatCharObj: nav.activeChatCharObj,
    currentChatSessionId: nav.currentChatSessionId,
    chatPreviousView: nav.chatPreviousView,
    isGlossaryWindowOpen: glossary.isGlossaryWindowOpen,
    openCharacterEditor: editor.openCharacterEditor,
    onOpenPersonaEditor: editor.onOpenPersonaEditor,
    openChatWrapper: (char) => nav.openChatWrapper(char, { chatViewRef, waitForComponent }),
    openFsEditor: editor.openFsEditor,
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
    fsEditorVisible: editor.fsEditorVisible,
    closeAndSaveFsEditor: editor.closeAndSaveFsEditor,
    handleGlossaryOpen: glossary.handleGlossaryOpen,
    handleGlossaryToggle: glossary.handleGlossaryToggle,
    onGlossaryHeaderUpdate: glossary.onGlossaryHeaderUpdate,
    onLanguageChanged,
    isOnboarding: nav.isOnboarding
});

useAppInit({
    isOnboarding: nav.isOnboarding,
    isDataLoaded,
    isDesktop: nav.isDesktop,
    checkDesktop: nav.checkDesktop,
    updateLayoutMetrics: nav.updateLayoutMetrics,
    initBackButton: nav.initBackButton,
    headerContainer,
    footerContainer,
    categories,
    activeCategories,
    appEventUnsubs: events.appEventUnsubs,
    handleOpenChatEvent: events.handleOpenChatEvent
});

events.registerAll();

// --- Local helpers ---
function waitForComponent(refVar, callback) {
    if (refVar.value) {
        callback(refVar.value);
    } else {
        const unwatch = watch(refVar, (val) => {
            if (val) {
                callback(val);
                unwatch();
            }
        });
    }
}

function openChatFromTemplate(char) {
    nav.openChatWrapper(char, { chatViewRef, waitForComponent });
}

function onLanguageChanged() {
    if (headerRef.value) headerRef.value.updateHeader();
}

// --- Z-index computed ---
const headerZIndex = computed(() => {
    if (editor.fsEditorVisible.value) return 12001;
    if (editor.isEditorView.value) return 1100;
    return 100;
});

const mainZIndex = computed(() => {
    if (editor.isEditorView.value) return 1000;
    return 1;
});

// --- Layout metrics ---
nav.setLayoutMetricsUpdater(() => {
    if (headerContainer.value) {
        const h = headerContainer.value.offsetHeight;
        document.documentElement.style.setProperty('--header-height', `${h}px`);
    }
    if (nav.isDesktop.value) {
        document.documentElement.style.setProperty('--footer-height', '0px');
    } else if (footerContainer.value) {
        document.documentElement.style.setProperty('--footer-height', `${footerContainer.value.offsetHeight}px`);
    }
});

// --- FAB Logic ---
const fabConfig = computed(() => {
    if (nav.currentView.value === 'view-dialogs' && !nav.isDesktop.value) {
        return {
            text: translations[currentLang.value]?.btn_new_chat || 'New Chat',
            action: () => dialogListRef.value?.openNewChatPicker()
        };
    } else if (nav.currentView.value === 'view-characters' && !nav.isDesktop.value) {
        return {
            text: translations[currentLang.value]?.btn_add || 'Add',
            action: () => characterListRef.value?.onAddCharacter()
        };
    }
    return null;
});

const showLogo = computed(() => {
    return !['view-chat', 'view-character-edit', 'view-persona-edit', 'view-theme-settings', 'view-settings',
             'view-tools', 'view-api', 'view-presets', 'view-lorebook', 'view-regex', 'view-personas'].includes(nav.currentView.value) && !nav.isHeaderEditorMode.value;
});

const mainStyle = computed(() => {
    if (!themeState.hasBackgroundImage) return {};
    return {
        backgroundImage: 'url("data:image/svg+xml,%3Csvg width=\'200\' height=\'200\' viewBox=\'0 0 200 200\' xmlns=\'http://www.w3.org/2000/svg\'%3E%3Cfilter id=\'noiseFilter\'%3E%3CfeTurbulence type=\'fractalNoise\' baseFrequency=\'0.8\' numOctaves=\'3\' stitchTiles=\'stitch\'/%3E%3C/filter%3E%3Crect width=\'100%25\' height=\'100%25\' filter=\'url(%23noiseFilter)\' opacity=\'0.05\'/%3E%3C/svg%3E")',
        backgroundRepeat: 'repeat',
        backgroundPosition: '0 0',
        backgroundSize: '200px 200px'
    };
});

// --- FS editor header watcher ---
watch(editor.fsEditorVisible, (val) => {
    if (val) {
        publishAppEvent(APP_EVENTS.ui.header.setupEditor, {
            title: translations[currentLang.value]?.header_editor || 'Editor',
            onBack: () => { editor.fsEditorVisible.value = false; },
            actions: [{
                icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                onClick: editor.closeAndSaveFsEditor
            }]
        });
    } else {
        if (headerRef.value) headerRef.value.updateHeader();
        publishAppEvent(APP_EVENTS.ui.fsEditorClosed);
    }
});

// --- Editor close wrapper (needs nav + editor cross-refs) ---
function closeEditorWrapper() {
    editor.closeEditor({
        activeChatCharObj: nav.activeChatCharObj,
        currentChatSessionId: nav.currentChatSessionId,
        chatPreviousView: nav.chatPreviousView,
        isHeaderEditorMode: nav.isHeaderEditorMode
    });
}
</script>

<template>
  <div class="app-layout" :class="{ 'desktop-mode': nav.isDesktop.value }" :style="mainStyle">
    <!-- Onboarding Overlay -->
    <Transition name="fade">
        <OnboardingView v-if="nav.isOnboarding.value" @finish="nav.finishOnboarding" />
    </Transition>

    <!-- Header Component -->
    <div class="header-container" ref="headerContainer" :style="{ zIndex: headerZIndex }">
        <AppHeader
            ref="headerRef"
            :current-view="nav.effectiveMainView.value"
            :is-active="!nav.isDesktopFloating.value"
            :categories="categories"
            :editing-index="editor.headerEditingIndex.value"
            @action-save="editor.handleHeaderSave"
            @action-delete="editor.handleHeaderDelete"
            @action-close="closeEditorWrapper"
        />
    </div>

    <!-- App Body: flex row on desktop (sidebars + main) -->
    <div class="app-body">

      <!-- Desktop Left Sidebar: always-visible chat list + nav -->
      <DesktopLeftSidebar 
          v-if="nav.isDesktop.value"
          :current-view="nav.currentView.value"
          :active-categories="activeCategories"
          :is-desktop-floating="nav.isDesktopFloating.value"
          :is-glossary-open="glossary.isGlossaryWindowOpen.value"
          @update:current-view="nav.currentView.value = $event"
          @open-chat="openChatFromTemplate"
      />

      <!-- Main Content Area -->
      <main id="main-container" v-if="isDataLoaded" :style="{ zIndex: mainZIndex }" :class="{ 'keyboard-open': isKeyboardOpen && nav.effectiveMainView.value !== 'view-chat', 'chat-view-main': nav.effectiveMainView.value === 'view-chat' }">

        <Transition name="fade">
            <!-- VIEW 1: DIALOGS -->
            <div id="view-dialogs" class="view active-view" v-if="nav.effectiveMainView.value === 'view-dialogs' && !nav.isDesktop.value">
                <DialogList
                    ref="dialogListRef"
                    :active-category="activeCategories['view-dialogs']"
                    @open-chat="openChatFromTemplate"
                />
            </div>

            <!-- VIEW 2: CHARACTERS -->
            <div id="view-characters" class="view active-view" v-else-if="nav.effectiveMainView.value === 'view-characters'">
                <CharacterList
                    ref="characterListRef"
                    :active-category="activeCategories['view-characters']"
                    @open-chat="openChatFromTemplate"
                />
            </div>

            <!-- VIEW 3: MENU -->
            <MenuView
                class="view active-view view-gray-bg"
                v-else-if="nav.effectiveMainView.value === 'view-menu' && !nav.isDesktopFloating.value"
            />

            <!-- VIEW: GLOSSARY -->
            <GlossaryView
                class="view active-view view-gray-bg"
                v-else-if="nav.effectiveMainView.value === 'view-glossary' && !nav.isDesktopFloating.value"
                :view-mode="true"
            />

            <!-- VIEW: THEME SETTINGS -->
            <ThemeSettingsView
                class="view active-view view-gray-bg"
                v-else-if="nav.effectiveMainView.value === 'view-theme-settings' && !nav.isDesktopFloating.value"
            />

            <!-- VIEW: SETTINGS -->
            <SettingsView
                class="view active-view view-gray-bg"
                v-else-if="nav.effectiveMainView.value === 'view-settings' && !nav.isDesktopFloating.value"
            />

            <!-- VIEW: TOOLS HUB -->
            <ToolsView
                class="view active-view view-gray-bg"
                v-else-if="nav.effectiveMainView.value === 'view-tools'"
            />

            <!-- VIEW: API (fullscreen) -->
            <ApiView
                class="view active-view view-gray-bg"
                v-else-if="nav.effectiveMainView.value === 'view-api'"
                :view-mode="true"
            />

            <!-- VIEW: PRESETS (fullscreen) -->
            <PresetView
                class="view active-view view-gray-bg"
                v-else-if="nav.effectiveMainView.value === 'view-presets'"
                :view-mode="true"
            />

            <!-- VIEW: LOREBOOK (fullscreen) -->
            <LorebookSheet
                class="view active-view view-gray-bg"
                v-else-if="nav.effectiveMainView.value === 'view-lorebook'"
                :view-mode="true"
            />

            <!-- VIEW: REGEX (fullscreen) -->
            <RegexSheet
                class="view active-view view-gray-bg"
                v-else-if="nav.effectiveMainView.value === 'view-regex'"
                :view-mode="true"
            />

            <!-- VIEW: PERSONAS (fullscreen) -->
            <PersonasView
                class="view active-view view-gray-bg"
                v-else-if="nav.effectiveMainView.value === 'view-personas'"
                :view-mode="true"
            />

            <!-- VIEW 5: CHAT -->
            <ChatView class="view active-view" v-else-if="nav.effectiveMainView.value === 'view-chat'" ref="chatViewRef" />

            <!-- VIEW 6: CHARACTER / PERSONA EDITOR -->
            <Editor
                class="view active-view"
                v-else-if="nav.effectiveMainView.value === 'view-character-edit' || nav.effectiveMainView.value === 'view-persona-edit'"
                :model-value="nav.effectiveMainView.value === 'view-character-edit' ? (editor.editingCharacter.value || {}) : (editor.editingPersona.value || {})"
                :config="nav.effectiveMainView.value === 'view-character-edit' ? characterEditorConfig : personaEditorConfig"
                :show-avatar="true"
                @update:model-value="(val) => nav.effectiveMainView.value === 'view-character-edit' ? editor.editingCharacter.value = val : editor.editingPersona.value = val"
                @save="editor.handleEditorAutoSave"
                @close="closeEditorWrapper"
                @open-fs="editor.openFsEditor"
            />
        </Transition>
      </main>

      <!-- Desktop: Floating menu overlay -->
      <WindowView :nav="nav">
          <MenuView v-if="nav.currentView.value === 'view-menu'" class="view-gray-bg window-panel" />
          <!-- glossary has its own corner popup, not shown here -->
          <ThemeSettingsView v-else-if="nav.currentView.value === 'view-theme-settings'" class="view-gray-bg window-panel" />
          <SettingsView v-else-if="nav.currentView.value === 'view-settings'" class="view-gray-bg window-panel" />
      </WindowView>

      <!-- Desktop: Glossary corner popup -->
      <Transition name="glossary-popup">
          <div v-if="glossary.isDesktopGlossary.value" class="desktop-glossary-popup" :style="glossary.glossaryStyle.value">
              <div class="desktop-glossary-popup-header" @mousedown="glossary.startGlossaryDrag">
                  <button v-if="glossary.glossaryCanGoBack.value" class="desktop-glossary-popup-back" @click="glossary.onGlossaryBack">
                      <svg viewBox="0 0 24 24"><path d="M20 11H7.83l5.59-5.59L12 4l-8 8 8 8 1.41-1.41L7.83 13H20v-2z"/></svg>
                  </button>
                  <span class="desktop-glossary-popup-title" :class="{ 'pl-3': !glossary.glossaryCanGoBack.value }">{{ glossary.glossaryPopupTitle.value }}</span>
                  <button class="desktop-glossary-popup-close" @click="glossary.isGlossaryWindowOpen.value = false">
                      <svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
                  </button>
              </div>
              <GlossaryView class="view view-gray-bg" :view-mode="true" />
          </div>
      </Transition>

      <!-- Desktop Right Sidebar: MagicDrawer panel -->
      <DesktopRightSidebar
          v-if="nav.isDesktop.value"
          :bottom-sheet-state="bottomSheetState"
          :right-sidebar-state="sidebarState"
          :active-chat-char-obj="nav.activeChatCharObj.value"
          :context-breakdown="chatViewRef?.contextBreakdown"
          :current-view="nav.currentView.value"
          @close-bottom-sheet="closeBottomSheet"
          @magic-notes="chatViewRef?.openAuthorsNoteSheet()"
          @magic-context="chatViewRef?.openContextSheet()"
          @magic-summary="chatViewRef?.openSummarySheet()"
          @magic-sessions="chatViewRef?.openSessionsSheet()"
          @magic-stats="chatViewRef?.openChatStatsSheet()"
          @magic-impersonate="chatViewRef?.startImpersonation()"
          @magic-char-card="chatViewRef?.openCharCard()"
          @magic-api="chatViewRef?.openApiView()"
          @magic-presets="chatViewRef?.openPresetView()"
          @magic-lorebooks="chatViewRef?.openLorebookSheet()"
          @magic-memory-books="chatViewRef?.openMemoryBooksSheet()"
          @magic-regex="chatViewRef?.openRegexSheet()"
          @magic-image-gen="chatViewRef?.openImageGenSheet()"
          @magic-glossary="glossary.isGlossaryWindowOpen.value = true"
          @request-preview="chatViewRef?.openRequestPreviewSheet()"
      />

      <!-- Floating Action Button: Positioned relative to grid on Desktop -->
      <Transition name="fab">
          <div v-if="fabConfig" class="desktop-fab-container">
            <FabButton :text="fabConfig.text" @click="fabConfig.action">
                <template #icon>
                    <svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>
                </template>
            </FabButton>
          </div>
      </Transition>
    </div>

    <!-- Bottom Navigation Bar (mobile only — desktop uses left sidebar) -->
    <div v-if="!nav.isDesktop.value" class="footer-container" ref="footerContainer">
        <BottomNavigation v-model:current-view="nav.currentView.value" />
    </div>

    <!-- Global Bottom Sheet (disabled on desktop chat view where right sidebar takes over) -->
    <BottomSheet
        v-if="!nav.isDesktop.value || nav.currentView.value !== 'view-chat'"
        :visible="bottomSheetState.visible"
        :locked="bottomSheetState.locked"
        :title="bottomSheetState.title"
        :help-tip="bottomSheetState.helpTip"
        :content="bottomSheetState.content"
        :items="bottomSheetState.items"
        :header-action="bottomSheetState.headerAction"
        :big-info="bottomSheetState.bigInfo"
        :session-items="bottomSheetState.sessionItems"
        :card-items="bottomSheetState.cardItems"
        :input="bottomSheetState.input"
        @close="closeBottomSheet"
    />

    <!-- Global Desktop Dropdown (replaces bottom sheets for simple selects on PC) -->
    <DesktopDropdown />

    <!-- Standard Image Viewer -->
    <ImageViewer />

    <!-- Toast -->
    <AppToast />
  </div>

  <ConnectionsSheet ref="connectionsSheetRef" />
  <LorebookSheet ref="lorebookSheetRef" />
  <BackupSheet ref="backupSheetRef" />
  <SyncSheet ref="syncSheetRef" />
  <ConflictSheet ref="conflictSheetRef" />
  <PresetView ref="presetViewRef" />
  <ApiView ref="apiViewRef" />

  <!-- Full Screen Editor (Managed by App.vue now) -->
  <FullScreenEditor 
      :visible="editor.fsEditorVisible.value"
      v-model="editor.fsEditorValue.value"
      @save="editor.autoSaveFsEditor"
      @close="editor.fsEditorVisible.value = false"
  />
  <NotificationsSheet />
  <DragDropOverlay />

</template>

<style>
.desktop-mode .desktop-fab-container {
    grid-column: 2;
    grid-row: 1;
    position: relative;
    pointer-events: none;
    z-index: 1000;
}

.desktop-mode .desktop-fab-container .fab-add {
    position: absolute !important;
    bottom: 24px;
    right: 24px;
    pointer-events: auto;
}

.header-container {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    z-index: 100;
    pointer-events: none;
    display: flex;
    flex-direction: column;
}

.header-container > * {
    pointer-events: auto;
}

.footer-container {
    position: absolute;
    bottom: 0;
    left: 0;
    width: 100%;
    z-index: 100;
    pointer-events: none;
    display: flex;
    flex-direction: column;
}

.footer-container > * {
    pointer-events: auto;
}

#main-container {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    overflow-y: overlay;
    overflow-x: hidden;
    z-index: 1;
}

#main-container::-webkit-scrollbar-track {
    margin-top: calc(var(--header-height, 60px) + 12px);
    margin-bottom: calc(var(--footer-height, 80px) + 12px);
}

#main-container.chat-view-main {
    overflow-y: hidden;
}

#main-container.keyboard-open {
    padding-bottom: var(--keyboard-overlap, 0px) !important;
}

.active-view::-webkit-scrollbar-track {
    background-color: transparent;
}

.view {
    padding-top: calc(var(--header-height, 60px) + 16px) !important;
    padding-bottom: calc(var(--footer-height, 80px) + 20px) !important;
    box-sizing: border-box;
}

/* Views that own their scroll container (virtual scroll) get footer clearance here.
   --footer-height is 0px on desktop, actual nav height on mobile. */
#main-container .view-content-wrapper {
    padding-bottom: calc(var(--footer-height, 80px) + 20px);
}

/* If a view contains a sub-view, delegate padding to the sub-view */
.view:has(.sub-view) {
    padding-top: 0;
    padding-bottom: 0;
}

.sub-view {
    padding-top: calc(var(--header-height, 60px) + 10px);
    padding-bottom: calc(var(--footer-height, 80px) + 20px);
    box-sizing: border-box;
}

/* ChatView handles its own layout/padding */

/* Global override for body to prevent WebView scrolling/panning */
body.no-scroll {
    position: fixed !important;
    width: 100% !important;
    height: 100% !important;
    overflow: hidden !important;
    overscroll-behavior: none !important;
    touch-action: none;
}

/* Re-enable touch for scrollable areas while body is locked */
body.no-scroll #chat-messages,
body.no-scroll .chat-input-editable,
body.no-scroll .edit-textarea,
body.no-scroll .magic-drawer,
body.no-scroll .bottom-sheet-content {
    touch-action: pan-y;
}
</style>
