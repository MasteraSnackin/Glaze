<script>
// --- Module Level State (Persists across component mounts) ---
let activeChatChar = null;
let _cleanupScroll = null;
let _msgIdCounter = 0;
let unsubCharacterUpdated = null;
let unsubGenerationEnded = null;
let unsubFsEditorClosed = null;
let unsubChatSearchToggle = null;
let unsubRegexChanged = null;
let unsubChatSearch = null;
let unsubApiContextChanged = null;
let unsubSettingsChanged = null;

import * as memoryBooksService from '@/core/services/memoryBooksService.js';

// Import Memory Books functions from service
const {
    createEmptyMemoryCoverage,
    createBaseMessageMeta,
    reconcileSessionMemoryState,
    runMemoryMaintenancePass,
    formatElapsedSeconds,
    genMemoryEntryId,
    genMemoryPromptId,
    normalizeMemoryEntryShape,
    parseMemoryKeyInput,
    buildMemoryKeysFromText,
    indexMemoryEntryIfNeeded,
    deleteMemoryEntryIndexIfPresent,
    reindexMemoryEntry,
    shouldEnableMemoryVectorSearch,
    getMemoryVectorSearchEnabled
} = memoryBooksService;
</script>

<script setup>
import { ref, nextTick, onMounted, onUnmounted, watch, computed, onBeforeUnmount } from 'vue';
import { Capacitor } from '@capacitor/core';
import { App } from '@capacitor/app';
import { keyboardOverlap } from '@/core/services/keyboardHandler.js';
import { estimateTokens } from '@/utils/tokenizer.js';
import { cleanText } from '@/utils/textFormatter.js';
import { getEffectivePersona, activePersona, allPersonas } from '@/core/states/personaState.js';
import { formatDate, formatDateSeparator } from '@/utils/dateFormatter.js';
import { currentLang, chatPaddingLR, setChatPaddingLR, shouldUseBatterySaverUI } from '@/core/config/APPSettings.js';
import { translations } from '@/utils/i18n.js';
import { calculateContext } from '@/core/llm/usecases/calculateContext.js';
import { createChatGenerationServices } from '@/core/llm/usecases/generateChat.js';
import { executeImpersonationUseCase } from '@/core/llm/usecases/impersonationRequest.js';
import { buildGenerationAuthorsNote } from '@/composables/chat/useGenerationPreparation.js';
import { useGenerationAbort } from '@/composables/chat/useGenerationAbort.js';
import { getApiRuntimeStorage } from '@/core/config/APISettings.js';
import { getActiveLLMProfile } from '@/core/config/ProviderProfiles.js';
import { getEmbeddingConfig, isEmbeddingConfigured } from '@/core/config/embeddingSettings.js';
import { animateTextChange, updateAppColors, initHeaderScroll, initRipple } from '@/core/services/ui.js';
import { showBottomSheet, closeBottomSheet, bottomSheetState } from '@/core/states/bottomSheetState.js';
import { db } from '@/utils/db.js';
import { createNewSession as dbCreateSession, deleteSession as dbDeleteSession, switchSession as dbSwitchSession, getAllGreetings, getChatData } from '@/utils/sessions.js';
import { lorebookState, getActiveLorebooksForContext } from '@/core/states/lorebookState.js';
import { presetState, getEffectivePreset, getEffectivePresetId } from '@/core/states/presetState.js';
import { useVirtualScroll } from '@/composables/chat/useVirtualScroll.js';
import { useGenerationRegistry } from '@/composables/chat/useGenerationRegistry.js';
import { useTypingStateCleanup } from '@/composables/chat/useTypingStateCleanup.js';
import { useSidebarResizer } from '@/composables/ui/useSidebarResizer.js';
import { sendMessageNotification, clearMessageNotifications } from '@/core/services/notificationService.js';
import { formatError } from '@/utils/errors.js';
import { themeState } from '@/core/states/themeState.js';
import { triggerChatImport } from '@/core/services/chatImporter.js';
import { setTrackedContext } from '@/core/services/timeTracker.js';
import ChatMessage from '@/components/chat/ChatMessage.vue';
import ChatInput from '@/components/chat/ChatInput.vue';
import PresetView from '@/views/PresetView.vue';
import CharacterCardSheet from '@/components/sheets/CharacterCardSheet.vue';
import LorebookSheet from '@/components/sheets/LorebookSheet.vue';
import RegexSheet from '@/components/sheets/RegexSheet.vue';
import StatsSheet from '@/components/sheets/StatsSheet.vue';
import TokenizerSheet from '@/components/sheets/TokenizerSheet.vue';
import ImageGenSheet from '@/components/sheets/ImageGenSheet.vue';
import GlossarySheet from '@/components/sheets/GlossarySheet.vue';
import MemoryBooksSheet from '@/components/sheets/MemoryBooksSheet.vue';
import { addDeletedStats, migrateStatsIfNeeded } from '@/core/services/statsService.js';
import { showToast } from '@/core/states/toastState.js';
import { triggerAutoSyncCheck } from '@/composables/chat/useAutoSync.js';
import { useMemoryBooks } from '@/composables/chat/useMemoryBooks.js';
import { useMemoryAutomation } from '@/composables/chat/useMemoryAutomation.js';
import { useChatMessageDisplay, restoreVisibleSwipeState } from '@/composables/chat/useChatMessageDisplay.js';
import { useContextBreakdown } from '@/composables/chat/useContextBreakdown.js';
import { useMessageSelection } from '@/composables/chat/useMessageSelection.js';
import { useChatSearch } from '@/composables/chat/useChatSearch.js';
import { useMemorySheetUI } from '@/composables/chat/useMemorySheetUI.js';
import { useSwipeNavigation } from '@/composables/chat/useSwipeNavigation.js';
import { useSessionManagement } from '@/composables/chat/useSessionManagement.js';
import { useMessageActions } from '@/composables/chat/useMessageActions.js';
import { useChatGeneration } from '@/composables/chat/useChatGeneration.js';
import { publishAppEvent, subscribeAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';

function genMsgId() {
    return `msg_${Date.now()}_${++_msgIdCounter}`;
}
import { getMemoryPromptOptions, getMemoryPromptLabel, getMemoryPromptLabelByKey, getNormalizedMemoryGenerationState } from '@/core/services/memoryPromptPresets.js';
import * as contextService from '@/core/services/contextService.js';

// Import additional memory service functions needed locally
const {
    getMemoryKeyMatchMode,
    setMemoryVectorSearchOnEntries,
    reindexAllMemoryEntries
} = memoryBooksService;

let chatGenerationServices = null;

const t = (key) => translations[currentLang.value]?.[key] || key;

const isAndroid = Capacitor.getPlatform() === 'android';
const isBatterySaverUI = computed(() => shouldUseBatterySaverUI());
const formatGenerationElapsed = (startTime) => {
    const elapsedSeconds = (Date.now() - startTime) / 1000;
    return isBatterySaverUI.value
        ? elapsedSeconds.toFixed(0) + 's'
        : elapsedSeconds.toFixed(1) + 's';
};
const getGenerationTimerInterval = () => isBatterySaverUI.value ? 1000 : 100;
const currentMessages = ref([]);
const {
    nextGenerationId,
    listGeneratingCharIds,
    getGenerationState,
    hasGenerationState,
    setGenerationState,
    isGenerationStateCurrent,
    clearGenerationState,
    markGenerationPersisted,
    clearPersistedGeneration,
    buildGenerationOwnerKey,
    createGenerationRequestToken
} = useGenerationRegistry();
const restartVisibleGenerationTimers = () => {
    if (!activeChatChar) return;

    const state = getGenerationState(activeChatChar.id);
    if (!state) return;

    if (typeof state.restartGenerationTimer === 'function') {
        state.restartGenerationTimer();
        return;
    }

    if (state.timerId) clearTimeout(state.timerId);
    state.timerId = setTimeout(() => {
        state.timerId = null;
        const idx = currentMessages.value.findIndex(m => m.id === state.msgId);
        if (idx !== -1) {
            currentMessages.value[idx].genTime = formatGenerationElapsed(state.startTime);
        }
    }, getGenerationTimerInterval());
};

let abortActiveChatGeneration = async () => false;
let abortAnyActiveGeneration = async () => false;
const { clearTypingStateForMessage } = useTypingStateCleanup({ currentMessages, getChatData, db });

// --- Component State ---
const chatViewRoot = ref(null);
const messagesContainer = ref(null);
const chatInputContainer = ref(null);

const chatRootStyle = computed(() => {
    return {
        '--chat-padding-lr': (chatPaddingLR.value > 0) ? `${chatPaddingLR.value}px` : '0px'
    };
});

const { width: leftPaddingRef, startResize: startLeftPaddingResize } = useSidebarResizer('gz_chat_padding_lr', chatPaddingLR.value, 'left', 0, 800);
const { width: rightPaddingRef, startResize: startRightPaddingResize } = useSidebarResizer('gz_chat_padding_lr', chatPaddingLR.value, 'right', 0, 800);

watch(leftPaddingRef, (val) => {
    setChatPaddingLR(val);
    if (rightPaddingRef.value !== val) rightPaddingRef.value = val;
});
watch(rightPaddingRef, (val) => {
    setChatPaddingLR(val);
    if (leftPaddingRef.value !== val) leftPaddingRef.value = val;
});

const chatInputRef = ref(null);
const inputValue = ref('');
const isImpersonating = ref(false);
const isGenerating = ref(false);
const showScrollButton = ref(false);
const isLoading = ref(false);
let currentOnBack = null;
let inputResizeObserver = null;
const cutoffIndex = ref(-1);
const apiView = ref(null);
const statsSheet = ref(null);
const tokenizerSheet = ref(null);
const imageGenSheet = ref(null);
const openImageGenSheet = () => imageGenSheet.value?.open();
const glossarySheet = ref(null);
const openGlossarySheet = () => glossarySheet.value?.open();
const memoryBooksSheet = ref(null);
const presetView = ref(null);
const charCardSheet = ref(null);
const lorebookSheet = ref(null);
const regexSheet = ref(null);
const activeChar = ref(null);
({ abortActiveChatGeneration, abortAnyActiveGeneration } = useGenerationAbort({
    getGenerationState,
    clearGenerationState,
    isGenerating,
    isImpersonating,
    activeChatChar: activeChar
}));
const regexRevision = ref(0);
// Initialize Memory Books composable
const {
    currentMemoryBookData,
    pendingMemoryMessageIds,
    draftMemoryMessageIds,
    memoryDraftState,
    loadCurrentMemoryBook,
    updatePendingMemoryMessageIds,
    startMemoryDraftProgress,
    stopMemoryDraftProgress,
    cancelMemoryDraft,
    setMemoryDraftAbortController,
    getMemoryDraftAbortController,
    handleMemorySearchTypeUpdate: handleMemorySearchTypeUpdate_composable,
    handleMemoryReindexAll: handleMemoryReindexAll_composable,
    handleMemoryScanChat: handleMemoryScanChat_composable,
    handleMemoryApproveDraft: handleMemoryApproveDraft_composable,
    handleMemoryDeleteDraft: handleMemoryDeleteDraft_composable,
    handleMemoryDeleteAllDrafts: handleMemoryDeleteAllDrafts_composable,
    handleMemoryDeleteEntry: handleMemoryDeleteEntry_composable,
    handleMemoryCancelDraft: handleMemoryCancelDraft_composable,
    handleMemoryOpenMaintenance: handleMemoryOpenMaintenance_composable
} = useMemoryBooks({
    getChatData,
    showToast,
    showBottomSheet,
    closeBottomSheet,
    formatError,
    db
});

let openMemoryBooksSheet = () => {};

const {
    createPendingMemoryDraft,
    generateMemoryDraftForMessages,
    runMemoryAutomationAfterStableTurn,
    bootstrapImportedMemoryDrafts,
    buildMemoryContinuityContext,
    buildMemoryDraftLoreContext,
    buildMemoryDraftSummaryExcerpt,
    parseMemoryDraftResponse,
    runBatchDraftGeneration,
    runBatchDraftGenerationFromIds,
    generateSingleDraft,
    handleMemoryBatchGenerate: handleMemoryBatchGenerate_impl,
    handleMemoryQuickModelChange: handleMemoryQuickModelChange_impl
} = useMemoryAutomation({
    activeChatChar,
    currentMessages,
    activePersona,
    getGenerationState,
    memoryDraftState,
    currentMemoryBookData,
    loadCurrentMemoryBook,
    updatePendingMemoryMessageIds,
    startMemoryDraftProgress,
    stopMemoryDraftProgress,
    setMemoryDraftAbortController,
    openMemoryBooksSheet
});

const {
    getAvatar,
    getAvatarLetter,
    getAvatarColor,
    getDisplayName,
    openAvatar
} = useChatMessageDisplay(activeChatChar, allPersonas);

const onRegexChanged = () => { regexRevision.value++; };
const contextBreakdown = ref(null);
// Import context settings from service
const { fillThreshold: initialFillThreshold, hidePercent: initialHidePercent } = contextService.loadHistoryContextSettings();
const historyFillThreshold = ref(initialFillThreshold);
const historyHidePercent = ref(initialHidePercent);

const {
    contextSegments,
    contextBreakdownItems,
    contextLegendItems,
    visibleHistoryMessages,
    historyUsagePercent,
    historyHidePreview,
    shouldRecommendHide
} = useContextBreakdown({
    contextBreakdown,
    currentMessages,
    historyFillThreshold,
    historyHidePercent
});

let isCalculatingCutoff = false;
let pendingCutoffRecalc = false;
let isOpeningChat = false;
let cutoffRerunTimer = null;
let cutoffDebounceTimer = null;
let contextCutoffCache = null; // { charId, sessionId, messageCount, hash, result }
const pendingGuidance = ref(null); // { text, type }

let ignoreScrollAdjustment = false;
let ignoreScrollAdjustmentTimer = null;



// --- Selection State ---
const {
    selectedMessages,
    isSelectionMode,
    selectionIncludesLast,
    toggleSelection,
    clearSelection,
    deleteSelectedMessages,
    toggleHideSelectedMessages
} = useMessageSelection(currentMessages, {
    getChatData,
    db,
    addDeletedStats,
    reconcileSessionMemoryState,
    debouncedUpdateContextCutoff: () => debouncedUpdateContextCutoff(),
    getActiveChatChar: () => activeChatChar
});


const {
    openMemoryEntryEditor,
    openMemoryPromptPreview,
    createMemoryFromSelection,
    generateMemoryDraftFromSelection,
    openMemoryTextPreview,
    openMessageMemoryCoverage,
    removeMemoryFromSelection,
    openMemoryGenerationSettings,
    openMemoryPromptManager,
    openMemoryPromptEditor,
    openMemoryBooksSheet: openMemoryBooksSheetImpl,
    handleMemorySearchTypeUpdate,
    handleMemoryReindexAll,
    handleMemoryScanChat,
    handleMemoryBatchGenerate,
    handleMemoryGenerateSingleDraft,
    handleMemoryApproveDraft,
    handleMemoryDeleteDraft,
    handleMemoryDeleteAllDrafts,
    handleMemoryDeleteEntry,
    handleMemoryOpenMaintenance,
    handleMemoryCancelDraft,
    handleMemoryPreview,
    handleMemoryOpenSettings,
    handleMemoryQuickModelChange
} = useMemorySheetUI({
    getActiveChatChar: () => activeChatChar,
    currentMessages,
    selectedMessages,
    clearSelection,
    memoryBooksSheet,
    loadCurrentMemoryBook,
    generateMemoryDraftForMessages,
    generateSingleDraft,
    cancelMemoryDraft,
    handleMemorySearchTypeUpdate_composable,
    handleMemoryReindexAll_composable,
    handleMemoryScanChat_composable,
    handleMemoryApproveDraft_composable,
    handleMemoryDeleteDraft_composable,
    handleMemoryDeleteAllDrafts_composable,
    handleMemoryDeleteEntry_composable,
    handleMemoryOpenMaintenance_composable,
    handleMemoryBatchGenerate_impl,
    handleMemoryQuickModelChange_impl,
    debouncedUpdateContextCutoff: () => debouncedUpdateContextCutoff()
});

openMemoryBooksSheet = openMemoryBooksSheetImpl;

const {
    deleteSession,
    openSessionsSheet,
    openDeleteSessionConfirm,
    createNewSession
} = useSessionManagement({
    activeChar,
    getActiveChatChar: () => activeChatChar,
    setActiveChatChar: (v) => { activeChatChar = v; },
    currentMessages,
    inputValue,
    isGenerating,
    hasGenerationState,
    getGenerationState,
    clearGenerationState,
    abortActiveChatGeneration,
    getChatGenerationServices: () => chatGenerationServices,
    loadChats,
    openChat,
    asyncSaveCurrentSessionState,
    getCleanupScroll: () => _cleanupScroll,
    setCleanupScroll: (v) => { _cleanupScroll = v; },
    t
});

// --- Display Logic (Separators) ---
const displayMessages = computed(() => {
    const msgs = currentMessages.value;
    if (!msgs || msgs.length === 0) return [];
    
    const res = [];
    let lastDateKey = null;
    let visibleIndex = 0;
    
    for (let i = 0; i < msgs.length; i++) {
        const msg = msgs[i];
        if (!msg) continue;
        const d = new Date(msg.timestamp);
        const dateKey = d.toDateString();
        
        if (dateKey !== lastDateKey) {
            res.push({ type: 'separator', timestamp: msg.timestamp, id: `sep_${dateKey}` });
            lastDateKey = dateKey;
        }
        
        if (!msg.isHidden) {
            if (visibleIndex === cutoffIndex.value && visibleIndex > 0) {
                res.push({ type: 'cutoff', id: 'context-cutoff' });
            }
            visibleIndex++;
        }
        
        res.push({ type: 'message', data: msg, originalIndex: i, id: `msg_${msg.timestamp}_${i}` });
    }
    
    if (cutoffIndex.value >= visibleIndex && visibleIndex > 0) {
        res.push({ type: 'cutoff', id: 'context-cutoff-end' });
    }
    
    return res;
});

// --- Virtual Scroll Setup ---
const { visibleItems, paddingTop, paddingBottom, refresh: refreshVirtualScroll, scrollToBottom: vsScrollToBottom, isScrolling, isProgrammaticScrolling, getScrollAnchor, scrollToAnchor, scrollToIndex, isItemVisible } = useVirtualScroll(displayMessages, messagesContainer, {
    buffer: isBatterySaverUI.value ? 28 : 75,
    estimateHeight: 100
});

// --- Search Logic ---
const {
    isSearchMode,
    searchQuery,
    searchResults,
    currentSearchIndex,
    searchMatchState,
    scrollToSearchResult,
    nextSearchResult,
    prevSearchResult,
    onChatSearchToggle,
    onChatSearch
} = useChatSearch({ currentMessages, scrollToIndex, displayMessages });

const onScroll = (e) => {
    const el = e.target;
    if (isSearchMode.value) {
        showScrollButton.value = false;
        return;
    }
    const distance = el.scrollHeight - el.scrollTop - el.clientHeight;
    showScrollButton.value = distance > 100;
};

// Expose vsScrollToBottom
window.forceScrollToBottom = () => { vsScrollToBottom('auto') };

watch([isSearchMode, isSelectionMode], () => {
    ignoreScrollAdjustment = true;
    if (ignoreScrollAdjustmentTimer) clearTimeout(ignoreScrollAdjustmentTimer);
    ignoreScrollAdjustmentTimer = setTimeout(() => {
        ignoreScrollAdjustment = false;
    }, 400);
});

// --- Data Management ---

async function loadChats() {
    // Preserve in-memory data for ANY character currently generating
    for (const charId of listGeneratingCharIds()) {
        const memData = await getChatData(charId);
        if (!memData) continue;

        const state = getGenerationState(charId);

        let foundMsg = null;
        let foundSessionId = memData.currentId;

        if (memData.sessions[foundSessionId]) {
            foundMsg = memData.sessions[foundSessionId].find(m => m.id === state.msgId);
        }
        if (!foundMsg) {
            for (const [sid, sess] of Object.entries(memData.sessions)) {
                const m = sess.find(msg => msg.id === state.msgId);
                if (m) {
                    foundMsg = m;
                    foundSessionId = sid;
                    break;
                }
            }
        }

        if (foundMsg) {
            if (!memData.sessions[foundSessionId]) memData.sessions[foundSessionId] = [];
            const dbSession = memData.sessions[foundSessionId];
            const dbIdx = dbSession.findIndex(m => m.id === state.msgId);
            if (dbIdx !== -1) {
                dbSession[dbIdx] = foundMsg;
            } else {
                dbSession.push(foundMsg);
            }
            await db.saveChat(charId, memData);
        }
    }

    if (activeChatChar) {
        const data = await getChatData(activeChatChar.id);
        const sessionId = activeChatChar.sessionId || data.currentId;
        if (data && data.sessions && data.sessions[sessionId]) {
            currentMessages.value = restoreVisibleSwipeState(data.sessions[sessionId]);
        } else {
            currentMessages.value = [];
        }
    }
}

async function updateContextCutoff() {
    if (!activeChatChar || !currentMessages.value) return;

    console.time('[updateContextCutoff] total');

    if (isOpeningChat) {
        pendingCutoffRecalc = true;
        return;
    }

    if (isCalculatingCutoff) {
        pendingCutoffRecalc = true;
        return;
    }

    // Set guard BEFORE any await to prevent concurrent executions from bypassing it
    isCalculatingCutoff = true;

    const currentCharId = activeChatChar.id;
    const visibleMessages = currentMessages.value.filter(m => m && !m.isTyping && !m.isHidden);
    const messageCount = visibleMessages.length;

    try {
        const cutoffChatData = await getChatData(activeChatChar.id);
        const sessionId = cutoffChatData.currentId;

        // Cache key includes context settings so changes to context size bust the cache
        const runtime = getApiRuntimeStorage();
        const contextSize = String(runtime.contextSize || 32000);
        const maxTokens = String(runtime.maxTokens || 8000);
        const cacheKey = `${currentCharId}_${sessionId}_${messageCount}_${contextSize}_${maxTokens}`;

        if (contextCutoffCache && contextCutoffCache.hash === cacheKey) {
            cutoffIndex.value = contextCutoffCache.result?.cutoffIndex ?? 0;
            contextBreakdown.value = contextCutoffCache.result?.contextBreakdown || null;
            return;
        }

        const history = visibleMessages
            .map((m, i) => ({ role: m.role === 'user' ? 'user' : 'assistant', content: m.text || "", originalIndex: i }));

        const summary = cutoffChatData.summaries?.[sessionId];

        let authorsNote = null;
        if (cutoffChatData.authorsNotes && cutoffChatData.authorsNotes[sessionId]) {
            authorsNote = buildGenerationAuthorsNote({
                getEffectivePreset,
                charId: activeChatChar.id,
                sessionId,
                anContent: cutoffChatData.authorsNotes[sessionId]
            });
        }

        const result = await calculateContext({
            char: activeChatChar,
            history,
            authorsNote,
            summary
        });

        if (activeChatChar && activeChatChar.id === currentCharId) {
            cutoffIndex.value = result?.cutoffIndex ?? 0;
            contextBreakdown.value = result?.contextBreakdown || null;
            contextCutoffCache = {
                hash: cacheKey,
                charId: currentCharId,
                sessionId,
                messageCount,
                result
            };
        }
    } finally {
        console.timeEnd('[updateContextCutoff] total');
        isCalculatingCutoff = false;
        if (pendingCutoffRecalc) {
            pendingCutoffRecalc = false;
            if (cutoffRerunTimer) clearTimeout(cutoffRerunTimer);
            cutoffRerunTimer = setTimeout(() => {
                updateContextCutoff();
            }, 0);
        }
    }
}

function debouncedUpdateContextCutoff(delay = 300) {
    const effectiveDelay = isBatterySaverUI.value ? Math.max(delay, 700) : delay;
    if (cutoffDebounceTimer) clearTimeout(cutoffDebounceTimer);
    cutoffDebounceTimer = setTimeout(() => {
        updateContextCutoff();
    }, effectiveDelay);
}

function invalidateContextCache() {
    contextCutoffCache = null;
}

async function updateSessionMessage(char, msgIndex, newMsgData) {
    const data = await getChatData(char.id);
    const sessionId = char.sessionId || data.currentId;
    if (data && data.sessions[sessionId]) {
        data.sessions[sessionId][msgIndex] = newMsgData;
        await db.saveChat(char.id, data);
    }
}

// Use context service functions
const { clampHistoryFillThreshold, clampHistoryHidePercent } = contextService;

function persistHistoryContextSettings(fillThreshold, hidePercent) {
    const clamped = contextService.persistHistoryContextSettings(fillThreshold, hidePercent);
    historyFillThreshold.value = clamped.fillThreshold;
    historyHidePercent.value = clamped.hidePercent;
}

async function saveCurrentMessages() {
    if (!activeChatChar) return;
    const data = await getChatData(activeChatChar.id);
    if (!data) return;
    const sessionId = activeChatChar.sessionId || data.currentId;
    data.sessions[sessionId] = currentMessages.value;
    await db.saveChat(activeChatChar.id, data);
}

function handleSaveContextSettings({ fillThreshold, hidePercent }) {
    persistHistoryContextSettings(fillThreshold, hidePercent);
}

async function hideTopMessagesNow() {
    const count = historyHidePreview.value.count;
    if (!count || !activeChatChar) return;

    let hidden = 0;
    for (const msg of currentMessages.value) {
        if (!msg || msg.isTyping || msg.isHidden) continue;
        msg.isHidden = true;
        hidden += 1;
        if (hidden >= count) break;
    }

    if (!hidden) return;

    await saveCurrentMessages();
    await updateContextCutoff();
    closeBottomSheet();
    showToast(`Hidden ${hidden} top message${hidden === 1 ? '' : 's'}`);
}

function confirmHideTopMessages() {
    const preview = historyHidePreview.value;
    if (!preview.count) return;

    showBottomSheet({
        title: 'Hide Top Messages',
        items: [
            {
                label: 'Open Summary',
                hint: 'Review or generate a summary first',
                icon: '<svg viewBox="0 0 24 24"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-2 14H7v-2h10v2zm0-4H7v-2h10v2zm0-4H7V7h10v2z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    setTimeout(() => presetView.value?.openSummarySheet(), 250);
                }
            },
            {
                label: `Hide ${preview.count} message${preview.count === 1 ? '' : 's'} now`,
                hint: `Free about ${preview.tokens} tokens`,
                icon: '<svg viewBox="0 0 24 24"><path d="M12 7c2.76 0 5 2.24 5 5 0 .65-.13 1.26-.36 1.83l2.92 2.92c1.51-1.26 2.7-2.89 3.43-4.75-1.73-4.39-6-7.5-11-7.5-1.4 0-2.74.25-3.98.7l2.16 2.16C10.74 7.13 11.35 7 12 7zM2 4.27l2.28 2.28.46.46C3.08 8.3 1.78 10.02 1 12c1.73 4.39 6 7.5 11 7.5 1.55 0 3.03-.3 4.38-.84l.42.42L19.73 22 21 20.73 3.27 3 2 4.27z"/></svg>',
                onClick: () => {
                    hideTopMessagesNow();
                }
            },
            {
                label: 'Cancel',
                onClick: () => {
                    closeBottomSheet();
                    // Return to Tokenizer sheet
                    setTimeout(() => {
                        isCalculatingCutoff = false; // ensure loader doesn't stick
                        tokenizerSheet.value?.open();
                    }, 50);
                }
            }
        ]
    });
}

