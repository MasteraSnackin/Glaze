<script setup>
import { ref, computed, onMounted, onBeforeUnmount } from 'vue';
import { publishAppEvent, subscribeAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { translations, t, updateLanguage } from '@/utils/i18n.js';
import { initRipple } from '@/core/services/interactionEffects.js';
import Editor from '@/components/editors/GenericEditor.vue';
import { presetState, initPresetState, getEffectivePresetId, flushPresetSave } from '@/core/states/presetState.js';
import SheetView from '@/components/ui/SheetView.vue';
import HelpTip from '@/components/ui/HelpTip.vue';
import RegexSheet from '@/components/sheets/RegexSheet.vue';
import { logger } from '@/utils/logger.js';
import { getEffectivePersona } from '@/core/states/personaState.js';
import { normalizeBlockId } from '@/utils/presetBlockIds.js';
import { Toast } from '@capacitor/toast';

import { usePresetNavigation } from '@/composables/app/usePresetNavigation.js';
import { usePresetLoader } from '@/composables/app/usePresetLoader.js';
import { usePresetConnections } from '@/composables/app/usePresetConnections.js';
import { usePresetCRUD } from '@/composables/app/usePresetCRUD.js';
import { usePresetSelectors } from '@/composables/app/usePresetSelectors.js';
import { usePresetImage } from '@/composables/app/usePresetImage.js';
import { useBlockManager } from '@/composables/app/useBlockManager.js';
import { useBlockEditor } from '@/composables/app/useBlockEditor.js';
import { useAuthorsNoteSheet } from '@/composables/app/useAuthorsNoteSheet.js';
import { useSummarySheet } from '@/composables/app/useSummarySheet.js';
import { usePresetTokenPreview } from '@/composables/app/usePresetTokenPreview.js';

const emit = defineEmits(['open-fs', 'update:activeChatChar']);

const sheet = ref(null);

const props = defineProps({
    activeChatChar: { type: Object, default: null },
    chatHistory: { type: Array, default: () => [] },
    isGenerating: { type: Boolean, default: false },
    viewMode: { type: Boolean, default: false }
});

const effectivePersona = computed(() => getEffectivePersona(props.activeChatChar?.id, props.activeChatChar?.sessionId));

// --- 1. Navigation ---
const {
    scrollPositions, editingPresetId, optimisticGlobalPresetId,
    isEditingBlock, editingBlockId, showStash, navDirection,
    showAdvancedSettings, genSheetBodyRef, headerState,
    updateHeaderState, goBackFromEditor, openBlockEditor, closeBlockEditor,
    onTransitionBeforeLeave, onTransitionBeforeEnter
} = usePresetNavigation({ sheet, props });

// --- Shared computed (glue between composables) ---
const effectivePresetId = computed(() => getEffectivePresetId(props.activeChatChar?.id, props.activeChatChar?.sessionId));
const currentPresetId = computed(() => editingPresetId.value || effectivePresetId.value);
const currentPreset = computed(() => presetState.presets[currentPresetId.value] || presetState.presets.default_shino);
const activeBlocks = computed(() => (currentPreset.value?.blocks || []).filter(b => !b.isStashed));
const stashedBlocks = computed(() => (currentPreset.value?.blocks || []).filter(b => b.isStashed));
const activeEditBlock = computed(() => {
    if (!editingBlockId.value || !currentPreset.value?.blocks) return null;
    return currentPreset.value.blocks.find(b => b.id === editingBlockId.value) || null;
});

const activePresetName = computed(() => presetState.presets[effectivePresetId.value]?.name || '');
const activePresetType = computed(() => {
    const charId = props.activeChatChar?.id;
    const chatId = charId && props.activeChatChar?.sessionId ? `${charId}_${props.activeChatChar.sessionId}` : null;
    if (chatId && presetState.connections.chat[chatId] === effectivePresetId.value) return 'chat';
    if (charId && presetState.connections.character[charId] === effectivePresetId.value) return 'character';
    return 'global';
});
const activePresetReason = computed(() => {
    if (activePresetType.value === 'chat') return t('preset_this_chat') || 'This Chat';
    if (activePresetType.value === 'character') return t('preset_this_char') || 'This Character';
    return t('preset_global_default') || 'Global Default';
});
const chatPresetName = computed(() => {
    const charId = props.activeChatChar?.id;
    const chatId = charId && props.activeChatChar?.sessionId ? `${charId}_${props.activeChatChar.sessionId}` : null;
    const id = chatId ? presetState.connections.chat[chatId] : null;
    return id ? presetState.presets[id]?.name : '';
});
const charPresetName = computed(() => {
    const charId = props.activeChatChar?.id;
    const id = charId ? presetState.connections.character[charId] : null;
    return id ? presetState.presets[id]?.name : '';
});
const globalPresetName = computed(() => {
    const id = presetState.globalPresetId;
    return id ? presetState.presets[id]?.name : '';
});

// --- 2. Loader ---
const { loadPresets, setupPersistenceWatchers } = usePresetLoader({ currentPreset });

// --- 3. Connections ---
const { getPresetConnectionType, openPresetConnections, activatePreset } = usePresetConnections({ optimisticGlobalPresetId, props });

// --- Helper functions needed by multiple composables ---
function getBlockIcon(block) {
    if (normalizeBlockId(block.id) === 'chat_history') return '<path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2z"/>';
    return getRoleIcon(block.role);
}

function getRoleIcon(role) {
    switch (role) {
        case 'user': return '<path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"/>';
        case 'assistant': return '<path d="M20 9V7c0-1.1-.9-2-2-2h-3c0-1.66-1.34-3-3-3S9 3.34 9 5H6c-1.1 0-2 .9-2 2v2c-1.66 0-3 1.34-3 3s1.34 3 3 3v4c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2v-4c1.66 0 3-1.34 3-3s-1.34-3-3-3zM7.5 11.5c0-.83.67-1.5 1.5-1.5s1.5.67 1.5 1.5S9.83 13 9 13s-1.5-.67-1.5-1.5zM16 17H8v-2h8v2zm-1.5-4c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5z"/>';
        case 'system':
        default: return '<path d="M20 13H4c-.55 0-1 .45-1 1v6c0 .55.45 1 1 1h16c.55 0 1-.45 1-1v-6c0-.55-.45-1-1-1zM7 19c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zM20 3H4c-.55 0-1 .45-1 1v6c0 .55.45 1 1 1h16c.55 0 1-.45 1-1V4c0-.55-.45-1-1-1zM7 9c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2z"/>';
    }
}

function hasMacro(block, macroName) {
    let content = '';
    if (block.id === 'authors_note') content = props.activeChatChar?.authors_note || '';
    else if (block.id === 'summary') content = props.activeChatChar?.summary || '';
    else content = block.content || '';
    if (macroName === 'setvar') return content.includes('{{setvar::');
    if (macroName === 'getvar') return content.includes('{{getvar::');
    return false;
}

function isBlockLocked() { return false; }

function getPresetWeight(id, preset) {
    if (preset.isFeatured) return 0;
    const type = getPresetConnectionType(id);
    if (type === 'chat') return 1;
    if (type === 'character') return 2;
    if (type === 'global') return 3;
    return 4;
}

function comparePresetEntries(a, b) {
    const [idA, pA] = a; const [idB, pB] = b;
    const wA = getPresetWeight(idA, pA); const wB = getPresetWeight(idB, pB);
    if (wA !== wB) return wA - wB;
    const cA = pA.createdAt || 0; const cB = pB.createdAt || 0;
    if (cA !== cB) return cA - cB;
    return pA.name.localeCompare(pB.name);
}

// --- 4. Token Preview ---
const {
    resolveBlockContent, isChatSpecific, shouldShowTokens, extendedReplaceMacros,
    getPresetTokens, editingPresetTokens, displayedEditingTokens,
    activePresetTokens, displayedActiveTokens,
    globalTokens, charTokens, chatTokens,
    getBlockTokens, presetTokenCache
} = usePresetTokenPreview({
    currentPreset, editingPresetId, editingBlockId, effectivePresetId,
    activeChatChar: computed(() => props.activeChatChar),
    chatHistory: computed(() => props.chatHistory),
    effectivePersona,
    isGenerating: computed(() => props.isGenerating)
});

// --- 5. CRUD ---
const {
    createNewPreset, cloneCurrentPreset, renameCurrentPreset, editCurrentAuthor,
    triggerExportST, confirmDeletePreset, confirmResetPreset,
    triggerImport, onFileSelected, openAddPresetSheet
} = usePresetCRUD({ currentPreset, currentPresetId, editingPresetId, updateHeaderState });

// --- 6. Selectors ---
const {
    getPresetCreatedAt, sortedPresetEntries,
    openPresetSelector, openPresetConnectionManager,
    openMergeRoleSelector, openSquashRoleSelector, openReasoningEffortSelector,
    openPresetOptionsMenu: openPresetOptionsMenuRaw,
    dragPresetIndex, dragHoverIndex, onPresetDragStart, onPresetDragEnter, onPresetDrop, onPresetDragEnd,
    onPresetTouchStart, onPresetTouchMove, onPresetTouchEnd
} = usePresetSelectors({
    currentPreset, currentPresetId, editingPresetId,
    activeChatChar: computed(() => props.activeChatChar),
    getPresetTokens, getPresetWeight, comparePresetEntries,
    updateHeaderState, openAddPresetSheet
});

function openPresetOptionsMenu() {
    openPresetOptionsMenuRaw({
        cloneCurrentPreset, triggerExportST, renameCurrentPreset,
        editCurrentAuthor, triggerImageUpload, confirmDeletePreset, confirmResetPreset
    });
}

// --- 7. Image ---
const { triggerImageUpload, compressImage, onImageSelected } = usePresetImage({ currentPreset });

// --- 8. Block Manager ---
const {
    dragSrcIndex, addNewBlock, openCopyBlockPresetPicker, openCopyBlockPicker,
    stashActiveBlock, unstashBlock, openStashSheet,
    deleteActiveBlock, confirmDeleteStashedBlock,
    onDragStart, onDragEnter, onDragEnd, onTouchStart, onTouchMove, onTouchEnd
} = useBlockManager({
    currentPreset, editingBlockId, isEditingBlock, activeEditBlock, stashedBlocks,
    getBlockIcon, getPresetTokens, getPresetWeight, comparePresetEntries, closeBlockEditor
});

// --- 9. Block Editor ---
const { getMagicBlockFields, editorConfig, editorProxy, updateActiveBlock } = useBlockEditor({
    currentPreset, activeEditBlock, activeChatChar: computed(() => props.activeChatChar), emit
});

// --- 10. Authors Note Sheet ---
const { openAuthorsNoteSheet } = useAuthorsNoteSheet({
    currentPreset, activeChatChar: computed(() => props.activeChatChar)
});

// --- 11. Summary Sheet ---
const { openSummarySheet } = useSummarySheet({
    currentPreset, activeChatChar: computed(() => props.activeChatChar), chatHistory: computed(() => props.chatHistory)
});

// --- Local component functions ---
function handleOpenFs(field, isCurrentBase = true) {
    const val = isCurrentBase ? currentPreset.value[field] : field;
    const onSave = (newVal) => { if (isCurrentBase) currentPreset.value[field] = newVal; };
    publishAppEvent(APP_EVENTS.nav.openFsRequest, { value: val, onSave });
}

const openedFromRegex = ref(false);

async function open() {
    await initPresetState();
    await loadPresets();
    sheet.value?.open();
    updateHeaderState();
}

function close() { sheet.value?.close(); }

function onSheetClose() {
    openedFromRegex.value = false;
    flushPresetSave();
    scrollPositions.list = 0; scrollPositions.editor = 0; scrollPositions['block-editor'] = 0;
}

async function openPreset(id, fromRegex = false) {
    await initPresetState();
    await loadPresets();
    editingPresetId.value = id;
    openedFromRegex.value = fromRegex;
    sheet.value?.open();
    updateHeaderState();
}

defineExpose({ open, close, openAuthorsNoteSheet, openSummarySheet, openPreset });

const regexSheetRef = ref(null);
const presetRegexCount = computed(() => currentPreset.value?.regexes?.length || 0);

function openRegexSheetFromPreset() {
    if (openedFromRegex.value) close();
    else regexSheetRef.value?.open();
}

// --- Lifecycle ---
const unsubs = [];

function handleBackNavigation() {
    if (!sheet.value?.isVisible) return;
    if (isEditingBlock.value || editingPresetId.value) goBackFromEditor();
}

onMounted(async () => {
    initRipple();
    await initPresetState();
    await loadPresets();
    unsubs.push(subscribeAppEvent(APP_EVENTS.ui.backNavigation, handleBackNavigation));
    if (currentPreset.value) localStorage.setItem('gz_api_request_reasoning', currentPreset.value.reasoningEnabled);
    updateLanguage();
    unsubs.push(subscribeAppEvent(APP_EVENTS.ui.fsEditorClosed, () => {
        if (isEditingBlock.value) setTimeout(() => updateHeaderState(), 50);
    }));
    updateHeaderState();
    setupPersistenceWatchers();
});

onBeforeUnmount(() => { unsubs.forEach(unsub => unsub()); });
</script>
<template>
    <div class="preset-view-root">

    <SheetView ref="sheet" :title="headerState.title" :show-back="headerState.showBack || viewMode" :actions="headerState.actions" :z-index="11500" :view-mode="viewMode" @back="goBackFromEditor" @close="onSheetClose">
        <div class="gen-sheet-body" ref="genSheetBodyRef">
            <Transition :name="navDirection === 'forward' ? 'ps-fwd' : 'ps-back'" mode="out-in" @before-leave="onTransitionBeforeLeave" @before-enter="onTransitionBeforeEnter">
        <!-- ═══ SELECTOR LIST VIEW ═══ -->
        <div class="preset-selector-list" v-if="!isEditingBlock && !editingPresetId" key="list" data-scroll-key="list">
            <TransitionGroup name="preset-list" tag="div" class="ps-list">
                <div v-for="[id, preset] in sortedPresetEntries" :key="id"
                     class="ps-card"
                     :data-id="id"
                     draggable="true"
                     @dragstart="onPresetDragStart($event, id)"
                     @dragenter.prevent="onPresetDragEnter($event, id)"
                     @dragover.prevent
                     @drop="onPresetDrop($event, id)"
                     @dragend="onPresetDragEnd"
                     @touchstart="onPresetTouchStart($event, id)"
                     @touchmove="onPresetTouchMove($event)"
                     @touchend="onPresetTouchEnd($event)"
                     :class="{ 
                         'ps-active': (optimisticGlobalPresetId || presetState.globalPresetId) === id, 
                         'ps-has-bg': !!preset.image, 
                         'dragging': dragPresetIndex === presetState.presetOrder.indexOf(id),
                         'drag-hover': dragHoverIndex !== -1 && dragHoverIndex === presetState.presetOrder.indexOf(id) && dragHoverIndex !== dragPresetIndex
                     }"
                     :style="preset.image ? { backgroundImage: 'url(' + preset.image + ')' } : {}"
                     @click="activatePreset(id)">
                    <!-- Overlay for image cards -->
                    <div class="ps-card-overlay" v-if="preset.image"></div>
                    <!-- Featured badge -->
                    <div v-if="preset.isFeatured" class="ps-featured-badge">
                        {{ t('label_featured_preset') || 'FEATURED PRESET' }}
                    </div>
                    <!-- Icon only for non-image cards -->
                    <div class="ps-card-icon" v-if="!preset.image">
                        <svg viewBox="0 0 24 24"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-5 14H7v-2h7v2zm3-4H7v-2h10v2zm0-4H7V7h10v2z"/></svg>
                    </div>
                    <!-- Info -->
                    <div class="ps-card-info">
                        <div class="ps-card-name" :class="{ 'ps-with-bg': !!preset.image }">
{{ preset.name || 'Default' }}
</div>
                        <div style="display: flex; align-items: center; gap: 8px; flex-wrap: wrap; margin-top: 4px;">
                            <div class="ps-card-badge" :class="{ 'ps-with-bg': !!preset.image }">
                                <svg viewBox="0 0 24 24" class="ps-badge-icon"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>
                                {{ presetTokenCache[id] }}
                            </div>
                            <div class="ps-card-meta" :class="{ 'ps-with-bg': !!preset.image }">
                                <span v-if="preset.author">by {{ preset.author }}</span>
                                <span v-if="preset.descriptionKey">{{ t(preset.descriptionKey) }}</span>
                            </div>
                        </div>
                    </div>
                    <!-- Card Actions (Top Right) -->
                    <div class="ps-card-actions">
                        <!-- Connection badge -->
                        <div class="ps-badge-area">
                            <div class="ps-conn-badge"
                                 :class="['ps-conn-' + (getPresetConnectionType(id) || 'none'), { 'ps-with-bg': !!preset.image }]"
                                 @click="openPresetConnections(id, $event)"
                                 :title="t('header_connections') || 'Connections'">
                                <svg viewBox="0 0 24 24"><path d="M3.9 12c0-1.71 1.39-3.1 3.1-3.1h4V7H7c-2.76 0-5 2.24-5 5s2.24 5 5 5h4v-1.9H7c-1.71 0-3.1-1.39-3.1-3.1zM8 13h8v-2H8v2zm9-6h-4v1.9h4c1.71 0 3.1 1.39 3.1 3.1s-1.39 3.1-3.1 3.1h-4V17h4c2.76 0 5-2.24 5-5s-2.24-5-5-5z"/></svg>
                            </div>
                        </div>
                        <!-- Edit pencil -->
                        <div class="ps-edit-btn" :class="{ 'ps-with-bg': !!preset.image }" @click.stop="editingPresetId = id; updateHeaderState();">
                            <svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>
                        </div>
                    </div>
                </div>

                <!-- Add / Import Button -->
                <div class="ps-add-btn" @click="openAddPresetSheet" key="add-btn">
                    <svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>
                    <span>{{ t('btn_add') || 'Add / Import' }}</span>
                </div>
            </TransitionGroup>
        </div>

        <!-- ═══ EDITOR VIEW ═══ -->
        <div class="prompt-builder-wrapper" v-else-if="!isEditingBlock && editingPresetId" key="editor" data-scroll-key="editor">

                <!-- Consolidated Dashboard and Blocks Container -->
                <div class="preset-dashboard" :class="{ 'has-background': !!currentPreset.image }" :style="currentPreset.image ? { 'background-image': 'url(' + currentPreset.image + ')' } : {}">
                    <div class="dashboard-edit-header">
                        <div class="active-row-content">
                            <div class="active-name-group">
                                <div class="active-preset-name-wrapper">
                                    <div class="active-preset-name">
{{ currentPreset.name || 'Default' }}
</div>
                                </div>
                                <div v-if="currentPreset.author" class="active-preset-author">