async function unhideAllMessages() {
    if (!activeChatChar) return;

    let changed = 0;
    for (const msg of currentMessages.value) {
        if (!msg || msg.isTyping || !msg.isHidden) continue;
        msg.isHidden = false;
        changed += 1;
    }

    if (!changed) return;

    await saveCurrentMessages();
    await updateContextCutoff();
    closeBottomSheet();
    showToast(`Unhid ${changed} message${changed === 1 ? '' : 's'}`);
}

async function openContextSheet() {
    // Always recalculate to ensure vector lorebooks are included
    if (activeChatChar) {
        const calculatePromise = updateContextCutoff();
        const timeoutPromise = new Promise(resolve => { setTimeout(resolve, 5000) });
        await Promise.race([calculatePromise, timeoutPromise]);

        if (isCalculatingCutoff) {
            await new Promise(resolve => { setTimeout(resolve, 1000) });
        }
    }

    if (!contextBreakdown.value) {
        showBottomSheet({
            title: 'Context',
            bigInfo: {
                icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;"><path d="M11 17h2v-6h-2v6zm0-8h2V7h-2v2zm1-7C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2z"/></svg>',
                description: 'Context calculation is taking longer than expected. Please check that your API settings are configured correctly and try again.',
                buttonText: 'Close',
                onButtonClick: () => closeBottomSheet()
            }
        });
        return;
    }

    tokenizerSheet.value?.open();
}

function handleSheetBack() {
    // Close current sheet and open MagicDrawer
    tokenizerSheet.value?.close();
    memoryBooksSheet.value?.close();
    chatInputRef.value?.openMagicDrawer();
}

async function setupHeader(char = activeChatChar) {
    if (!char) return;
    const data = await getChatData(char.id);
    const initialSessionId = char.sessionId || (data ? data.currentId : '...');
    const sessionName = data?.sessionNames?.[initialSessionId];

    publishAppEvent(APP_EVENTS.ui.header.setupChat, {
            char,
            currentSessionId: initialSessionId,
            sessionName,
            callbacks: {
                onActionsClick: () => openSessionsSheet(char),
                onBackClick: () => {
                    closeChat();
                    if (currentOnBack) currentOnBack();
                }
            }
        }
    );
}

const onFsEditorClosed = async () => {
    if (activeChatChar) {
        // Restore chat header when FS editor is closed
        await setupHeader(activeChatChar);
    }
};

const applyImageAutoHide = () => {
    const autoHide = localStorage.getItem('gz_api_auto_hide_images') === 'true';
    const threshold = parseInt(localStorage.getItem('gz_api_auto_hide_images_n') || '1', 10);
    
    if (!autoHide || threshold <= 0 || !activeChatChar) return;

    let changed = false;
    let assistantCount = 0;
    
    // Iterate backwards to count assistant responses after user images
    for (let i = currentMessages.value.length - 1; i >= 0; i--) {
        const msg = currentMessages.value[i];
        if (msg.role === 'char' || msg.role === 'assistant') {
            assistantCount++;
        } else if (msg.role === 'user' && msg.image) {
            if (assistantCount >= threshold && !msg.imageHidden) {
                msg.imageHidden = true;
                changed = true;
            }
        }
    }

    if (changed) {
        const charId = activeChatChar.id;
        const sessionId = activeChatChar.sessionId;
        const messageSnapshot = currentMessages.value;
        getChatData(activeChatChar.id).then(data => {
            if (data && sessionId && data.sessions?.[sessionId]) {
                data.sessions[sessionId] = messageSnapshot;
                db.saveChat(charId, data);
            }
        });
    }
};