by {{ currentPreset.author }}
</div>
                            </div>
                            
                            <!-- Consolidate Actions Top Right -->
                            <div class="action-icons-corner">
                                <div class="header-dots-btn" @click.stop="openPresetOptionsMenu">
                                    <svg viewBox="0 0 24 24"><path d="M12 8c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm0 2c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2zm0 6c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2z"/></svg>
                                </div>
                            </div>
                        </div>
                    </div>

                    <div class="dashboard-utils-row">
                        <div class="utils-left">
                            <div v-if="stashedBlocks.length > 0"
                                 class="header-stash-btn"
                                 @click.stop="openStashSheet"
                                 :title="t('stash') || 'Stash'">
                                <svg viewBox="0 0 24 24"><path d="M20 6h-8l-2-2H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm-6 10H6v-2h8v2zm4-4H6v-2h12v2z"/></svg>
                                <span class="stash-count-dot">{{ stashedBlocks.length }}</span>
                            </div>
                            <div class="header-stash-btn"
                                 @click.stop="openRegexSheetFromPreset"
                                 :title="t('menu_regex') || 'Regex'">
                                <svg viewBox="0 0 24 24"><path d="M9.4 16.6L4.8 12l4.6-4.6L8 6l-6 6 6 6 1.4-1.4zm5.2 0l4.6-4.6-4.6-4.6L16 6l6 6-6 6-1.4-1.4z"/></svg>
                                <span v-if="presetRegexCount > 0" class="stash-count-dot">{{ presetRegexCount }}</span>
                            </div>
                        </div>
                        <div class="utils-right">
                            <div class="active-tokens">
                                <svg viewBox="0 0 24 24"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>
                                <span>{{ displayedEditingTokens }}</span>
                            </div>
                        </div>
                    </div>

                    <!-- Integrated Block List directly below hierarchy -->
                    <div class="prompt-blocks-area">
                    <TransitionGroup name="block-list" tag="div">
                        <div v-for="block in activeBlocks" :key="block.id" 
                             class="prompt-block"
                             :class="{ 
                                 'disabled': !block.enabled,
                                 'dragging': dragSrcIndex === currentPreset.blocks.findIndex(b => b.id === block.id),
                                 'drag-hover': dragHoverIndex !== -1 && dragHoverIndex === currentPreset.blocks.findIndex(b => b.id === block.id) && dragSrcIndex !== dragHoverIndex
                             }"
                             :data-id="block.id"
                             draggable="true"
                             @dragstart="!isBlockLocked(block) && onDragStart($event, block.id)"
                             @dragenter.prevent="!isBlockLocked(block) && onDragEnter($event, block.id)"
                             @dragover.prevent
                             @drop="!isBlockLocked(block) && onDrop($event, block.id)"
                             @dragend="onDragEnd">
                            <div class="block-handle"
                                 @touchstart="!isBlockLocked(block) && onTouchStart($event, block.id)"
                                 @touchmove="!isBlockLocked(block) && onTouchMove($event)"
                                 @touchend="!isBlockLocked(block) && onTouchEnd($event)">
                                 <svg v-if="isBlockLocked(block)" viewBox="0 0 24 24" style="width:16px;height:16px;fill:currentColor;opacity:0.5"><path d="M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm-6 9c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm3.1-9H8.9V6c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2z"/></svg>
                                 <span v-else>≡</span>
                            </div>
                            <div class="block-content">
                                <svg viewBox="0 0 24 24" class="block-role-icon" v-html="getBlockIcon(block)"></svg>
                                <div class="block-name">
                                    {{ block.i18n ? t(block.i18n) : block.name }}
                                    <span v-if="hasMacro(block, 'setvar')" class="macro-badge setvar">set</span>
                                    <span v-if="hasMacro(block, 'getvar')" class="macro-badge getvar">get</span>
                                </div>
                                <div v-if="shouldShowTokens(block)" class="block-tokens" :title="t('label_tokens') || 'Tokens'">
                                    {{ getBlockTokens(block) }}
                                </div>
                            </div>
                            <div class="block-actions">
                                <div class="block-edit" @click.stop="openBlockEditor(block.id)">
                                    <svg viewBox="0 0 24 24"><path d="M3 17.46v3.04h3.04l11.12-11.12-3.04-3.04L3 17.46zm16.48-9.71c.39-.39.39-1.02 0-1.41l-1.63-1.63c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.04 3.04 1.83-1.83z"/></svg>
                                </div>
                                <div v-if="block.id === 'guided_generation'" class="block-lock-wrap">
                                    <svg viewBox="0 0 24 24" class="block-lock-icon"><path d="M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm-6 9c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm3.1-9H8.9V6c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2z"/></svg>
                                </div>
                                <input v-else type="checkbox" class="vk-switch block-toggle small-switch" v-model="block.enabled">
                            </div>
                        </div>
                    </TransitionGroup>
                    
                    <div class="add-block-btn prompt-block" @click="addNewBlock">
                        <div class="block-handle" style="opacity: 0">