async function openChat(char, onBack, force = false) {
    let targetSessionId = char.sessionId;
    if (targetSessionId === undefined) {
        const memData = await getChatData(char.id);
        targetSessionId = memData ? memData.currentId : undefined;
    }

    // Prevent reloading if the requested chat is already open and active
    if (!force && activeChatChar && String(activeChatChar.id) === String(char.id) && String(activeChatChar.sessionId) === String(targetSessionId) && !isOpeningChat) {
        if (char.msgId) {
            const msgIdx = currentMessages.value.findIndex(m => m.id === char.msgId);
            if (msgIdx !== -1) {
                const displayIndex = displayMessages.value.findIndex(
                    m => m.type === 'message' && m.originalIndex === msgIdx
                );
                if (displayIndex !== -1) {
                    scrollToAnchor({ index: displayIndex, offset: 0 });
                    nextTick(() => {
                        const el = document.getElementById(`msg-${msgIdx}`);
                        if (el) {
                            el.classList.add('search-highlight');
                            setTimeout(() => el.classList.remove('search-highlight'), 2000);
                        }
                    });
                }
            }
            delete char.msgId;
        }
        
        if (onBack && currentOnBack !== onBack) {
            currentOnBack = onBack;
        }

        clearMessageNotifications(char.id);
        return;
    }

    isOpeningChat = true;
    isLoading.value = true;
    cutoffIndex.value = -1;
    contextBreakdown.value = null;

    try {
    // Attempt to migrate legacy stats locally
    await migrateStatsIfNeeded();

    // Hide tabbar immediately to prevent flickering
    const tabbar = document.querySelector('.tabbar');
    if (tabbar) tabbar.style.display = 'none';

    if (onBack) currentOnBack = onBack;
    // Cleanup previous scroll listener if exists to prevent leaks/conflicts
    if (_cleanupScroll) {
        _cleanupScroll();
        _cleanupScroll = null;
    }

    // Setup header immediately to start transition before loader covers screen
    setupHeader(char);

    clearMessageNotifications(char.id);

    await loadChats();

    if (char.sessionId) {
        const data = await getChatData(char.id);
        if (data && data.sessions && data.sessions[char.sessionId]) {
            if (data.currentId !== char.sessionId) {
                data.currentId = char.sessionId;
                await db.saveChat(char.id, data);
            }
        }
    }

    const chatData = await getChatData(char.id);
    const currentSessionId = chatData.currentId;

    activeChatChar = { ...char, sessionId: char.sessionId || currentSessionId };
    setTrackedContext(activeChatChar.id, activeChatChar.sessionId);
    
    // Explicitly strip legacy properties from the base character reference 
    // to prevent leakage from DB payloads saved before the fixes.
    delete activeChatChar.authors_note;
    delete activeChatChar.summary;

    activeChar.value = activeChatChar;
    isGenerating.value = hasGenerationState(char.id);

    // Clear unread
    const unread = (await db.get('gz_unread')) || {};
    if (unread[char.id]) {
        delete unread[char.id];
        await db.set('gz_unread', unread);
    }


    const effectivePreset = getEffectivePreset(char.id, currentSessionId ? `${char.id}_${currentSessionId}` : null);
    const presetSummary = effectivePreset.blocks?.find(b => b.id === 'summary');
    const presetAN = effectivePreset.blocks?.find(b => b.id === 'authors_note');

    // Remove legacy properties when creating new sessions to avoid picking them up
    // However, if they exist from before the fix, we should wipe them during load.
    if (!chatData.authorsNotes?.[currentSessionId]) { 
        delete activeChatChar.authors_note; 
    } 
    if (!chatData.summaries?.[currentSessionId]) { 
        delete activeChatChar.summary; 
    }

    // Inject Session Data for GenerationView binding
    let summaryData = chatData.summaries?.[currentSessionId];
    if (typeof summaryData === 'string') {
        summaryData = { 
            content: summaryData, 
            depth: presetSummary?.depth !== undefined ? presetSummary.depth : 4, 
            role: presetSummary?.role || 'system', 
            insertion_mode: presetSummary?.insertion_mode || 'relative' 
        };
    } else if (!summaryData) {
        summaryData = null;
    }
    
    let anData = chatData.authorsNotes?.[currentSessionId];
    if (typeof anData === 'object' && anData !== null) {
        anData = anData.content || null;
    } else if (typeof anData !== 'string') {
        anData = null;
    }
    
    // Author's Note and Summary settings are now directly in the preset, not in char/chat data.
    // Content is still in char data.
    if (anData !== null) activeChatChar.authors_note = anData;
    else delete activeChatChar.authors_note;
    
    if (summaryData !== null) activeChatChar.summary = summaryData.content;
    else delete activeChatChar.summary;
    
    if (activeChar.value) {
        if (anData !== null) activeChar.value.authors_note = anData;
        else delete activeChar.value.authors_note;
        
        if (summaryData !== null) activeChar.value.summary = summaryData.content;
        else delete activeChar.value.summary;
    }

    // Update header session if it was placeholder
    if (!activeChatChar.sessionId) {
        setupHeader(activeChatChar);
    }

    // Load messages
    let msgs = chatData.sessions[currentSessionId];
    if (!msgs) {
        msgs = [];
        chatData.sessions[currentSessionId] = msgs;
    }

    // Filter out corrupted/null messages
    msgs = msgs.filter(m => m !== null && m !== undefined);
    // Backfill unique IDs for legacy messages
    msgs.forEach(m => {
        if (!m.id) m.id = `legacy_${m.timestamp || Date.now()}_${Math.random().toString(36).slice(2, 6)}`;
        if (!Array.isArray(m.contextRefs)) m.contextRefs = [];
        if (!m.memoryCoverage || typeof m.memoryCoverage !== 'object') m.memoryCoverage = createEmptyMemoryCoverage();
        if (!Array.isArray(m.memoryCoverage.entryIds)) m.memoryCoverage.entryIds = [];
        if (typeof m.memoryCoverage.needsRebuild !== 'boolean') m.memoryCoverage.needsRebuild = false;
        if (typeof m.memoryCoverage.stale !== 'boolean') m.memoryCoverage.stale = false;
    });
    chatData.sessions[currentSessionId] = msgs;

    // Cleanup phantom generations or errors
    let dirty = false;
    while (msgs.length > 0) {
        const lastMsg = msgs[msgs.length - 1];
        const isPhantomTyping = lastMsg.isTyping && !hasGenerationState(char.id);

        if (isPhantomTyping) {
            if (lastMsg.swipes && lastMsg.swipes.length > 1) {
                // Revert to previous swipe if interrupted
                const failedSwipeId = lastMsg.swipeId || (lastMsg.swipes.length - 1);
                lastMsg.swipes.splice(failedSwipeId, 1);
                if (lastMsg.swipesMeta) lastMsg.swipesMeta.splice(failedSwipeId, 1);
                
                let newSwipeId = failedSwipeId - 1;
                if (newSwipeId < 0) newSwipeId = 0;
                
                lastMsg.swipeId = newSwipeId;
                lastMsg.text = lastMsg.swipes[newSwipeId] || "";
                lastMsg.isTyping = false;
                
                if (lastMsg.swipesMeta && lastMsg.swipesMeta[newSwipeId]) {
                    lastMsg.reasoning = lastMsg.swipesMeta[newSwipeId].reasoning;
                    lastMsg.genTime = lastMsg.swipesMeta[newSwipeId].genTime;
                    lastMsg.guidanceText = lastMsg.swipesMeta[newSwipeId].guidanceText || null;
                    lastMsg.guidanceType = lastMsg.swipesMeta[newSwipeId].guidanceType || 'GENERATION';
                } else {
                    lastMsg.reasoning = null;
                    lastMsg.genTime = null;
                    lastMsg.guidanceText = null;
                    lastMsg.guidanceType = 'GENERATION';
                }
                dirty = true;
                break;
            } else {
                msgs.pop();
                dirty = true;
            }
        } else {
            break;
        }
    }
    if (dirty) {
        await db.saveChat(char.id, chatData);
    }

    // Cleanup stuck imggen-loading states (saved during interrupted generation).
    // Convert them back to canonical <img data-iig-instruction='...' src="[IMG:GEN]"> so
    // processMessageImages can pick them up and regenerate on this load.
    {
        const loadingSpanRe = /<span\b[^>]*\bclass="[^"]*\bimggen-loading\b[^"]*"[^>]*data-iig-instruction='([^']*)'[^>]*>(?:<span[^>]*>[^<]*<\/span>)*<\/span>/g;
        let dirtyImggen = false;
        const fixText = (t) => t ? t.replace(loadingSpanRe, (_, enc) => `<img data-iig-instruction='${enc}' src="[IMG:GEN]">`) : t;
        for (const msg of msgs) {
            if (!msg?.text?.includes('imggen-loading')) continue;
            const newText = fixText(msg.text);
            if (newText !== msg.text) {
                msg.text = newText;
                if (msg.swipes) msg.swipes = msg.swipes.map(fixText);
                dirtyImggen = true;
            }
        }
        if (dirtyImggen) {
            chatData.sessions[currentSessionId] = msgs;
            await db.saveChat(char.id, chatData);
        }
    }

    currentMessages.value = msgs;
    
    // First Message Logic
    const persona = activePersona.value;
    const greetings = getAllGreetings(char, persona);
    if (currentMessages.value.length === 0 && greetings.length > 0) {
        const now = new Date();
        const time = now.getHours() + ':' + String(now.getMinutes()).padStart(2, '0');
        const firstMsg = {
            id: genMsgId(),
            role: 'char',
            text: greetings[0],
            time: time,
            genTime: '0s',
            tokens: estimateTokens(greetings[0]),
            greetingIndex: 0,
            swipes: greetings,
            swipeId: 0,
            timestamp: Date.now(),
            ...createBaseMessageMeta()
        };
        currentMessages.value.push(firstMsg);
        if (activeChatChar) {
            const sessionId = activeChatChar.sessionId;
            const data = await getChatData(activeChatChar.id);
            if (data && sessionId && data.sessions?.[sessionId]) {
                data.sessions[sessionId] = currentMessages.value;
                await db.saveChat(activeChatChar.id, data);
            }
        }
        scrollToBottom(false);
    }

    // Restore draft
    inputValue.value = chatData.draft || '';
    pendingCutoffRecalc = true;

    // Reset virtual scroll (defaults to bottom)
    refreshVirtualScroll();

    nextTick(async () => {
        updateAppColors();
        
        if (char.msgId) {
            const msgIdx = currentMessages.value.findIndex(m => m.id === char.msgId);
            if (msgIdx !== -1) {
                const displayIndex = displayMessages.value.findIndex(
                    m => m.type === 'message' && m.originalIndex === msgIdx
                );
                if (displayIndex !== -1) {
                    // Use scrollToAnchor for instant positioning without jitter
                    await scrollToAnchor({ index: displayIndex, offset: 0 });
                    nextTick(() => {
                        const el = document.getElementById(`msg-${msgIdx}`);
                        if (el) {
                            el.classList.add('search-highlight');
                            setTimeout(() => el.classList.remove('search-highlight'), 2000);
                        }
                    });
                }
            }
            delete char.msgId;
        } else if (chatData.lastScrollAnchor) {
            await scrollToAnchor(chatData.lastScrollAnchor);
        } else {
             if (messagesContainer.value) messagesContainer.value.scrollTop = messagesContainer.value.scrollHeight;
        }
        
        // Init scroll listener for header
        if (messagesContainer.value) {
            // Delay slightly to allow scrollToAnchor to apply
            setTimeout(() => {
                const currentScroll = messagesContainer.value ? messagesContainer.value.scrollTop : 0;
                _cleanupScroll = initHeaderScroll(messagesContainer.value, currentScroll);
            }, 50);
            messagesContainer.value.addEventListener('scroll', onScroll);
            onScroll({ target: messagesContainer.value });
            applyImageAutoHide();
        }
        // updateInputPreview(); // Handled by ChatInput component

        // Restore generation state if active
        if (hasGenerationState(char.id)) {
            const state = getGenerationState(char.id);
            let lastReopenScrollAt = 0;
            
            // Clear previous timer if exists (from previous mount)
            if (state.timerId) clearTimeout(state.timerId);

            // Define updater for this component instance
            state.onUIUpdate = (text, reasoning, isTyping, textDelta) => {
                const idx = currentMessages.value.findIndex(m => m.id === state.msgId);
                if (idx !== -1) {
                    const m = currentMessages.value[idx];
                    if (textDelta) {
                        m.text += textDelta;
                    } else {
                        m.text = text;
                    }
                    m.reasoning = reasoning;
                    m.isTyping = isTyping;

                    if (isBatterySaverUI.value) {
                        const now = Date.now();
                        if (now - lastReopenScrollAt >= 180) {
                            lastReopenScrollAt = now;
                            smartScroll();
                        }
                    } else {
                        smartScroll();
                    }
                }
            };

            // Restart timer for this component instance
            state.restartGenerationTimer = () => {
                if (state.timerId) clearTimeout(state.timerId);

                state.timerId = setTimeout(() => {
                    state.timerId = null;

                    const activeState = getGenerationState(char.id);
                    if (!activeState || activeState.genId !== state.genId) return;

                    const idx = currentMessages.value.findIndex(m => m.id === state.msgId);
                    if (idx !== -1) {
                        currentMessages.value[idx].genTime = formatGenerationElapsed(state.startTime);
                    }

                    if (typeof activeState.restartGenerationTimer === 'function') {
                        activeState.restartGenerationTimer();
                    }
                }, getGenerationTimerInterval());
            };
            state.restartGenerationTimer();
        }
    });

    // Lorebook Banner Trigger
    const activeLbs = getActiveLorebooksForContext(char.id, char.id && currentSessionId ? `${char.id}_${currentSessionId}` : null);
    const presetName = effectivePreset ? effectivePreset.name : '';
    const effPersona = getEffectivePersona(char.id, currentSessionId ? `${char.id}_${currentSessionId}` : null);
    const personaName = effPersona ? effPersona.name : '';

    if (activeLbs.length > 0 || presetName || personaName) {
        publishAppEvent(APP_EVENTS.ui.header.showLbBanner, {
                names: activeLbs,
                preset: presetName,
                persona: personaName
            });
    }

    } finally {
        isLoading.value = false;
        isOpeningChat = false;
        if (pendingCutoffRecalc) {
            pendingCutoffRecalc = false;
            updateContextCutoff();
        }
        // Update pending memory indicators
        updatePendingMemoryMessageIds(activeChatChar);
    }
}

function asyncSaveCurrentSessionState() {
    if (activeChatChar && messagesContainer.value) {
        const charContext = activeChatChar;
        const sessionId = charContext.sessionId;
        const inputValueDraft = inputValue.value;
        const currentAnchor = getScrollAnchor();

        db.patchChatData(charContext.id, (data) => {
            data.lastScrollAnchor = currentAnchor;
            data.draft = inputValueDraft;

            if (sessionId && data.sessions && data.sessions[sessionId]) {
                const msgs = data.sessions[sessionId];
                for (let i = msgs.length - 1; i >= 0; i--) {
                    const msg = msgs[i];
                    if (msg.isEditing) {
                        msg.isEditing = false;
                        delete msg.editText;
                    }

                    if (msg.isError) {
                        if (msg.swipes && msg.swipes.length > 1) {
                            const errorSwipeId = msg.swipeId || 0;
                            msg.swipes.splice(errorSwipeId, 1);
                            if (msg.swipesMeta) msg.swipesMeta.splice(errorSwipeId, 1);

                            let newSwipeId = errorSwipeId - 1;
                            if (newSwipeId < 0) newSwipeId = 0;

                            msg.swipeId = newSwipeId;
                            msg.text = msg.swipes[newSwipeId] || "";
                            msg.isError = false;

                            if (msg.swipesMeta && msg.swipesMeta[newSwipeId]) {
                                msg.reasoning = msg.swipesMeta[newSwipeId].reasoning;
                                msg.genTime = msg.swipesMeta[newSwipeId].genTime;
                            } else {
                                msg.reasoning = null;
                                msg.genTime = null;
                            }
                        } else {
                            msgs.splice(i, 1);
                        }
                    }
                }
                data.sessions[sessionId] = msgs;
            }

            if (charContext.authors_note !== undefined) {
                if (!data.authorsNotes) data.authorsNotes = {};
                data.authorsNotes[sessionId] = charContext.authors_note;
            }
            if (charContext.summary !== undefined) {
                if (!data.summaries) data.summaries = {};
                data.summaries[sessionId] = charContext.summary;
            }
        });
    }
}

function closeChat() {
    updateAppColors(true); // Revert colors
    if (activeChatChar && messagesContainer.value) {
        asyncSaveCurrentSessionState();
        messagesContainer.value.removeEventListener('scroll', onScroll);
    }
    
    if (_cleanupScroll) {
        _cleanupScroll();
        _cleanupScroll = null;
    }

    publishAppEvent(APP_EVENTS.ui.header.reset);
    activeChatChar = null;
    activeChar.value = null;
    setTrackedContext(null, null);
    currentMessages.value = [];
    inputValue.value = '';
}