≡
</div>
                        <div class="block-content">
                            <svg viewBox="0 0 24 24" class="block-role-icon"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>
                            <div class="block-name" data-i18n="add_block">
Add Block
</div>
                        </div>
                    </div>
                    </div> <!-- End prompt-blocks-area -->
                </div> <!-- End preset-dashboard -->

                <!-- Advanced Settings Section -->
                <div class="advanced-settings-toggle" @click="showAdvancedSettings = !showAdvancedSettings">
                    <span>{{ t('section_advanced_settings') || 'Advanced Settings' }}</span>
                    <svg :class="{ rotated: showAdvancedSettings }" viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
                </div>

                <Transition name="expand">
                    <div v-if="showAdvancedSettings" class="advanced-settings-panel">
                        <div class="menu-group">
                            <div class="section-header">
{{ t('section_postprocessing') || 'Prompt Postprocessing' }}
</div>
                            <div class="settings-item-checkbox" @click.capture="currentPreset.noAssistant ? Toast.show({ text: t('hint_merge_locked') || 'Required by NoAssistant mode — single block', duration: 'short', position: 'bottom' }) : null">
                                <div class="settings-text-col">
                                    <label>{{ t('label_merge_prompts') || 'Merge Prompts' }} <HelpTip term="preset-merge"/></label>
                                    <div class="settings-desc">
{{ t('desc_merge_prompts') || 'Combine adjacent blocks into one message' }}
</div>
                                </div>
                                <input type="checkbox" v-model="currentPreset.mergePrompts" class="vk-switch" :disabled="currentPreset.noAssistant">
                            </div>
                            <div class="settings-item" v-if="currentPreset.mergePrompts" @click="openMergeRoleSelector">
                                <label>{{ t('label_merge_role') || 'Merge Role' }}</label>
                                <div class="settings-desc">
{{ currentPreset.mergeRole }}
</div>
                            </div>
                            <div class="settings-item-checkbox">
                                <div class="settings-text-col">
                                    <label>{{ t('label_no_assistant') || 'NoAssistant' }} <HelpTip term="preset-noassistant"/></label>
                                    <div class="settings-desc">
{{ t('desc_no_assistant') || 'Send all chat history in a single block with role prefixes' }}
</div>
                                </div>
                                <input type="checkbox" v-model="currentPreset.noAssistant" class="vk-switch">
                            </div>
                            <template v-if="currentPreset.noAssistant">
                                <div class="settings-item">
                                    <label>{{ t('label_stop_string') || 'Stop String' }}</label>
                                    <div class="settings-desc">
{{ t('desc_stop_string') || 'Sent as stop parameter to the model. Leave empty to omit.' }}
</div>
                                    <input type="text" v-model="currentPreset.stopString" placeholder="e.g. User:">
                                </div>
                                <div class="settings-item">
                                    <label>{{ t('label_user_prefix') || 'User Prefix' }}</label>
                                    <div class="settings-desc">
{{ t('desc_user_prefix') || 'Prefix prepended to user messages in history block' }}
</div>
                                    <input type="text" v-model="currentPreset.userPrefix" placeholder="e.g. User: ">
                                </div>
                                <div class="settings-item">
                                    <label>{{ t('label_char_prefix') || 'Char Prefix' }}</label>
                                    <div class="settings-desc">
{{ t('desc_char_prefix') || 'Prefix prepended to character messages in history block' }}
</div>
                                    <input type="text" v-model="currentPreset.charPrefix" placeholder="e.g. Assistant: ">
                                </div>
                                <div class="settings-item" @click="openSquashRoleSelector">
                                    <label>{{ t('label_squash_role') || 'Squash Role' }}</label>
                                    <div class="settings-desc">
{{ t('desc_squash_role') || 'Consecutive messages from this role will be merged' }}: {{ currentPreset.squashRole }}
</div>
                                </div>
                            </template>
                        </div>

                        <div class="menu-group">
                            <div class="section-header">
{{ t('label_reasoning_settings') || 'Reasoning' }} <HelpTip term="preset-reasoning"/>
</div>
                            <div class="settings-item-checkbox">
                                <div class="settings-text-col">
                                <label>{{ t('label_parse_inline_reasoning') || 'Parse Inline Reasoning' }} <HelpTip term="preset-reasoning-inline"/></label>
                                <div class="settings-desc">
{{ t('desc_parse_inline_reasoning') || 'Extracts reasoning from the message body and inserts it into the reasoning block' }}
</div>
                                </div>
                                <input type="checkbox" v-model="currentPreset.parseInlineReasoning" class="vk-switch">
                            </div>
                            <div class="settings-item" v-if="currentPreset.parseInlineReasoning">
                            <label>{{ t('label_reasoning_tags') || 'Reasoning Tags (Outer CoT)' }}</label>
                                <input type="text" v-model="currentPreset.reasoningStart" placeholder="<think>" style="margin-bottom: 5px;">
                                <input type="text" v-model="currentPreset.reasoningEnd" placeholder="</think>">
                            </div>
                        </div>

                        <!-- Function Prompts -->
                        <div class="menu-group">
                            <div class="section-header">
{{ t('label_preset_prompts') || 'Function Prompts' }}
</div>
                            <div class="settings-item">
                                <div class="label-row">
                                    <label>{{ t('label_impersonation_prompt') || 'Impersonation Prompt' }}</label>
                                    <div class="expand-btn" @click="handleOpenFs('impersonationPrompt')">
<svg viewBox="0 0 24 24"><path d="M15 3l2.3 2.3-2.89 2.87 1.42 1.42L18.7 6.7 21 9V3zM3 9l2.3-2.3 2.87 2.89 1.42-1.42L6.7 5.3 9 3H3zm6 12l-2.3-2.3 2.89-2.87-1.42-1.42L5.3 17.3 3 15v6zm12-6l-2.3 2.3-2.87-2.89-1.42 1.42 2.89 2.87L15 21h6z"/></svg>
</div>
                                </div>
                                <textarea v-model="currentPreset.impersonationPrompt" rows="3" :placeholder="t('placeholder_impersonation_prompt') || 'Prompt to trigger impersonation...'"></textarea>
                            </div>
                            <div class="settings-item">
                                <div class="label-row">
                                    <label>{{ t('label_summary_prompt') || 'Summary Prompt' }}</label>
                                    <div class="expand-btn" @click="handleOpenFs('summaryPrompt')">
<svg viewBox="0 0 24 24"><path d="M15 3l2.3 2.3-2.89 2.87 1.42 1.42L18.7 6.7 21 9V3zM3 9l2.3-2.3 2.87 2.89 1.42-1.42L6.7 5.3 9 3H3zm6 12l-2.3-2.3 2.89-2.87-1.42-1.42L5.3 17.3 3 15v6zm12-6l-2.3 2.3-2.87-2.89-1.42 1.42 2.89 2.87L15 21h6z"/></svg>
</div>
                                </div>
                                <textarea v-model="currentPreset.summaryPrompt" rows="3" placeholder="Summarize the following roleplay conversation... (use {{history}})"></textarea>
                            </div>
                        </div>

                    </div>
                </Transition>
            </div>

        <!-- Block Editor View -->
        <div v-else-if="isEditingBlock" class="block-editor-view" key="block-editor" data-scroll-key="block-editor" style="min-height: 100%;">
            <div class="block-editor-scroll">
                <Editor v-model="editorProxy" :config="editorConfig" @open-fs="(data) => emit('open-fs', data)">
                    <template #footer>
                        <div class="block-editor-inline-actions settings-item" v-if="activeEditBlock && !activeEditBlock.isStatic" style="border-top: 1px solid rgba(127,127,127,0.1); border-bottom: none;">
                            <button class="editor-btn stash-btn" @click="stashActiveBlock">
                                <svg viewBox="0 0 24 24"><path d="M20 6h-8l-2-2H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm-6 10H6v-2h8v2zm4-4H6v-2h12v2z"/></svg>
                                <span>{{ t('action_stash') || 'Move to stash' }}</span>
                            </button>
                            <button class="editor-btn delete-btn" @click="deleteActiveBlock">
                                <svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>
                                <span>{{ t('btn_delete') || 'Delete' }}</span>
                            </button>
                        </div>
                    </template>
                </Editor>
            </div>
        </div>
            </Transition>
        </div>
    </SheetView>

    <RegexSheet ref="regexSheetRef" :active-chat-char="activeChatChar" :inside-preset="true" :z-index="11800" />

    <input
        type="file"
        id="preset-file-input"
        style="display: none" 
        @change="onFileSelected"
    >
    <input 
        type="file" 
        id="preset-image-input" 
        style="display: none" 
        accept="image/*" 
        @change="onImageSelected"
    >
    </div>