function scrollToBottom(smooth = true) {
    vsScrollToBottom(smooth ? 'smooth' : 'auto');
}

function smartScroll() {
    if (isSearchMode.value) return;
    if (!showScrollButton.value) {
        scrollToBottom(false);
    }
}

chatGenerationServices = createChatGenerationServices({
    activeChatChar: activeChar,
    isGenerating,
    currentMessages,
    displayMessages,
    smartScroll,
    scrollToBottom,
    isItemVisible,
    scrollToIndex,
    genMsgId,
    updateSessionMessage,
    runMemoryAutomationAfterStableTurn
});

const {
    sendMessage,
    startGeneration,
    handleImageRegenerate
} = useChatGeneration({
    getActiveChatChar: () => activeChatChar,
    currentMessages,
    inputValue,
    isGenerating,
    pendingGuidance,
    hasGenerationState,
    getGenerationState,
    abortAnyActiveGeneration,
    getChatGenerationServices: () => chatGenerationServices,
    genMsgId,
    createBaseMessageMeta,
    nextGenerationId,
    createGenerationRequestToken,
    buildGenerationOwnerKey,
    updateSessionMessage,
    scrollToBottom,
    openApiView,
    memoryDraftState,
    t
});


// --- Message Actions ---

const {
    openMessageActions,
    regenerateMessage,
    branchSession,
    enterEditMode,
    saveEdit,
    cancelEdit,
    saveGuidance,
    toggleImageHidden
} = useMessageActions({
    activeChar,
    getActiveChatChar: () => activeChatChar,
    currentMessages,
    isGenerating,
    hasGenerationState,
    getGenerationState,
    clearGenerationState,
    abortActiveChatGeneration,
    startGeneration,
    updateSessionMessage,
    updateContextCutoff,
    unhideAllMessages,
    toggleSelection,
    loadChats,
    openChat,
    t
});

const {
    changeSwipe,
    changeGreeting
} = useSwipeNavigation({
    currentMessages,
    isGenerating,
    getActiveChatChar: () => activeChatChar,
    regenerateMessage: (msgIndex, mode, guidanceText) => regenerateMessage(msgIndex, mode, guidanceText)
});

// --- Magic Menu ---

async function startImpersonation(guidanceText = null) {
    if (guidanceText) {
        pendingGuidance.value = { text: guidanceText, type: 'IMPERSONATION' };
    } else {
        pendingGuidance.value = null;
    }
    if (!activeChatChar) return;

    const controller = new AbortController();

    return executeImpersonationUseCase({
        char: activeChatChar,
        guidanceText,
        controller,
        services: {
            app: chatGenerationServices.app,
            lifecycle: {
                setGenerationState,
                clearGenerationState,
                nextGenerationId,
                buildGenerationHistory: () => currentMessages.value
                    .map((m, i) => ({ ...m, originalIndex: i }))
                    .filter(m => !m.isTyping && !m.isHidden)
                    .map(m => ({ role: m.role === 'user' ? 'user' : 'assistant', content: m.text, chatId: m.originalIndex })),
                cleanText
            },
            state: {
                inputValue,
                isImpersonating,
                isGenerating,
                currentMessages,
                activeChatChar: activeChar,
                showBottomSheet,
                closeBottomSheet,
                openApiView,
                t
            }
        }
    });
}

// --- Utils ---

async function openCharCard() {
    if (!activeChatChar) return;
    charCardSheet.value?.open(activeChatChar);
}

async function openChatStatsSheet(char = activeChatChar) {
    if (!char) return;
    statsSheet.value?.open(char, currentMessages.value);
}

function openApiView() {
    publishAppEvent(APP_EVENTS.nav.openApiSheet);
}

function openPresetView() {
    if (presetView.value) {
        presetView.value.open();
    }
}

async function openLorebookSheet() {
    const chatData = await getChatData(activeChar.value?.id);
    const charId = activeChar.value?.id;
    const sessionId = chatData?.currentId;
    lorebookSheet.value?.open({
        charId: charId,
        chatId: charId && sessionId ? `${charId}_${sessionId}` : null
    });
}

function openLorebookEntry(lbId, entryId) {
    lorebookSheet.value?.openEntry(lbId, entryId);
}

function openRegexSheet() {
    regexSheet.value?.open();
}

const restoreHeader = () => {
    if (activeChatChar) setupHeader(activeChatChar);
};

// Expose methods for App.vue
defineExpose({
    loadChats,
    openChat,
    restoreHeader,
    openLorebookEntry,
    startImpersonation,
    openPersonas: () => { chatInputRef.value?.openPersonas(); },
    initChat: () => {},
    // Desktop right-panel magic handlers
    openPresetView,
    openApiView,
    openLorebookSheet,
    openMemoryBooksSheet,
    openRegexSheet,
    openChatStatsSheet: () => openChatStatsSheet(),
    openCharCard,
    openSessionsSheet: () => openSessionsSheet(activeChatChar),
    openImageGenSheet,
    openGlossarySheet,
    openAuthorsNoteSheet: () => presetView.value?.openAuthorsNoteSheet(),
    openSummarySheet: () => presetView.value?.openSummarySheet(),
    openContextSheet: () => openContextSheet(),
});

const onGenerationEnded = (e) => {
    if (activeChatChar && activeChatChar.id === e.detail.charId) {
        isGenerating.value = false;
        isImpersonating.value = false;
        applyImageAutoHide();
        updateContextCutoff();
    }
};

const onCharacterUpdated = (e) => {
    if (activeChatChar && activeChatChar.id === e.detail.character.id) {
        activeChatChar = e.detail.character;
        activeChar.value = e.detail.character;
        publishAppEvent(APP_EVENTS.ui.header.updateAvatar, activeChatChar);
    }
};

const onVisibilityChange = () => {
    if (document.visibilityState === 'hidden' && activeChatChar) {
        const charId = activeChatChar.id;
        const sessionId = activeChatChar.sessionId;
        const messagesSnapshot = currentMessages.value;
        const draft = inputValue.value;
        const authorsNote = activeChatChar.authors_note;
        const summary = activeChatChar.summary;
        db.patchChatData(charId, (data) => {
            if (sessionId && messagesSnapshot.length > 0) {
                data.sessions[sessionId] = messagesSnapshot;
            }
            data.draft = draft;
            if (authorsNote !== undefined) {
                if (!data.authorsNotes) data.authorsNotes = {};
                data.authorsNotes[sessionId] = authorsNote;
            }
            if (summary !== undefined) {
                if (!data.summaries) data.summaries = {};
                data.summaries[sessionId] = summary;
            }
        });
    } else if (document.visibilityState === 'visible' && activeChatChar) {
        clearMessageNotifications(activeChatChar.id);
    }
};

let _paddingRafContext = null;
const updateContentPadding = () => {
    if (_paddingRafContext) cancelAnimationFrame(_paddingRafContext);
    _paddingRafContext = requestAnimationFrame(() => {
        _paddingRafContext = null;
        if (messagesContainer.value && chatInputContainer.value) {
        const el = messagesContainer.value;
        const currentFullHeight = chatInputContainer.value.getBoundingClientRect().height;
        const currentContainerHeight = el.getBoundingClientRect().height;
        
        const prevContainerHeight = el._lastContainerHeight !== undefined ? el._lastContainerHeight : currentContainerHeight;
        el._lastContainerHeight = currentContainerHeight;
        const containerHeightDiff = currentContainerHeight - prevContainerHeight;
        
        const prevFullHeight = el._lastFullHeight !== undefined ? el._lastFullHeight : currentFullHeight;
        el._lastFullHeight = currentFullHeight;
        const diffScroll = currentFullHeight - prevFullHeight;

        const targetPadding = currentFullHeight;

        const currentPadding = parseFloat(el.style.paddingBottom) || 0;
        const paddingDiff = targetPadding - currentPadding;

        if (Math.abs(diffScroll) < 0.1 && Math.abs(paddingDiff) < 0.1 && Math.abs(containerHeightDiff) < 0.1) return;

        const isAtBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 5;

        el.style.paddingBottom = `${targetPadding}px`;

        if (!isProgrammaticScrolling.value) {
            isProgrammaticScrolling.value = true;
        }
        if (el._scrollUnlockTimer) clearTimeout(el._scrollUnlockTimer);
        el._scrollUnlockTimer = setTimeout(() => {
            isProgrammaticScrolling.value = false;
        }, 100);
        
        const totalScrollAdjustment = diffScroll - containerHeightDiff;

        if (isAtBottom) {
            // If already at the bottom, stay at the bottom
            el.scrollTop = el.scrollHeight - el.clientHeight;
        } else if (!ignoreScrollAdjustment && Math.abs(totalScrollAdjustment) > 0.1) {
            el.scrollTop += totalScrollAdjustment;
        }
        }
    });
};

function setScrollLock(enabled) {
    if (enabled) {
        document.body.classList.add('no-scroll');
    } else {
        document.body.classList.remove('no-scroll');
    }
}

// Throttle visualViewport handler via RAF to prevent layout thrashing on iOS
// during rapid keyboard show/hide cycles (which can crash WKWebView).
let _vpRafId = null;
function handleVisualViewport() {
    if (Capacitor.getPlatform() !== 'ios') return;
    if (_vpRafId) return;
    _vpRafId = requestAnimationFrame(() => {
        _vpRafId = null;
        if (!window.visualViewport || !chatViewRoot.value) return;
        chatViewRoot.value.style.height = `${window.visualViewport.height}px`;
        window.scrollTo(0, 0);
    });
}

onMounted(() => {
    setScrollLock(true);
    loadChats();
    initRipple();
    if (activeChatChar) {
        setupHeader(activeChatChar);
    }
    unsubCharacterUpdated = subscribeAppEvent(APP_EVENTS.domain.character.updated, ({ detail }) => onCharacterUpdated({ detail }));
    unsubGenerationEnded = subscribeAppEvent(APP_EVENTS.domain.generation.ended, ({ detail }) => onGenerationEnded({ detail }));
    unsubFsEditorClosed = subscribeAppEvent(APP_EVENTS.ui.fsEditorClosed, onFsEditorClosed);
    if (window.visualViewport) {
        window.visualViewport.addEventListener('resize', handleVisualViewport);
        window.visualViewport.addEventListener('scroll', handleVisualViewport);
        handleVisualViewport();
    }

    // Clear notifications when app comes to foreground and chat is active
    document.addEventListener('visibilitychange', onVisibilityChange);

    if (Capacitor.isNativePlatform()) {
        App.addListener('appStateChange', ({ isActive }) => {
            if (!isActive && activeChatChar) {
                const charId = activeChatChar.id;
                const sessionId = activeChatChar.sessionId;
                const messagesSnapshot = currentMessages.value;
                const draft = inputValue.value;
                db.patchChatData(charId, (data) => {
                    if (sessionId && messagesSnapshot.length > 0) {
                        data.sessions[sessionId] = messagesSnapshot;
                    }
                    data.draft = draft;
                });
            }
        });
    }

    if (chatInputContainer.value) {
        inputResizeObserver = new ResizeObserver(updateContentPadding);
        inputResizeObserver.observe(chatInputContainer.value);
        if (messagesContainer.value) inputResizeObserver.observe(messagesContainer.value);
        updateContentPadding();
    }
    updateContextCutoff();
    unsubChatSearchToggle = subscribeAppEvent(APP_EVENTS.ui.chatSearchToggle, ({ detail }) => onChatSearchToggle({ detail }));
    unsubRegexChanged = subscribeAppEvent(APP_EVENTS.domain.lorebook.regexScriptsChanged, onRegexChanged);
    unsubChatSearch = subscribeAppEvent(APP_EVENTS.ui.chatSearch, ({ detail }) => onChatSearch({ detail }));
    unsubApiContextChanged = subscribeAppEvent(APP_EVENTS.domain.settings.apiContextChanged, updateContextCutoff);
    unsubSettingsChanged = subscribeAppEvent(APP_EVENTS.domain.settings.changed, restartVisibleGenerationTimers);
});