</template>

<style scoped>
/* API Status Base Style (moved from inline) */
.conn-badge {
    display: flex; 
    align-items: center; 
    font-size: 0.75em; 
    cursor: pointer; 
    padding: 4px 8px; 
    border-radius: 12px; 
    font-weight: normal; 
    text-transform: none;
    transition: all 0.3s ease;
}

#api-status-text {
    transition: opacity 0.2s ease, color 0.3s ease;
}

.status-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background-color: orange;
    margin-right: 6px;
    transition: background-color 0.3s ease;
}
.status-dot.connecting { background-color: orange; }
.status-dot.connected { background-color: #4CAF50; }
.status-dot.failed { background-color: #ff4444; }

/* Prompt Preset Editor Styles */
.preset-list-move {
    transition: transform 0.3s cubic-bezier(0.25, 1, 0.5, 1);
}
.ps-card.dragging {
    opacity: 0.5;
    transform: scale(0.98);
}
.ps-card.drag-hover {
    transform: scale(1.02);
    box-shadow: 0 0 0 2px var(--vk-blue), 0 5px 15px rgba(0,0,0,0.2) !important;
    z-index: 2;
}

.prompt-container {
    padding: 0 !important;
    overflow: hidden;
}

.prompt-block {
    background-color: transparent;
    border: none;
    border-radius: 0;
    border-bottom: 1px solid rgba(127, 127, 127, 0.2);
    margin-bottom: 0;
    display: flex;
    overflow: hidden;
    box-shadow: none;
    transition: box-shadow 0.2s, opacity 0.3s ease, background-color 0.3s ease;
    align-items: center;
    padding-right: 12px;
    position: relative;
    z-index: 1;
    width: 100%;
}

.prompt-block:last-child {
    border-bottom: none;
}

.prompt-block.dragging {
    opacity: 0.5;
    transform: scale(0.98);
}

.prompt-block.drag-hover {
    box-shadow: inset 0 0 0 2px var(--vk-blue) !important;
    z-index: 2;
}

.prompt-block.disabled {
    opacity: 0.5;
}

.preset-selector {
  height: 32px;
  display: flex;
  align-items: center;
  gap: 6px;
  cursor: pointer;
  font-weight: 600;
  font-size: 13px;
  color: var(--vk-blue);
  padding: 0 14px;
  border-radius: 16px;
  background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.15);
  backdrop-filter: blur(var(--element-blur, 12px));
  -webkit-backdrop-filter: blur(var(--element-blur, 12px));
  border: 1px solid rgba(var(--vk-blue-rgb, 82, 139, 204), 0.2);
  transition: transform 0.1s ease, background-color 0.2s, opacity 0.2s;
  overflow: hidden;
}

.preset-selector:active {
  transform: scale(0.95);
  opacity: 0.8;
}

.token-count-badge {
    display: flex;
    align-items: center;
    font-size: 12px;
    color: var(--text-gray);
    background-color: rgba(0,0,0,0.05);
    padding: 4px 8px;
    border-radius: 12px;
    margin-left: auto;
}
.token-count-badge svg {
    width: 14px;
    height: 14px;
    margin-right: 4px;
    fill: currentColor;
    opacity: 0.7;
}

.preset-selector svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
}

.block-handle {
    width: 30px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: grab;
    color: var(--text-gray);
    font-size: 20px;
    line-height: 1;
    user-select: none;
    padding: 0 4px;
    touch-action: none;
}

.block-content {
    flex: 1;
    padding: 10px 0;
    display: flex;
    align-items: center;
    overflow: hidden;
}

.block-name {
    font-weight: 500;
    font-size: 15px;
    color: var(--text-black);
    flex: 1;
    white-space: normal;
    word-break: break-word;
    display: flex;
    align-items: center;
}

.macro-badge {
    font-size: 9px;
    padding: 1px 4px;
    border-radius: 4px;
    margin-left: 4px;
    margin-bottom: 2px;
    text-transform: uppercase;
    font-weight: bold;
    color: white;
    line-height: 1;
    flex-shrink: 0;
}
.macro-badge.setvar {
    background-color: var(--vk-blue);
}
.macro-badge.getvar {
    background-color: #4CAF50;
}

.block-role-icon {
    width: 16px;
    height: 16px;
    opacity: 0.6;
    fill: currentColor;
    margin-right: 8px;
}

.block-tokens {
    font-size: 11px;
    color: var(--text-gray);
    background-color: rgba(0,0,0,0.05);
    padding: 2px 5px;
    border-radius: 8px;
    flex-shrink: 0;
}

.block-actions {
    display: flex;
    align-items: center;
}

.block-edit {
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    color: var(--text-gray);
    opacity: 0.6;
    transition: opacity 0.2s;
}

.block-edit:active {
    opacity: 1;
}

.block-edit svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
}

.small-switch {
    transform: scale(0.8);
    transform-origin: right center;
}

.block-lock-wrap {
    width: 44px;
    height: 24px;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
}

.block-lock-icon {
    width: 18px;
    height: 18px;
    fill: var(--text-gray, rgba(127,127,127,0.5));
}

.preset-connection-btn {
    width: 36px;
    height: 36px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 50%;
    background: rgba(var(--vk-blue-rgb), 0.1);
    color: var(--vk-blue);
    cursor: pointer;
    transition: all 0.2s;
    flex-shrink: 0;
}

.preset-connection-btn:hover {
    background: rgba(var(--vk-blue-rgb), 0.2);
    transform: scale(1.05);
}

.preset-connection-btn svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
}

.block-list-enter-active,
.block-list-leave-active {
  transition: all 0.3s ease;
}
.block-list-enter-from,
.block-list-leave-to {
  opacity: 0;
  transform: translateY(-10px);
}

.block-list-move {
  transition: none !important;
}

.status-fade-enter-active,
.status-fade-leave-active {
  transition: opacity 0.2s ease, transform 0.2s ease;
}
.status-fade-enter-from,
.status-fade-leave-to {
  opacity: 0;
  transform: translateY(5px);
}

/* Slide Transitions */
.slide-left-enter-active,
.slide-left-leave-active,
.slide-right-enter-active,
.slide-right-leave-active {
  transition: transform 0.15s ease, opacity 0.15s ease;
}

.slide-left-enter-from {
  transform: translateX(20px);
  opacity: 0;
}
.slide-left-leave-to {
  transform: translateX(-20px);
  opacity: 0;
}

.slide-right-enter-from {
  transform: translateX(-20px);
  opacity: 0;
}
.slide-right-leave-to {
  transform: translateX(20px);
  opacity: 0;
}

.noise-bg::before {
    content: "";
    position: absolute;
    top: 0; left: 0; width: 100%; height: 100%;
    background-image: url("data:image/svg+xml,%3Csvg viewBox='0 0 200 200' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noiseFilter'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.8' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noiseFilter)' opacity='1'/%3E%3C/svg%3E");
    opacity: 0.025;
    background-size: 300px 300px;
    pointer-events: none;
    z-index: 0;
}

.gen-sheet-header {
    height: 56px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 16px;
    border-bottom: 1px solid var(--border-color);
    flex-shrink: 0;
}

.header-title {
    font-weight: 600;
    font-size: 17px;
}

.header-btn {
    width: 40px;
    height: 40px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    color: var(--vk-blue);
}
.header-btn svg { width: 24px; height: 24px; fill: currentColor; }

.gen-sheet-tabs { padding: 10px 16px; flex-shrink: 0; }
.gen-sheet-body { 
    position: relative; 
    display: flex;
    flex-direction: column;
    flex: 1;
}

.clickable-selector {
    display: flex;
    align-items: center;
    justify-content: space-between;
    background: var(--bg-item);
    border: 1px solid var(--border-color);
    padding: 0 16px;
    height: 44px;
    border-radius: 12px;
    cursor: pointer;
    font-size: 14px;
    transition: background 0.2s;
    margin-top: 4px;
}

.clickable-selector:active {
    background: var(--bg-item-active);
}

.clickable-selector svg {
    width: 20px;
    height: 20px;
    fill: var(--text-gray);
    opacity: 0.5;
}

.summary-sheet {
    padding-bottom: 4px;
}

.summary-status-row {
    margin: 4px 16px 12px;
    padding: 12px;
    border-radius: 14px;
    background: rgba(var(--vk-blue-rgb), 0.06);
    border: 1px solid var(--border-color);
}

.summary-status-badge {
    font-weight: 600;
    margin-bottom: 4px;
}

.summary-status-text {
    font-size: 13px;
    color: var(--text-gray);
    line-height: 1.45;
}

.summary-action-grid {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 10px;
    padding: 0 16px 16px;
}

.summary-action-btn {
    margin-top: 0;
}

.summary-action-secondary {
    background: rgba(var(--vk-blue-rgb), 0.1);
    color: var(--vk-blue);
}

@media (max-width: 520px) {
    .summary-action-grid {
        grid-template-columns: 1fr;
    }
}

.preset-overview-block {
    margin: 0 16px 16px;
    padding: 12px;
    background: rgba(var(--vk-blue-rgb), 0.05);
    border: 1px solid var(--border-color);
    border-radius: 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
}

.preset-dashboard {
    /* Base styling for when no image is present */
    margin: 0 16px 16px;
    padding: 12px 0 0;
    background: rgba(var(--vk-blue-rgb), 0.05);
    border: 1px solid var(--border-color);
    border-radius: 16px;
    background-clip: padding-box;
    display: flex;
    flex-direction: column;
    gap: 12px;
    transition: background 0.2s, transform 0.1s;
    position: relative;
    overflow: hidden;
}

.preset-dashboard.has-background {
    background-size: 100% auto;
    background-position: top center;
    background-repeat: no-repeat;
    background-color: transparent;
    min-height: auto;
    justify-content: flex-start;
}

.preset-dashboard.has-background::before {
    content: "";
    position: absolute;
    top: 0; left: 0; width: 100%; height: 100%;
    /* Fade from dark at top to app background color at bottom */
    background: linear-gradient(to bottom, rgba(0,0,0,0.85) 0%, rgba(0,0,0,0.6) 80px, var(--app-bg) 200px);
    z-index: 0;
}

.preset-dashboard.has-background .active-preset-name,
.preset-dashboard.has-background .active-label,
.preset-dashboard.has-background .level-pill,
.preset-dashboard.has-background .level-name,
.preset-dashboard.has-background .active-preset-author {
    color: white;
    text-shadow: 0 1px 4px rgba(0,0,0,0.5);
}

.preset-dashboard.has-background .active-preset-author {
    opacity: 0.7;
}

.preset-dashboard.has-background .hierarchy-item.active {
    background: rgba(255, 255, 255, 0.2);
    backdrop-filter: blur(4px);
    -webkit-backdrop-filter: blur(4px);
    border: 1px solid rgba(255, 255, 255, 0.1);
}

.action-icons-corner {
    position: absolute;
    top: 16px;
    right: 12px;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 12px;
    z-index: 5;
}

.preset-dashboard.has-background .active-tokens {
    background: rgba(255, 255, 255, 0.2);
    color: white;
    backdrop-filter: blur(8px);
    -webkit-backdrop-filter: blur(8px);
    border: 1px solid rgba(255,255,255,0.1);
}

.preset-dashboard.has-background .header-stash-btn {
    background: rgba(255, 255, 255, 0.2);
    color: white;
    backdrop-filter: blur(8px);
    -webkit-backdrop-filter: blur(8px);
    border: 1px solid rgba(255,255,255,0.1);
}

.preset-dashboard.has-background .header-stash-btn:hover {
    background: rgba(255, 255, 255, 0.3);
}

.dashboard-utils-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 0 16px;
    margin-top: 24px;
}

.utils-left, .utils-right {
    display: flex;
    align-items: center;
    gap: 8px;
}

.header-dots-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 32px;
    height: 32px;
    background: rgba(var(--vk-blue-rgb), 0.1);
    border-radius: 50%;
    cursor: pointer;
    color: var(--vk-blue);
    transition: all 0.2s;
}

.preset-dashboard.has-background .header-dots-btn {
    background: rgba(255, 255, 255, 0.2);
    color: white;
    backdrop-filter: blur(8px);
    -webkit-backdrop-filter: blur(8px);
    border: 1px solid rgba(255,255,255,0.1);
}

.header-dots-btn svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
    opacity: 0.8;
}

.prompt-blocks-area {
    position: relative;
    z-index: 1;
    display: flex;
    flex-direction: column;
}

/* Removed active scaling for the whole dashboard since it contains interactive elements now */

.dashboard-active-row {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 4px;
    cursor: pointer;
    padding: 8px;
    border-radius: 12px;
    transition: background 0.2s;
}

.dashboard-edit-header {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 4px;
    padding: 0 20px;
}

.active-row-content {
    display: flex;
    align-items: center;
    gap: 12px;
    width: 100%;
}

.dashboard-active-row:hover {
    background: rgba(0,0,0,0.03);
}

.active-label {
    font-size: 10px;
    font-weight: 700;
    text-transform: uppercase;
    color: var(--vk-blue);
    letter-spacing: 0.05em;
    opacity: 0.7;
}

.active-preset-name-wrapper {
    display: flex;
    align-items: center;
    gap: 4px;
    min-width: 0;
    position: relative;
    z-index: 10;
}

.active-preset-name {
    font-size: 18px;
    font-weight: 700;
    color: var(--text-black);
    line-height: 1.2;
    word-break: break-word; /* Allow wrapping */
}

.preset-name-arrow {
    width: 20px;
    height: 20px;
    fill: currentColor;
    opacity: 0.5;
}

.preset-dashboard.has-background .preset-name-arrow {
    filter: drop-shadow(0 1px 4px rgba(0,0,0,0.5));
}

.active-name-group {
    display: flex;
    flex-direction: column;
    gap: 0px;
    flex: 1;
    cursor: pointer;
    min-width: 0;
    padding-right: 40px;
}