watch(() => currentMessages.value.length, () => {
    updateContextCutoff();
});

watch(activeChar, async (newVal) => {
    if (!newVal) return;
    
    const chatData = await getChatData(newVal.id);
    if (!chatData) return;
    const sessionId = chatData.currentId;
    let changed = false;

    // Sync Summary Content
    if (newVal.summary !== undefined) {
        if (!chatData.summaries) chatData.summaries = {};
        let currentSum = chatData.summaries[sessionId];
        if (typeof currentSum === 'string') {
            currentSum = { content: currentSum, depth: 4, role: 'system', insertion_mode: 'relative', prefix: 'Summary: ' };
        } else if (!currentSum) {
            currentSum = { content: '', depth: 4, role: 'system', insertion_mode: 'relative', prefix: 'Summary: ' };
        }
        if (currentSum.content !== newVal.summary) {
            chatData.summaries[sessionId] = { ...currentSum, content: newVal.summary };
            changed = true;
        }
    }

    // Sync Author's Note Content
    if (newVal.authors_note !== undefined) {
        if (!chatData.authorsNotes) chatData.authorsNotes = {};
        const storedAn = chatData.authorsNotes[sessionId];
        const currentAN = typeof storedAn === 'string' ? storedAn : storedAn?.content || '';
        if (currentAN !== newVal.authors_note) {
            chatData.authorsNotes[sessionId] = newVal.authors_note;
            changed = true;
        }
    }

    if (changed) await db.saveChat(newVal.id, chatData);
}, { deep: true });

onBeforeUnmount(() => {
    if (activeChatChar && messagesContainer.value) {
        const charId = activeChatChar.id;
        const sessionId = activeChatChar.sessionId;
        const currentAnchor = getScrollAnchor();
        const draft = inputValue.value;
        const messagesSnapshot = currentMessages.value;
        const authorsNote = activeChatChar.authors_note;
        const summary = activeChatChar.summary;
        db.patchChatData(charId, (data) => {
            data.lastScrollAnchor = currentAnchor;
            data.draft = draft;
            if (sessionId && messagesSnapshot.length > 0) {
                data.sessions[sessionId] = messagesSnapshot;
            }
            if (authorsNote !== undefined) {
                if (!data.authorsNotes) data.authorsNotes = {};
                data.authorsNotes[sessionId] = authorsNote;
            }
            if (summary !== undefined) {
                if (!data.summaries) data.summaries = {};
                data.summaries[sessionId] = summary;
            }
        });
    }
});

onUnmounted(() => {
    setScrollLock(false);
    stopMemoryDraftProgress();
    // Cleanup UI timers AND abort active generations for ALL generating states
    // This prevents leaked intervals, closures referencing unmounted reactive state, and stuck isTyping flags
    for (const charId of listGeneratingCharIds()) {
        const state = getGenerationState(charId);
        // Abort controller to stop ongoing API requests
        if (state.controller) {
            try {
                state.controller.abort();
            } catch (e) {
                console.warn('[onUnmounted] Failed to abort controller:', e);
            }
        }
        // Clear UI timer
        if (state.timerId) {
            clearTimeout(state.timerId);
            state.timerId = null;
        }
        if (typeof state.clearStreamFlushTimer === 'function') {
            state.clearStreamFlushTimer();
        }
        if (typeof state.streamFlush === 'function') {
            state.streamFlush();
        }
        // Disconnect UI updater to prevent updates to unmounted component
        state.onUIUpdate = null;
        // Clean localStorage flag
        const sessionId = activeChatChar?.sessionId;
        if (sessionId) {
            clearPersistedGeneration(charId, sessionId);
        }
        // Clear registry entry to prevent stale state from blocking future generations
        clearGenerationState(charId);
    }
    if (unsubCharacterUpdated) { unsubCharacterUpdated(); unsubCharacterUpdated = null; }
    document.removeEventListener('visibilitychange', onVisibilityChange);
    if (unsubGenerationEnded) { unsubGenerationEnded(); unsubGenerationEnded = null; }
    if (unsubFsEditorClosed) { unsubFsEditorClosed(); unsubFsEditorClosed = null; }
    
    if (window.visualViewport) {
        window.visualViewport.removeEventListener('resize', handleVisualViewport);
        window.visualViewport.removeEventListener('scroll', handleVisualViewport);
    }
    if (_vpRafId) {
        cancelAnimationFrame(_vpRafId);
        _vpRafId = null;
    }

    // Cleanup scroll listener (may not have been cleaned up by closeChat)
    if (_cleanupScroll) {
        _cleanupScroll();
        _cleanupScroll = null;
    }

    // Remove scroll listener that was added in openChat()
    if (messagesContainer.value) {
        messagesContainer.value.removeEventListener('scroll', onScroll);
    }

    if (inputResizeObserver) {
        inputResizeObserver.disconnect();
        inputResizeObserver = null;
    }
    if (unsubChatSearchToggle) { unsubChatSearchToggle(); unsubChatSearchToggle = null; }
    if (unsubRegexChanged) { unsubRegexChanged(); unsubRegexChanged = null; }
    if (unsubChatSearch) { unsubChatSearch(); unsubChatSearch = null; }
    if (unsubApiContextChanged) { unsubApiContextChanged(); unsubApiContextChanged = null; }
    if (unsubSettingsChanged) { unsubSettingsChanged(); unsubSettingsChanged = null; }
    if (cutoffRerunTimer) {
        clearTimeout(cutoffRerunTimer);
        cutoffRerunTimer = null;
    }

    // Reset chatViewRoot height to prevent stale inline style leaking to next mount
    if (chatViewRoot.value) {
        chatViewRoot.value.style.height = '';
    }
});

</script>

<template>
    <div id="view-chat" ref="chatViewRoot" :class="{ 'android-resize-fix': isAndroid }" :style="chatRootStyle">
        <div v-if="isLoading" class="chat-loading-overlay">
            <div class="app-loader-spinner"></div>
        </div>

        <div class="sidebar-drag-handle" v-if="!isAndroid" :style="{ left: 'calc(' + chatPaddingLR + 'px - 4px)' }" @mousedown="startLeftPaddingResize" style="position: absolute; z-index: 10;"></div>
        <div class="sidebar-drag-handle" v-if="!isAndroid" :style="{ right: 'calc(' + chatPaddingLR + 'px - 4px)' }" @mousedown="startRightPaddingResize" style="position: absolute; z-index: 10;"></div>

        <div class="chat-container" id="chat-messages" ref="messagesContainer" :class="{ 'is-scrolling': isScrolling, 'visually-hidden': isLoading }" :style="isAndroid ? { marginBottom: keyboardOverlap + 'px' } : {}">
            <!-- paddingTop - spacer for virtual list scroll offset -->
            <div :style="{ height: paddingTop + 'px' }"></div>
            
            <template v-for="vItem in visibleItems" :key="vItem.key">
                <div v-if="vItem.item.type === 'separator'" class="chat-date-separator" :data-index="vItem.index">
                    {{ formatDateSeparator(vItem.item.timestamp) }}
                </div>
                <div v-else-if="vItem.item.type === 'cutoff'" class="chat-context-limit">
                    <span>Context Limit</span>
                </div>
                <ChatMessage 
                    v-else
                    :id="`msg-${vItem.item.originalIndex}`"
                    :data-index="vItem.index"
                    :message="vItem.item.data"
                    :index="vItem.item.originalIndex"
                    :active-chat-char="activeChatChar"
                    :is-generating="isGenerating"
                    :is-last="vItem.item.originalIndex === currentMessages.length - 1"
                    :search-query="isSearchMode ? searchQuery : ''"
                    :regex-revision="regexRevision"
                    :active-search-match-index="searchMatchState.msgIdx === vItem.item.originalIndex ? searchMatchState.occurrenceIdx : -1"
                    :is-selection-mode="isSelectionMode"
                    :is-selected="selectedMessages.has(vItem.item.data.id)"
                    :is-pending-memory="pendingMemoryMessageIds.has(vItem.item.data.id)"
                    :is-draft-memory="draftMemoryMessageIds.has(vItem.item.data.id)"
                    @swipe="(dir) => changeSwipe(vItem.item.originalIndex, dir, true)"
                    @change-greeting="(dir) => changeGreeting(vItem.item.originalIndex, dir, true)"
                    @regenerate="(mode, guidanceText) => regenerateMessage(vItem.item.originalIndex, mode, guidanceText)"
                    @edit="() => enterEditMode(vItem.item.data)"
                    @save-edit="saveEdit(vItem.item.data, vItem.item.originalIndex)"
                    @cancel-edit="cancelEdit(vItem.item.data)"
                    @update:edit-text="(val) => { vItem.item.data.editText = val }"
                    @save-guidance="(text) => saveGuidance(vItem.item.data, vItem.item.originalIndex, text)"
                    @open-actions="openMessageActions(vItem.item.data, vItem.item.originalIndex)"
                    @open-avatar="openAvatar(vItem.item.data)"
                    @open-memory-coverage="openMessageMemoryCoverage"
                    @toggle-selection="toggleSelection(vItem.item.data.id)"
                    @toggle-image-hidden="toggleImageHidden(vItem.item.data, vItem.item.originalIndex)"
                    @regenerate-image="(payload) => handleImageRegenerate(vItem.item.originalIndex, payload)"
                />
            </template>
            <!-- paddingBottom - spacer for virtual list scroll offset -->
            <div :style="{ height: paddingBottom + 'px' }"></div>
        </div>

        <div class="chat-status-gradient"></div>

        <div class="chat-input-wrapper" ref="chatInputContainer" :style="isAndroid ? { bottom: keyboardOverlap + 'px' } : {}">
            <ChatInput 
                ref="chatInputRef"
                v-model="inputValue"
                :is-generating="isGenerating"
                :is-impersonating="isImpersonating"
                :show-scroll-button="showScrollButton"
                :is-search-mode="isSearchMode"
                :is-selection-mode="isSelectionMode"
                :selected-count="selectedMessages.size"
                :can-delete-selected="selectionIncludesLast"
                :search-match-current="currentSearchIndex + 1"
                :search-match-total="searchResults.length"
                :active-char="activeChar"
                @send="sendMessage"
                @scroll-to-bottom="scrollToBottom"
                @search-next="nextSearchResult"
                @search-prev="prevSearchResult"
                @magic-impersonate="startImpersonation"
                @magic-notes="presetView.openAuthorsNoteSheet()"
                @magic-context="openContextSheet()"
                @magic-stats="openChatStatsSheet()"
                @magic-summary="presetView.openSummarySheet()"
                @magic-sessions="openSessionsSheet(activeChatChar)"
                @magic-char-card="openCharCard"
                @magic-api="openApiView"
                @magic-presets="openPresetView"
                @magic-lorebooks="openLorebookSheet"
                @magic-memory-books="openMemoryBooksSheet"
                @magic-regex="openRegexSheet"
                @magic-image-gen="openImageGenSheet"
                @magic-glossary="openGlossarySheet"
                @delete-selected="deleteSelectedMessages"
                @hide-selected="toggleHideSelectedMessages"
                @generate-memory-draft-selected="generateMemoryDraftFromSelection"
                @create-memory-selected="createMemoryFromSelection"
                @remove-memory-selected="removeMemoryFromSelection"
                @cancel-selection="clearSelection"
            />
            

        </div>

        <div style="display: none;"></div>
        <PresetView ref="presetView" :active-chat-char="activeChar" :chat-history="currentMessages" :is-generating="isGenerating" @update:active-chat-char="val => { if (activeChar) Object.assign(activeChar, val) }" />
        <CharacterCardSheet ref="charCardSheet" />
        <LorebookSheet ref="lorebookSheet" />
        <RegexSheet ref="regexSheet" :active-chat-char="activeChar" />
        <StatsSheet ref="statsSheet" />
        <TokenizerSheet
            ref="tokenizerSheet"
            :breakdown="contextBreakdown"
            :context-segments="contextSegments"
            :context-breakdown-items="contextBreakdownItems"
            :context-legend-items="contextLegendItems"
            :history-usage-percent="historyUsagePercent"
            :history-hide-preview="historyHidePreview"
            :should-recommend-hide="shouldRecommendHide"
            :history-fill-threshold="historyFillThreshold"
            :history-hide-percent="historyHidePercent"
            :is-calculating="isCalculatingCutoff"
            @hide-messages="confirmHideTopMessages"
            @save-settings="handleSaveContextSettings"
            @back="handleSheetBack"
        />
        <ImageGenSheet ref="imageGenSheet" />
        <GlossarySheet ref="glossarySheet" />
        <MemoryBooksSheet
            v-if="currentMemoryBookData"
            ref="memoryBooksSheet"
            :memory-book="currentMemoryBookData"
            :current-messages="currentMessages"
            :character-name="activeChatChar?.name || 'Character'"
            :session-id="String(activeChatChar?.sessionId || '')"
            :memory-draft-state="memoryDraftState"
            :pending-memory-message-ids="pendingMemoryMessageIds"
            @close="() => {}"
            @open-settings="handleMemoryOpenSettings"
            @open-maintenance="handleMemoryOpenMaintenance"
            @open-preview="handleMemoryPreview"
            @update-search-type="handleMemorySearchTypeUpdate"
            @reindex-all="handleMemoryReindexAll"
            @scan-chat="handleMemoryScanChat"
            @batch-generate="handleMemoryBatchGenerate"
            @generate-draft="handleMemoryGenerateSingleDraft"
            @delete-all-drafts="handleMemoryDeleteAllDrafts"
            @approve-draft="handleMemoryApproveDraft"
            @delete-draft="handleMemoryDeleteDraft"
            @delete-entry="handleMemoryDeleteEntry"
            @cancel-draft="handleMemoryCancelDraft"
            @change-model="handleMemoryQuickModelChange"
            @back="handleSheetBack"
        />
    </div>