.active-preset-author {
    font-size: 12px;
    font-weight: 500;
    color: var(--vk-blue);
    opacity: 0.8;
    word-break: break-word; /* Allow wrapping */
}

.active-tokens {
    display: flex;
    align-items: center;
    gap: 4px;
    font-size: 12px;
    font-weight: 600;
    color: var(--text-gray);
    background: rgba(0,0,0,0.05);
    padding: 4px 8px;
    border-radius: 20px;
}

.active-tokens svg {
    width: 14px;
    height: 14px;
    fill: currentColor;
    opacity: 0.7;
}

.hierarchy-stack {
    display: flex;
    align-items: center;
    gap: 4px;
    background: rgba(0,0,0,0.03);
    padding: 4px;
    border-radius: 12px;
}

.hierarchy-item {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding: 6px 8px;
    border-radius: 8px;
    transition: all 0.2s;
    min-width: 0;
}

.hierarchy-item.active {
    background: #2c2c2e;
    box-shadow: 0 2px 8px rgba(0,0,0,0.05);
}

.hierarchy-item.empty {
    opacity: 0.4;
}

.level-pill {
    font-size: 9px;
    font-weight: 700;
    text-transform: uppercase;
    color: var(--text-gray);
    opacity: 0.6;
}

.hierarchy-item.active .level-pill {
    color: var(--vk-blue);
    opacity: 1;
}

.level-name {
    font-size: 11px;
    font-weight: 600;
    color: var(--text-black);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

/* Tiny token chips removed from hierarchy */

.hierarchy-arrow {
    display: flex;
    align-items: center;
    color: var(--text-gray);
    opacity: 0.3;
}

.hierarchy-arrow svg {
    width: 14px;
    height: 14px;
    fill: currentColor;
}

.add-block-btn {
    border-top: 1px solid rgba(127, 127, 127, 0.2);
    cursor: pointer;
    transition: background 0.2s;
    background: transparent;
}

.add-block-btn .block-name {
    color: var(--vk-blue);
    font-weight: 600;
}

.add-block-btn .block-role-icon {
    color: var(--vk-blue);
    opacity: 0.8;
}

.add-block-btn:active {
    background: rgba(var(--vk-blue-rgb), 0.05);
}

/* Old Card Styles removed */
.preset-card-bottom {
    display: flex;
    justify-content: space-between;
    align-items: center;
}

.preset-display-name {
    font-size: 18px;
    font-weight: 700;
    color: var(--text-black);
}

.preset-chevron {
    color: var(--text-gray);
    display: flex;
    align-items: center;
}

.preset-chevron svg {
    width: 24px;
    height: 24px;
    fill: currentColor;
}

/* Advanced Settings Toggle */
.advanced-settings-toggle {
    margin: 16px;
    padding: 12px;
    border-radius: 12px;
    background: var(--bg-gray);
    display: flex;
    justify-content: space-between;
    align-items: center;
    cursor: pointer;
    font-weight: 600;
    font-size: 14px;
    color: var(--text-gray);
    transition: all 0.2s;
}

.advanced-settings-toggle:active {
    background: rgba(0,0,0,0.05);
}

.advanced-settings-toggle svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
    transition: transform 0.3s cubic-bezier(0.16, 1, 0.3, 1);
}

.advanced-settings-toggle svg.rotated {
    transform: rotate(180deg);
}

.advanced-settings-panel {
    overflow: hidden;
}

/* Transitions */
.expand-enter-active,
.expand-leave-active {
  transition: all 0.3s cubic-bezier(0.16, 1, 0.3, 1);
  max-height: 1000px;
  opacity: 1;
}

.expand-enter-from,
.expand-leave-to {
  max-height: 0;
  opacity: 0;
  transform: translateY(-10px);
}

.stash-section {
    margin-top: 16px;
    padding-top: 16px;
    border-top: 1px solid rgba(255,255,255,0.05);
}

.stash-toggle {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 12px;
    background: rgba(var(--vk-blue-rgb), 0.05);
    border-radius: 10px;
    cursor: pointer;
    font-size: 14px;
    font-weight: 600;
    color: var(--vk-blue);
    transition: background 0.2s;
}

.stash-toggle:hover {
    background: rgba(var(--vk-blue-rgb), 0.1);
}

.stash-icon {
    width: 20px;
    height: 20px;
    fill: currentColor;
    opacity: 0.8;
}

.chevron-icon {
    width: 20px;
    height: 20px;
    fill: currentColor;
    margin-left: auto;
    transition: transform 0.3s;
}

.chevron-icon.rotated {
    transform: rotate(180deg);
}

.stash-list {
    display: flex;
    flex-direction: column;
    gap: 8px;
    margin-top: 8px;
    padding: 4px;
}

.stashed-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 8px 12px;
    background: rgba(255,255,255,0.03);
    border: 1px solid rgba(255,255,255,0.05);
    border-radius: 10px;
    gap: 12px;
}

.stashed-info {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
}

.stashed-role-icon {
    width: 16px;
    height: 16px;
    fill: var(--text-gray);
    flex-shrink: 0;
}

.stashed-name {
    font-size: 13px;
    color: var(--text-black);
    font-weight: 500;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.stashed-actions {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-shrink: 0;
}

.unstash-btn {
    background: var(--vk-blue);
    color: white;
    border: none;
    padding: 4px 10px;
    border-radius: 6px;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
}

.stashed-delete {
    color: #ff4444;
    cursor: pointer;
    display: flex;
    padding: 4px;
    opacity: 0.7;
    transition: opacity 0.2s;
}

.stashed-delete:hover {
    opacity: 1;
}

.stashed-delete svg {
    width: 18px;
    height: 18px;
    fill: currentColor;
}

.header-stash-btn {
    position: relative;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 6px;
    background: rgba(var(--vk-blue-rgb), 0.1);
    border-radius: 20px;
    cursor: pointer;
    color: var(--vk-blue);
    transition: all 0.2s;
}

.header-stash-btn:hover {
    background: rgba(var(--vk-blue-rgb), 0.2);
}

.header-stash-btn.active {
    background: var(--vk-blue);
    color: white;
}

.header-stash-btn svg {
    width: 14px;
    height: 14px;
    fill: currentColor;
    opacity: 0.7;
}

.stash-count-dot {
    position: absolute;
    top: -4px;
    right: -4px;
    background: #ff4444;
    color: white;
    font-size: 9px;
    font-weight: 700;
    min-width: 12px;
    height: 12px;
    border-radius: 6px;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 0 3px;
    border: 1px solid var(--app-bg);
}

.small-header {
    margin-bottom: 8px;
    font-size: 12px !important;
    opacity: 0.6;
}

/* Block Editor Rework */
.block-editor-view {
    display: flex;
    flex-direction: column;
}

.block-editor-scroll {
    padding-bottom: 40px;
}

:deep(.editor-container) {
    height: auto !important;
    overflow: visible !important;
}

.block-editor-inline-actions {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding: 16px;
}

.editor-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 10px;
    width: 100%;
    padding: 14px;
    border-radius: 12px;
    border: none;
    font-size: 15px;
    font-weight: 600;
    cursor: pointer;
    transition: transform 0.1s, opacity 0.2s;
}

.editor-btn:active {
    transform: scale(0.98);
}

.stash-btn {
    background: rgba(var(--vk-blue-rgb), 0.1);
    color: var(--vk-blue);
}

.delete-btn {
    background: rgba(255, 68, 68, 0.1);
    color: #ff4444;
}

.editor-btn svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
}

/* ═══ Preset Selector List ═══ */
.preset-selector-list {
    padding: 0 16px 20px;
    padding-bottom: calc(var(--footer-height, 0px) + var(--keyboard-overlap, 0px) + 20px);
}

.ps-list {
    display: flex;
    flex-direction: column;
    gap: 10px;
}