</template>

<style>
@import url('https://fonts.googleapis.com/css2?family=Orbitron:wght@400;700&family=Rajdhani:wght@300;500;700&display=swap');
/* Chat View */
#view-chat {
    position: fixed;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    display: flex;
    flex-direction: column;
    flex: none;
    height: 100%;
    min-height: 0;
    width: 100%;
    overflow: hidden; /* Disable view scroll, delegate to chat-container */
    padding: 0 !important;
    background-color: var(--ui-bg);
    z-index: 1000;
}

@keyframes msgFadeIn {
    from { opacity: 0; transform: translateY(10px); }
    to { opacity: 1; transform: translateY(0); }
}

.message-section {
    animation: msgFadeIn 0.3s ease-out;
}

.chat-container {
    padding: calc(60px + var(--sat)) 0 0 0; /* Space for fixed header */
    margin-top: 0;
    flex: 1;
    overflow-y: auto;
    overflow-x: hidden;
    min-height: 0;
    /* Enable scroll anchoring to prevent jumps when top padding changes */
    overflow-anchor: auto; 
    
    /* Hide scrollbar */
    scrollbar-width: none; /* Firefox */
    -ms-overflow-style: none;  /* IE 10+ */
}

.chat-container::-webkit-scrollbar {
    display: none; /* Chrome, Safari and Opera */
}

/* Performance optimization: disable pointer events on items while scrolling */
.chat-container.is-scrolling .message-section {
    pointer-events: none;
}

.message-section {
    padding: 12px 16px;
    display: flex;
    flex-direction: column;
    transition: background-color 0.5s ease, color 0.5s ease;
    touch-action: pan-y;
    overflow: hidden;
}


.msg-name {
    font-weight: 500;
    font-size: 14px;
    color: var(--text-dark-gray);
}

.msg-time {
    margin-left: auto;
    font-size: 12px;
    color: var(--text-gray);
}

/* Typing Indicator (VK Style Pencil) */
@keyframes pencil-write {
    0% { transform: translateX(0); }
    15% { transform: translateX(1px); }
    30% { transform: translateX(2px); }
    45% { transform: translateX(3px); }
    60% { transform: translateX(4px); }
    75% { transform: translateX(5px); }
    100% { transform: translateX(0); }
}

.typing-container {
    display: flex;
    align-items: center;
    padding: 2px 0;
    color: var(--text-gray, #818c99);
    font-size: 0.9em;
}

.typing-icon {
    width: 16px;
    height: 16px;
    fill: var(--text-gray);
    margin-right: 10px;
    animation: pencil-write 1.5s infinite ease-in-out;
}


/* Chat Input Bar */
.chat-input-wrapper {
    position: absolute !important;
    bottom: 0;
    left: 0;
    width: 100%;
    z-index: 1000;
    display: flex;
    flex-direction: column;
    overflow: visible !important;
    flex-shrink: 0;
}

.context-sheet {
    padding: 0 16px 16px;
}

.context-sheet-note {
    font-size: 13px;
    color: var(--text-gray);
    line-height: 1.45;
}

.context-sheet-actions {
    display: flex;
    gap: 10px;
    margin-top: 16px;
}

.clickable-selector {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    background: var(--bg-item);
    border: 1px solid var(--border-color);
    padding: 0 16px;
    min-height: 44px;
    border-radius: 12px;
    cursor: pointer;
    font-size: 14px;
    transition: background 0.2s;
    margin-top: 4px;
}

.clickable-selector:active {
    background: var(--bg-item-active);
}

.clickable-selector span {
    min-width: 0;
    flex: 1;
}

.clickable-selector svg {
    width: 20px;
    height: 20px;
    flex-shrink: 0;
    fill: var(--text-gray);
    opacity: 0.5;
}

.context-sheet-btn {
    flex: 1;
    min-height: 42px;
    border: none;
    border-radius: 12px;
    padding: 0 14px;
    font-size: 14px;
    font-weight: 600;
}

.context-sheet-btn-primary {
    color: #fff;
    background: var(--vk-blue);
}

.context-sheet-btn-secondary {
    color: var(--text-black);
    background: rgba(255, 255, 255, 0.08);
}

.context-sheet-btn-destructive {
    color: #fff;
    background: #ff4444;
}

.memory-batch-actions {
    margin-bottom: 12px;
    padding: 12px 14px;
    border-radius: 14px;
    background: rgba(199, 156, 255, 0.08);
    border: 1px solid rgba(199, 156, 255, 0.25);
}

.memory-batch-info {
    color: var(--text-black);
    font-size: 13px;
    margin-bottom: 10px;
}

.memory-batch-info strong {
    color: #c79cff;
}

.memory-generation-status-card {
    margin-bottom: 12px;
    padding: 12px 14px;
    border-radius: 14px;
    background: rgba(30, 200, 255, 0.12);
    border: 1px solid rgba(30, 200, 255, 0.28);
}

.memory-generation-status-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    margin-bottom: 4px;
}

.memory-generation-status-row strong {
    color: var(--text-black);
    font-size: 14px;
}

.memory-generation-status-row span {
    color: var(--vk-blue);
    font-weight: 700;
    font-variant-numeric: tabular-nums;
}

.memory-session-overview {
    margin-bottom: 12px;
    padding: 14px;
    border-radius: 16px;
    background: linear-gradient(180deg, rgba(122, 108, 255, 0.14), rgba(30, 200, 255, 0.08));
    border: 1px solid rgba(122, 108, 255, 0.22);
}

.memory-session-overview-head {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 12px;
    margin-bottom: 8px;
}

.memory-session-title {
    color: var(--text-black);
    font-size: 16px;
    font-weight: 800;
}

.memory-session-chip {
    padding: 6px 10px;
    border-radius: 999px;
    background: rgba(255, 255, 255, 0.5);
    color: var(--text-black);
    font-size: 12px;
    font-weight: 700;
    white-space: nowrap;
}

.memory-session-overview-meta {
    color: var(--text-gray);
    font-size: 12px;
    line-height: 1.5;
}

.memory-sheet-section {
    margin-top: 12px;
}

.memory-sheet-section-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    margin-bottom: 8px;
}

.memory-sheet-section-head label {
    color: var(--text-black);
    font-weight: 800;
    font-size: 13px;
    text-transform: uppercase;
    letter-spacing: 0.04em;
}

.memory-sheet-section-head span {
    min-width: 28px;
    padding: 4px 8px;
    border-radius: 999px;
    background: rgba(255, 255, 255, 0.08);
    color: var(--text-gray);
    text-align: center;
    font-size: 12px;
    font-weight: 700;
}

.memory-status-summary {
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 10px;
    margin-bottom: 12px;
}

.memory-status-summary-item {
    padding: 10px 12px;
    border-radius: 12px;
    background: rgba(255, 255, 255, 0.08);
    border: 1px solid rgba(255, 255, 255, 0.08);
    text-align: center;
}

.memory-status-summary-item strong {
    display: block;
    color: var(--text-black);
    font-size: 18px;
    line-height: 1.1;
}

.memory-status-summary-item span {
    display: block;
    margin-top: 4px;
    color: var(--text-gray);
    font-size: 12px;
}

.memory-status-summary-item.warning {
    background: rgba(255, 184, 77, 0.12);
    border-color: rgba(255, 184, 77, 0.3);
}

.memory-status-summary-item.danger {
    background: rgba(255, 107, 107, 0.12);
    border-color: rgba(255, 107, 107, 0.3);
}

.memory-status-summary-item.ok {
    background: rgba(126, 231, 135, 0.12);
    border-color: rgba(126, 231, 135, 0.3);
}

.memory-status-summary-item.draft {
    background: rgba(122, 108, 255, 0.12);
    border-color: rgba(122, 108, 255, 0.3);
}

.memory-entry-card.is-warning {
    border-color: rgba(255, 184, 77, 0.35);
    box-shadow: inset 0 0 0 1px rgba(255, 184, 77, 0.14);
}

.memory-status-badge.ok {
    background: rgba(126, 231, 135, 0.16);
    color: #2d8a39;
}

.memory-status-badge.warning {
    background: rgba(255, 184, 77, 0.18);
    color: #a85e00;
}

.memory-status-badge.draft {
    background: rgba(122, 108, 255, 0.16);
    color: #5b4bd0;
}

@media (max-width: 480px) {
    .memory-status-summary {
        grid-template-columns: 1fr 1fr;
    }

    .memory-session-overview-head {
        flex-direction: column;
        align-items: flex-start;
    }
}


/* History List */
.history-item {
    padding: 12px;
    border-bottom: 1px solid var(--border-color);
    display: flex;
    justify-content: space-between;
    align-items: center;
}

.chat-date-separator {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 16px 0;
    color: var(--text-gray);
    font-size: 11px;
    font-weight: 500;
    text-transform: uppercase;
    letter-spacing: 1px;
    width: 100%;
}

.chat-date-separator::before, .chat-date-separator::after {
    content: '';
    flex: 1;
    height: 1px;
    background: var(--border-color);
    margin: 0 12px;
    opacity: 0.5;
}

.chat-context-limit {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 16px 0;
    color: var(--text-gray);
    font-size: 11px;
    font-weight: 500;
    text-transform: uppercase;
    letter-spacing: 1px;
    opacity: 1;
}
.chat-context-limit::before, .chat-context-limit::after {
    content: '';
    flex: 1;
    height: 1px;
    background: var(--border-color);
    margin: 0 12px;
    opacity: 1;
}

.impersonate-status {
    display: flex;
    align-items: center;
    margin-left: auto;
    margin-right: 8px;
    pointer-events: none;
    background-color: transparent;
}

/* Typing Dots for Dialog List */
.typing-dots {
    display: inline-flex;
    align-items: center;
    height: 12px;
}
.typing-dot {
    width: 4px;
    height: 4px;
    background-color: var(--vk-blue);
    border-radius: 50%;
    margin: 0 1px;
    animation: typingDot 1.4s infinite ease-in-out both;
}
.typing-dot:nth-child(1) { animation-delay: -0.32s; }
.typing-dot:nth-child(2) { animation-delay: -0.16s; }
@keyframes typingDot {
    0%, 80%, 100% { transform: scale(0); }
    40% { transform: scale(1); }
}

/* Typing Dots for Chat Message & Impersonation */
.typing-dots-bounce {
    display: inline-block;
    margin-left: 4px;
}

.typing-dots-bounce span {
    display: inline-block;
    animation: dotBounce 1.4s infinite ease-in-out both;
    color: var(--text-gray);
    font-size: 1.4em;
    line-height: 10px;
    vertical-align: middle;
}

.typing-dots-bounce span:nth-child(1) { animation-delay: -0.32s; }
.typing-dots-bounce span:nth-child(2) { animation-delay: -0.16s; }

@keyframes dotBounce {
    0%, 80%, 100% { transform: translateY(0); opacity: 0.5; }
    40% { transform: translateY(-5px); opacity: 1; }
}

/* Unread Message State */
.list-item.unread .item-subtitle,
.list-item.unread .item-meta {
    color: var(--vk-blue);
    font-weight: 500;
}


/* Deletion Animation */
@keyframes msgDelete {
    0% {
        opacity: 1;
        transform: translateY(0);
        max-height: 500px; /* Large enough to cover most messages */
        margin-bottom: 0;
        padding-top: 12px;
        padding-bottom: 12px;
    }
    100% {
        opacity: 0;
        transform: translateY(20px);
        max-height: 0;
        margin-bottom: 0;
        padding-top: 0;
        padding-bottom: 0;
        border-bottom-width: 0;
    }
}

.message-section.deleting {
    animation: msgDelete 0.3s ease-out forwards;
    overflow: hidden;
    border-bottom: none;
    pointer-events: none;
}


.msg-switcher {
    background-color: rgba(30, 30, 30, var(--element-opacity, 0.6));
    color: var(--text-gray);
}

/* Code Blocks */
.code-block {
    background-color: rgba(255, 255, 255, 0.1);
    border-radius: 6px;
    padding: 10px;
    margin: 8px 0;
    overflow-x: auto;
    font-family: Consolas, Monaco, 'Courier New', monospace;
    font-size: 13px;
    white-space: pre;
    color: var(--text-black);
}

.edit-btn.save svg {
    fill: #4CAF50;
}

.edit-btn.cancel svg {
    fill: #ff4444;
}

.edit-btn:hover {
    background-color: rgba(255,255,255,0.1);
}

/* --- Custom Interface Styles (FC) --- */
.fc-interface {
  width: 100%;
  max-width: 340px;
  margin: 20px auto;
  background: #050a05;
  border: 1px solid #33ff33;
  font-family: 'Rajdhani', sans-serif;
  color: #ccffcc;
  overflow: hidden;
  position: relative;
  box-shadow: 0 0 15px rgba(51, 255, 51, 0.2);
  border-radius: 8px;
}

.fc-header {
  background: linear-gradient(90deg, #0a1f0a, #003300);
  padding: 10px;
  border-bottom: 1px solid #33ff33;
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.fc-logo {
  font-family: 'Orbitron', sans-serif;
  font-weight: 700;
  color: #33ff33;
  text-shadow: 0 0 5px #33ff33;
  font-size: 14px;
}

.fc-status {
  font-size: 10px;
  color: #33ff33;
  animation: blink 2s infinite;
}

.fc-content {
  padding: 15px;
  position: relative;
  min-height: 280px;
}

/* Character Scan Layer */
.scan-container {
  position: relative;
  height: 180px;
  background: url('https://image.pollinations.ai/prompt/silhouette%20of%20a%20man%20standing%20in%20a%20casino%20green%20hologram%20style%20wireframe?nologo=true') center/cover no-repeat;
  border: 1px solid #1a4d1a;
  margin-bottom: 15px;
  overflow: hidden;
}

.scan-line {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  height: 2px;
  background: #33ff33;
  box-shadow: 0 0 10px #33ff33;
  animation: scan 3s linear infinite;
}

.scan-overlay {
  position: absolute;
  bottom: 0;
  left: 0;
  width: 100%;
  background: rgba(0, 20, 0, 0.8);
  padding: 5px;
  font-size: 12px;
  transform: translateY(100%);
  transition: transform 0.3s ease;
}

.scan-container:hover .scan-overlay {
  transform: translateY(0);
}

/* Interactive Tabs */
.fc-tabs {
  display: flex;
  gap: 5px;
  margin-bottom: 10px;
}

.fc-tab {
  flex: 1;
  background: #0f2b0f;
  border: 1px solid #1a4d1a;
  color: #88cc88;
  padding: 8px;
  text-align: center;
  cursor: pointer;
  font-size: 12px;
  transition: all 0.3s ease;
  text-transform: uppercase;
}

.fc-tab:hover, .fc-tab.active {
  background: #33ff33;
  color: #000;
  box-shadow: 0 0 10px rgba(51, 255, 51, 0.4);
}

/* Data Display Area */
.data-panel {
  display: none;
  animation: fadeInUp 0.4s ease;
}

.data-panel.active {
  display: block;
}

.stat-row {
  display: flex;
  justify-content: space-between;
  margin-bottom: 8px;
  font-size: 13px;
  border-bottom: 1px dashed #1a4d1a;
  padding-bottom: 4px;
}

.stat-val {
  color: #33ff33;
  font-weight: 700;
}

/* Animations */
@keyframes scan {
  0% { top: 0; opacity: 0; }
  10% { opacity: 1; }
  90% { opacity: 1; }
  100% { top: 100%; opacity: 0; }
}

@keyframes blink {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.5; }
}

@keyframes fadeInUp {
  from { opacity: 0; transform: translateY(5px); }
  to { opacity: 1; transform: translateY(0); }
}

/* Header Hiding Fix */
.app-header, header.app-header {
    transform: translateY(0) translateZ(0);
}
.app-header.fixed-header {
    position: fixed;
    left: 0;
    right: 0;
    margin-top: calc(var(--sat) + 10px) !important;
    width: auto;
    z-index: 1000;
}
.app-header.scroll-hidden {
    transform: none;
    transform: translateY(-250%);
}

/* Text Change Animations */
@keyframes slideOutLeft {
    to { opacity: 0; transform: translateX(-20px); }
}
@keyframes slideOutRight {
    to { opacity: 0; transform: translateX(20px); }
}
@keyframes slideInLeft {
    from { opacity: 0; transform: translateX(-20px); }
    to { opacity: 1; transform: translateX(0); }
}
@keyframes slideInRight {
    from { opacity: 0; transform: translateX(20px); }
    to { opacity: 1; transform: translateX(0); }
}

.msg-body.slide-out-left { animation: slideOutLeft 0.15s ease forwards; }
.msg-body.slide-out-right { animation: slideOutRight 0.15s ease forwards; }
.msg-body.slide-in-left { animation: slideInLeft 0.15s ease forwards; }
.msg-body.slide-in-right { animation: slideInRight 0.15s ease forwards; }

/* Streaming Text Animation */
@keyframes streamAnim {
    from { opacity: 0; transform: translateY(5px); }
    to { opacity: 1; transform: translateY(0); }
}

.stream-char {
    animation: streamAnim 0.2s ease-out forwards;
    display: inline-block;
}



.chat-loading-placeholder {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    padding-top: 60px;
}

.chat-loading-overlay {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    background-color: var(--white);
    z-index: 100;
    display: flex;
    align-items: center;
    justify-content: center;
    padding-top: 60px;
}

.visually-hidden {
    opacity: 0;
}

.chat-status-gradient {
    position: fixed;
    top: 0;
    left: 0;
    width: 100%;
    height: calc(var(--sat) + 20px);
    background: linear-gradient(to bottom, rgba(0,0,0,0.4), transparent);
    z-index: 900;
    pointer-events: none;
}

.memory-entry-list {
    display: flex;
    flex-direction: column;
    gap: 12px;
}

.memory-entry-card {
    padding: 12px;
    border: 1px solid var(--border-color, rgba(0, 0, 0, 0.08));
    border-radius: 14px;
    background: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.72));
    backdrop-filter: blur(var(--element-blur, 16px));
    -webkit-backdrop-filter: blur(var(--element-blur, 16px));
}

.memory-entry-head {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 12px;
    margin-bottom: 8px;
}

.memory-entry-title {
    font-size: 14px;
    font-weight: 600;
    color: var(--text-black);
}

.memory-entry-meta {
    font-size: 12px;
    color: var(--text-gray);
    text-transform: uppercase;
}

.memory-entry-preview {
    font-size: 13px;
    line-height: 1.45;
    color: var(--text-dark-gray);
    white-space: pre-wrap;
}

.memory-entry-fulltext {
    padding: 12px;
    border-radius: 14px;
    background: rgba(255, 255, 255, 0.08);
    border: 1px solid rgba(255, 255, 255, 0.06);
    font-size: 14px;
    line-height: 1.55;
    color: var(--text-black);
    white-space: pre-wrap;
}

.memory-chip-list {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    margin-top: 8px;
}

.memory-chip {
    display: inline-flex;
    align-items: center;
    padding: 4px 8px;
    border-radius: 999px;
    font-size: 12px;
    color: #7ee787;
    background: rgba(126, 231, 135, 0.12);
    border: 1px solid rgba(126, 231, 135, 0.22);
}

.memory-entry-delete {
    border: none;
    border-radius: 999px;
    padding: 6px 10px;
    background: rgba(255, 68, 68, 0.12);
    color: #ff6b6b;
    font-size: 12px;
    font-weight: 600;
}

.memory-status-badges {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
    justify-content: flex-end;
}

.memory-status-badge {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border-radius: 999px;
    padding: 6px 10px;
    font-size: 12px;
    font-weight: 600;
}

.memory-status-badge.vector {
    background: rgba(30, 200, 255, 0.14);
    color: #1ec8ff;
}

.memory-status-badge.indexed {
    background: rgba(126, 231, 135, 0.12);
    color: #7ee787;
}

.memory-preview-delete {
    color: #ff6b6b;
}

.memory-draft-actions {
    display: flex;
    align-items: center;
    gap: 8px;
}

.memory-entry-approve {
    border: none;
    border-radius: 999px;
    padding: 6px 10px;
    background: rgba(30, 200, 255, 0.14);
    color: #1ec8ff;
    font-size: 12px;
    font-weight: 600;
}

.memory-inline-link {
    margin-top: 8px;
    padding: 0;
    border: none;
    background: transparent;
    color: var(--vk-blue);
    font-size: 13px;
    font-weight: 600;
    text-align: left;
}



.clock-flip-enter-active,
.clock-flip-leave-active {
    transition: transform 0.25s cubic-bezier(0.4, 0, 0.2, 1), opacity 0.25s ease;
}
.clock-flip-enter-from {
    transform: translateY(-15px);
    opacity: 0;
}
.clock-flip-leave-to {
    transform: translateY(15px);
    opacity: 0;
}

/* Android text selection fix */
#view-chat.android-resize-fix .chat-container {
    transition: margin-bottom 0.25s cubic-bezier(0.2, 0.8, 0.2, 1);
}
#view-chat.android-resize-fix .chat-input-wrapper {
    transition: bottom 0.25s cubic-bezier(0.2, 0.8, 0.2, 1);
}
#view-chat.android-resize-fix .chat-input-container.keyboard-open .chat-input-content {
    padding-bottom: 0 !important;
}
</style>

<style scoped>
/* Scoped overrides if necessary, but mostly relying on chat.css */
.msg-avatar {
    display: flex;
    align-items: center;
    justify-content: center;
    color: white;
    font-weight: bold;
    font-size: 1.2em;
}

/* Swipe Animations */
.slide-next-enter-active, .slide-next-leave-active,
.slide-prev-enter-active, .slide-prev-leave-active {
  transition: all 0.2s ease;
}
.slide-next-enter-from { transform: translateX(10px); opacity: 0; }
.slide-next-leave-to { transform: translateX(-10px); opacity: 0; }
.slide-prev-enter-from { transform: translateX(-10px); opacity: 0; }
.slide-prev-leave-to { transform: translateX(10px); opacity: 0; }

.fade-enter-active, .fade-leave-active {
  transition: opacity 0.2s ease;
}
.fade-enter-from, .fade-leave-to {
  opacity: 0;
}


</style>