.ps-card {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 10px 10px;
    background: var(--menu-group-bg, rgba(0,0,0,0.02));
    border: 2px solid #2c2d2e;
    border-radius: 12px;
    cursor: pointer;
    transition: all 0.2s ease;
    user-select: none;
    position: relative;
    overflow: hidden;
    background-size: cover;
    background-position: center top;
}

.ps-card.ps-has-bg {
    min-height: 160px;
    align-items: flex-end;
    padding: 12px 16px;
}

.ps-card:active {
    transform: scale(0.98);
}

.ps-card.ps-has-bg:active .ps-card-overlay {
    background: linear-gradient(to top, rgba(0,0,0,0.9) 0%, rgba(0,0,0,0.4) 100%);
}

.ps-card.ps-active {
    border-color: var(--accent-color, var(--vk-blue));
}

/* Overlay for image cards */
.ps-card-overlay {
    position: absolute;
    top: 0; left: 0; width: 100%; height: 100%;
    background: linear-gradient(to top, rgba(0,0,0,0.8) 0%, rgba(0,0,0,0.3) 100%);
    z-index: 1;
    pointer-events: none;
}

.ps-card > *:not(.ps-card-overlay):not(.ps-featured-badge):not(.ps-card-actions) {
    position: relative;
    z-index: 2;
}

/* Featured badge */
.ps-featured-badge {
    position: absolute;
    top: 10px;
    left: 12px;
    background: transparent;
    color: rgba(255, 255, 255, 0.5);
    font-size: 9px;
    font-weight: 700;
    padding: 0;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    z-index: 3;
    text-shadow: 0 1px 2px rgba(0,0,0,0.5);
}

.ps-card-icon {
    width: 40px;
    height: 40px;
    border-radius: 50%;
    background: rgba(var(--vk-blue-rgb), 0.1);
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    color: var(--vk-blue);
    box-shadow: 0 2px 5px rgba(0,0,0,0.1);
}

.ps-card.ps-has-bg .ps-card-icon {
    display: none;
}

.ps-card-icon svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
}

.ps-card-info {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    padding-right: 80px;
}

.ps-card-label-row {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
    margin-bottom: 2px;
}

.ps-card-name {
    font-size: 15px;
    font-weight: 600;
    color: var(--text-black);
    white-space: normal;
    word-break: break-word;
}

.ps-card-name.ps-with-bg {
    color: #ffffff;
    text-shadow: 0 1px 3px rgba(0,0,0,0.8);
    font-size: 16px;
    white-space: normal;
    word-break: break-word;
}

.ps-card-badge {
    display: flex;
    align-items: center;
    gap: 4px;
    font-size: 10px;
    font-weight: 700;
    padding: 2px 6px;
    border-radius: 12px;
    background: rgba(0, 0, 0, 0.05);
    color: var(--text-gray);
    flex-shrink: 0;
}

.ps-card-badge.ps-with-bg {
    background: rgba(255, 255, 255, 0.2);
    color: white;
    backdrop-filter: blur(4px);
    -webkit-backdrop-filter: blur(4px);
    border: 1px solid rgba(255, 255, 255, 0.1);
}

.ps-badge-icon {
    width: 12px;
    height: 12px;
    fill: currentColor;
    opacity: 0.7;
}

.ps-card-meta {
    font-size: 12px;
    color: var(--text-gray);
    display: -webkit-box;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
}

.ps-card-meta.ps-with-bg {
    color: rgba(255,255,255,0.7);
    text-shadow: 0 1px 2px rgba(0,0,0,0.8);
}

.ps-card-meta > span:not(:last-child)::after {
    content: ' · ';
    opacity: 0.5;
}

.ps-badge-area {
    flex-shrink: 0;
}

.ps-conn-badge {
    width: 30px;
    height: 30px;
    border-radius: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: all 0.2s;
    cursor: pointer;
}

.ps-conn-badge:active {
    transform: scale(0.9);
}

.ps-conn-badge svg {
    width: 16px;
    height: 16px;
    fill: currentColor;
}

.ps-conn-none {
    background: rgba(0,0,0,0.04);
    color: var(--text-gray);
    opacity: 0.5;
}

.ps-conn-badge.ps-with-bg.ps-conn-none {
    background: rgba(255,255,255,0.15);
    color: white;
    opacity: 0.6;
}

.ps-conn-global {
    background: rgba(52, 199, 89, 0.12);
    color: #34c759;
}

.ps-conn-character {
    background: rgba(175, 82, 222, 0.12);
    color: #af52de;
}

.ps-conn-chat {
    background: rgba(255, 149, 0, 0.12);
    color: #ff9500;
}

.ps-conn-badge.ps-with-bg.ps-conn-global,
.ps-conn-badge.ps-with-bg.ps-conn-character,
.ps-conn-badge.ps-with-bg.ps-conn-chat {
    backdrop-filter: blur(4px);
    -webkit-backdrop-filter: blur(4px);
    border: 1px solid rgba(255,255,255,0.1);
}

.ps-edit-btn {
    width: 34px;
    height: 34px;
    border-radius: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--text-gray);
    opacity: 0.6;
    cursor: pointer;
    transition: all 0.2s;
    flex-shrink: 0;
}

.ps-edit-btn:active {
    opacity: 1;
    background: rgba(var(--vk-blue-rgb), 0.08);
    color: var(--vk-blue);
}

.ps-edit-btn.ps-with-bg {
    color: white;
    opacity: 0.8;
    background: rgba(0,0,0,0.4);
    border-radius: 50%;
    backdrop-filter: blur(4px);
    -webkit-backdrop-filter: blur(4px);
}

.ps-edit-btn.ps-with-bg:active {
    opacity: 1;
    background: rgba(0,0,0,0.6);
    color: white;
}

.ps-card-actions {
    position: absolute;
    top: 10px;
    right: 12px;
    display: flex;
    align-items: center;
    gap: 8px;
    z-index: 5;
}

.ps-edit-btn svg {
    width: 18px;
    height: 18px;
    fill: currentColor;
}

.ps-add-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    padding: 14px;
    border-radius: 14px;
    background: var(--accent-color, var(--vk-blue));
    color: white;
    font-size: 15px;
    font-weight: 600;
    cursor: pointer;
    transition: all 0.2s;
    user-select: none;
    margin-top: 4px;
}

.ps-add-btn:active {
    transform: scale(0.97);
    opacity: 0.85;
}

.ps-add-btn svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
}
/* Expand Buttons */
.label-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 8px;
}

.label-row label {
    margin-bottom: 0 !important;
}

.expand-btn {
    cursor: pointer;
    color: var(--vk-blue);
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 6px;
    margin: -6px;
    border-radius: 50%;
    transition: background-color 0.2s;
}

.expand-btn:hover {
    background-color: rgba(81, 129, 184, 0.1);
}

.expand-btn svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
}
/* ── Sub-view Slide Animations ── */
.ps-fwd-enter-active {
    transition: transform 0.15s cubic-bezier(0.2, 0.8, 0.2, 1), opacity 0.12s ease;
}
.ps-fwd-leave-active {
    transition: transform 0.1s cubic-bezier(0.4, 0, 1, 1), opacity 0.1s ease;
}
.ps-fwd-enter-from {
    transform: translateX(30px);
    opacity: 0;
}
.ps-fwd-leave-to {
    transform: translateX(-20px);
    opacity: 0;
}

.ps-back-enter-active {
    transition: transform 0.15s cubic-bezier(0.2, 0.8, 0.2, 1), opacity 0.12s ease;
}
.ps-back-leave-active {
    transition: transform 0.1s cubic-bezier(0.4, 0, 1, 1), opacity 0.1s ease;
}
.ps-back-enter-from {
    transform: translateX(-30px);
    opacity: 0;
}
.ps-back-leave-to {
    transform: translateX(20px);
    opacity: 0;
}
</style>
