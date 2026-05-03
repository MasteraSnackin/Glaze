<script setup>
import { ref, watch, nextTick, onMounted, onBeforeUnmount } from 'vue';
import { Capacitor } from '@capacitor/core';
import DesktopPopup from '@/components/ui/DesktopPopup.vue';
import { hideKeyboard, showKeyboard, applyKeyboardOverlap, onKeyboardShow, onKeyboardHide } from '@/core/services/keyboardHandler.js';
import { translations, t } from '@/utils/i18n.js';
import HelpTip from '@/components/ui/HelpTip.vue';
import { bottomSheetState } from '@/core/states/bottomSheetState.js';
import { getLastClickPosition } from '@/core/states/desktopPopupState.js';
import { sidebarState, setSidebarOccupied } from '@/core/states/sidebarState.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { publishAppEvent } from '@/core/events/eventHub.js';
import { attachLongPress } from '@/core/services/ui.js';

const vLongPress = {
    mounted: (el, binding) => {
        if (binding.value) {
            const check = attachLongPress(el, binding.value);
            el._checkLongPress = check;
        }
    }
};

const handleCardClick = (event, item) => {
    if (event.currentTarget._checkLongPress && event.currentTarget._checkLongPress()) return;
    if (item.onClick) item.onClick(event);
};
const props = defineProps({
    visible: Boolean,
    locked: { type: Boolean, default: false }, // when true, prevents backdrop/drag dismiss
    title: String,
    helpTip: String,
    content: [String, Object], // HTML string or DOM node
    items: Array, // [{ label, icon, iconColor, onClick, isDestructive, actions: [{icon, color, onClick}] }]
    headerAction: Object, // { icon, onClick }
    bigInfo: Object, // { icon, description, buttonText, buttonDisabled, onButtonClick, glossaryChip: { term, label } }
    sessionItems: Array, // [{ title, count, time, preview, isActive, onClick, onDelete }]
    cardItems: Array, // [{ label, sublabel, icon, onClick }]
    input: Object, // { placeholder, value, confirmLabel, onConfirm }
    isSolid: Boolean,
    sidebarMode: { type: Boolean, default: false },
    popupOnDesktop: { type: Boolean, default: false },
    popupWidth: { type: Number, default: 300 },
    estimatedHeight: { type: Number, default: 0 }
});

const emit = defineEmits(['close']);

const domContent = ref(null);
const inputValue = ref('');
const inputRef = ref(null);
const isLocalKeyboardOpen = ref(false);

const isDesktopPopup = ref(false);
const popupCoordinates = ref({ x: 0, y: 0 });

function openGlossaryChip(term) {
    emit('close');
    nextTick(() => {
        publishAppEvent(APP_EVENTS.nav.openGlossary, { term });
    });
}

function close() {
    // Hide keyboard and blur active element before closing
    if (isLocalKeyboardOpen.value) {
        isLocalKeyboardOpen.value = false;
        const active = document.activeElement;
        if (active && (domContent.value?.contains(active) || inputRef.value === active)) {
            active.blur();
        }
        if (Capacitor.isNativePlatform()) {
            hideKeyboard();
        }
    }
    emit('close');
}

// Sync with sidebar state to ensure only one sheet/view is active at a time
let _historyPushed = false;
watch(() => props.visible, (newVal) => {
    if (newVal) {
        if (props.popupOnDesktop && typeof window !== 'undefined' && window.innerWidth >= 768) {
            isDesktopPopup.value = true;
            const pos = getLastClickPosition();
            popupCoordinates.value = { x: pos.x, y: pos.y };
        } else {
            isDesktopPopup.value = false;
        }
    }

    if (newVal && props.sidebarMode) {
        setSidebarOccupied(true, 'bottom_sheet');
    } else if (!newVal && props.sidebarMode && sidebarState.activeSheetId === 'bottom_sheet') {
        setSidebarOccupied(false);
    }
    
    if (!newVal && isLocalKeyboardOpen.value) {
        isLocalKeyboardOpen.value = false;
    }

    // Support browser back gesture/button for PWA/Web
    const isDesktopEnv = window.innerWidth >= 768;
    if (newVal && !isDesktopEnv) {
        window.history.pushState({ type: 'bottom_sheet' }, '');
        _historyPushed = true;
    } else if (!newVal && _historyPushed) {
        if (window.history.state?.type === 'bottom_sheet') {
            window.history.back();
        }
        _historyPushed = false;
    }
}, { immediate: true });

watch(() => sidebarState.activeSheetId, (newId) => {
    if (props.visible && props.sidebarMode && newId && newId !== 'bottom_sheet') {
        close();
    }
});

watch(() => props.input, (newVal) => {
    if (newVal) {
        inputValue.value = newVal.value || '';
        
        if (Capacitor.isNativePlatform()) {
            isLocalKeyboardOpen.value = true;
            // Pre-emptively set overlap if it's 0 to avoid delay in sheet raising
            applyKeyboardOverlap();
        }

        nextTick(() => {
            if (inputRef.value) {
                inputRef.value.focus({ preventScroll: true });
                if (Capacitor.isNativePlatform()) {
                    showKeyboard();
                }
            }
        });
    }
});

function onInputConfirm() {
    if (props.input && props.input.onConfirm && inputValue.value.trim()) {
        props.input.onConfirm(inputValue.value.trim());
    }
}

// Handle DOM elements passed as content (legacy support)
watch(() => [domContent.value, props.content], () => {
    if (domContent.value && props.content && typeof props.content !== 'string') {
        domContent.value.innerHTML = '';
        if (props.content instanceof HTMLElement || props.content instanceof DocumentFragment) {
            domContent.value.appendChild(props.content);
        }
    }
}, { immediate: true });

// Drag to close logic
const startY = ref(0);
const currentDragY = ref(0);
const isDragging = ref(false);

function onHandleTouchStart(e) {
    startY.value = e.touches[0].clientY;
    isDragging.value = true;
}

function onHandleTouchMove(e) {
    if (!isDragging.value) return;
    const delta = e.touches[0].clientY - startY.value;
    if (delta > 0) {
        currentDragY.value = delta;
    }
}

function onHandleTouchEnd() {
    isDragging.value = false;
    if (!props.locked && currentDragY.value > 80) {
        close();
    }
    currentDragY.value = 0;
}

function checkFocus() {
    const active = document.activeElement;
    if (!active) return;

    const isInside = domContent.value?.contains(active) || inputRef.value === active || active?.closest('.bottom-sheet-content');

    if (isInside) {
        // Only trigger if it's a text-entry field that actually opens a virtual keyboard
        const tagName = active.tagName;
        let isTextEntry = false;
        
        if (tagName === 'TEXTAREA') {
            isTextEntry = true;
        } else if (tagName === 'INPUT') {
            const textTypes = ['text', 'password', 'email', 'number', 'tel', 'url', 'search', 'date', 'datetime-local', 'month', 'time', 'week'];
            isTextEntry = textTypes.includes(active.type.toLowerCase());
        } else if (active.isContentEditable) {
            isTextEntry = true;
        }

        // Only apply keyboard logic on native mobile platforms
        if (isTextEntry && Capacitor.isNativePlatform()) {
            isLocalKeyboardOpen.value = true;
            applyKeyboardOverlap();
            showKeyboard();
        } else {
            // On desktop or non-text fields: never treat as keyboard open
            isLocalKeyboardOpen.value = false;
        }
    } else {
        isLocalKeyboardOpen.value = false;
    }
}

const kbListeners = [];

function onSheetFocusIn() {
    checkFocus();
    // Reset viewport pan to prevent double offset (CSS padding + browser pan)
    if (isLocalKeyboardOpen.value) {
        window.scrollTo(0, 0);
    }
}

onMounted(async () => {
    // Listen to focus to instantly apply padding and prevent Android visualViewport pan
    document.addEventListener('focusin', onSheetFocusIn);
    document.addEventListener('focusout', () => { setTimeout(checkFocus, 50); });

    if (Capacitor.isNativePlatform()) {
        kbListeners.push(await onKeyboardShow((info) => {
            checkFocus();
            // Height might not be set yet if it's the first time
            if (info && info.keyboardHeight) {
                applyKeyboardOverlap(info.keyboardHeight);
            }
        }));
        kbListeners.push(await onKeyboardHide(() => { 
            isLocalKeyboardOpen.value = false; 
        }));
    }
});

onBeforeUnmount(() => {
    if (props.sidebarMode && sidebarState.activeSheetId === 'bottom_sheet') {
        setSidebarOccupied(false);
    }
    document.removeEventListener('focusin', onSheetFocusIn);
    kbListeners.forEach(l => l.remove());
});
</script>

<template>
    <!-- Desktop Popup Window Override -->
    <DesktopPopup
        v-if="isDesktopPopup"
        :visible="visible"
        :title="title"
        :headerAction="headerAction"
        :bigInfo="bigInfo"
        :items="items"
        :sessionItems="sessionItems"
        :cardItems="cardItems"
        :input="input"
        :content="content"
        :isTriggered="true"
        :x="popupCoordinates.x"
        :y="popupCoordinates.y"
        :width="popupWidth"
        :estimatedHeight="estimatedHeight"
        @close="close"
    >
        <!-- Vue Slot Content -->
        <slot></slot>
    </DesktopPopup>

    <!-- Regular Bottom Sheet -->
    <Teleport v-else :to="sidebarMode ? '#desktop-sidebar-content' : 'body'">
        <Transition name="bottom-sheet">
            <div v-if="visible" class="visible" :class="{ 'modal-overlay': !sidebarMode, 'bottom-sheet-sidebar-wrapper': sidebarMode }">
                <div v-if="!sidebarMode" class="modal-backdrop" @click="locked ? undefined : close()"></div>
                <div class="bottom-sheet-content" @click.stop 
                     :style="!sidebarMode && isDragging ? { transform: `translateY(${currentDragY}px)` } : ''"
                     :class="{ 'is-dragging': isDragging, 'keyboard-open': isLocalKeyboardOpen, 'is-solid': props.isSolid || bottomSheetState.isSolid, 'is-sidebar': sidebarMode }">
                
                <div class="sheet-header-area">
                    <div v-if="!sidebarMode" class="sheet-handle-bar"
                         @touchstart="onHandleTouchStart"
                         @touchmove.prevent="onHandleTouchMove"
                         @touchend="onHandleTouchEnd"
                    ></div>

                    <div class="sheet-header" v-if="title || headerAction">
                        <div class="sheet-title">
                            <div v-if="sidebarMode" class="sheet-back-btn" @click="close">
                                <svg viewBox="0 0 24 24"><path d="M20 11H7.83l5.59-5.59L12 4l-8 8 8 8 1.41-1.41L7.83 13H20v-2z"/></svg>
                            </div>
                            <div class="sc-header-title">{{ title }}</div>
                            <HelpTip v-if="helpTip" :term="helpTip" />
                        </div>
                        <div class="sheet-action-btn" v-if="headerAction" @click="headerAction.onClick" v-html="headerAction.icon"></div>
                    </div>
                </div>
                
                <div class="sheet-scroll-container" :class="{ 'has-header': title || headerAction }">
                    <!-- Custom Content (HTML) -->
                    <div v-if="typeof content === 'string'" class="sheet-custom-content" v-html="content"></div>
                    <div v-else-if="content" class="sheet-custom-content" ref="domContent"></div>
                    
                    <!-- Vue Slot Content -->
                    <slot></slot>

                    <!-- Big Info Sheet -->
                    <div v-if="bigInfo" class="sheet-big-info">
                        <div class="big-info-icon" v-html="bigInfo.icon"></div>
                        <div class="big-info-desc">
{{ bigInfo.description }}
</div>
                        <div v-if="bigInfo.glossaryChip" class="big-info-chip-line">
{{ bigInfo.glossaryChip.hint }} <button class="big-info-chip" @click.stop="openGlossaryChip(bigInfo.glossaryChip.term)">
{{ bigInfo.glossaryChip.label }}
</button>
</div>
                        <div v-if="bigInfo.buttonText" class="sheet-big-info-btn" :class="{ disabled: bigInfo.buttonDisabled }" @click="!bigInfo.buttonDisabled && bigInfo.onButtonClick()">
{{ bigInfo.buttonText }}
</div>
                    </div>

                    <!-- List Items -->
                    <div v-if="items && items.length" class="sheet-list">
                        <div :class="{ 'sheet-group-card': !sidebarMode }">
                            <div v-for="(item, index) in items" :key="index" 
                                 :class="[sidebarMode ? 'sheet-item-card' : 'sheet-item', { 'centered': item.centered, 'has-hint': item.hint }]" 
                                 @click="item.onClick">
                                <div class="sheet-item-icon" v-if="item.icon" v-html="item.icon" :style="{ color: item.iconColor }"></div>
                                <div class="sheet-item-content">
                                    <span :class="{ 'text-destructive': item.isDestructive }">{{ item.label }}</span>
                                    <span v-if="item.hint" class="sheet-item-hint">{{ item.hint }}</span>
                                </div>
                                
                                <!-- Item Actions (Buttons on the right) -->
                                <div class="sheet-item-actions" v-if="item.actions && item.actions.length">
                                    <div v-for="(action, aIndex) in item.actions" :key="aIndex" 
                                            class="sheet-item-action-btn"
                                            @click.stop="action.onClick"
                                            v-html="action.icon"
                                            :style="{ color: action.color }">
                                    </div>
                                </div>
                            </div>
                        </div>
                    </div>

                    <!-- Session Items (Custom Layout) -->
                    <div v-if="sessionItems && sessionItems.length" class="sheet-list">
                        <div :class="{ 'sheet-group-card': !sidebarMode }">
                            <div v-for="(item, index) in sessionItems" :key="index" :class="sidebarMode ? 'sheet-item-card' : 'sheet-item'" class="session-item" @click="item.onClick">
                                <div class="session-content">
                                    <div class="session-title">
                                        {{ item.title }} <span class="session-count"><svg viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2z"/></svg>{{ item.count }}</span>
                                    </div>
                                    <div class="session-preview">
                                        {{ item.preview }}
                                    </div>
                                </div>
                                <div class="session-right">
                                    <div class="session-meta-right">
                                        <div class="session-time">
                                            {{ item.time }}
                                        </div>
                                        <div v-if="item.isActive" class="active-dot"></div>
                                    </div>
                                    <div class="session-delete-btn" @click.stop="item.onDelete">
                                        <svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>
                                    </div>
                                </div>
                            </div>
                        </div>
                    </div>

                    <!-- Card Items (Triggered style) -->
                    <div v-if="cardItems && cardItems.length" class="sheet-card-list">
                        <div v-for="(item, index) in cardItems" :key="index" 
                             class="triggered-item-card" 
                             :class="{ 'has-bg': item.image, 'is-active': item.isActive }"
                             :style="item.image ? { backgroundImage: `url(${item.image})` } : {}"
                             v-long-press="item.onLongPress"
                             @click="handleCardClick($event, item)"
                             @contextmenu.prevent="item.onLongPress ? item.onLongPress() : undefined">
                            <div class="card-overlay" v-if="item.image"></div>
                            <div v-if="item.isFeatured" class="featured-badge">
                                {{ t('label_featured_preset') || 'FEATURED PRESET' }}
                            </div>
                            <div class="item-icon" v-if="item.icon">
                                <div v-if="item.icon.startsWith('<')" v-html="item.icon"></div>
                                <svg v-else viewBox="0 0 24 24"><path :d="item.icon"/></svg>
                            </div>
                            <div class="item-info">
                                <div class="item-label-row">
                                    <div class="item-label" :class="{ 'with-bg': item.image }">
{{ item.label }}
</div>
                                    <div v-if="item.badge" class="item-badge" :class="{ 'with-bg': item.image }">
                                        <svg viewBox="0 0 24 24" class="badge-icon"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>
                                        {{ item.badge }}
                                    </div>
                                </div>
                                <div v-if="item.sublabel" class="item-sublabel" :class="{ 'with-bg': item.image }">
{{ item.sublabel }}
</div>
                            </div>
                            
                            <!-- Item Actions (Buttons on the right) -->
                            <div class="sheet-item-actions" :class="{ 'card-actions-right': item.actions && item.actions.length }" v-if="item.actions && item.actions.length">
                                <div v-for="(action, aIndex) in item.actions" :key="aIndex" 
                                     class="sheet-item-action-btn card-action-btn"
                                     :class="{ 'with-bg': item.image }"
                                     @click.stop="action.onClick"
                                     v-html="action.icon"
                                     :style="{ color: action.color }">
                                </div>
                            </div>
                        </div>
                    </div>

                    <!-- Input Sheet -->
                    <div v-if="input" class="sheet-input-container">
                        <div class="settings-item">
                            <input 
                                ref="inputRef"
                                type="text" 
                                v-model="inputValue" 
                                :placeholder="input.placeholder"
                                @keydown.enter="onInputConfirm"
                            >
                        </div>
                        <div class="settings-padding" style="padding-top: 0;">
                            <div class="btn-save" style="margin-top: 10px;" @click="onInputConfirm">
{{ input.confirmLabel || 'Save' }}
</div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    </Transition>
</Teleport>
</template>

<style scoped>
.sheet-big-info-btn.disabled {
    opacity: 0.45;
    cursor: not-allowed;
    pointer-events: none;
}

.sheet-item.centered {
    justify-content: center;
}
.sheet-item.centered .sheet-item-content {
    flex: 0 0 auto;
}
</style>

<style>
/* Base Styles moved from components.css */
.modal-overlay {
    position: fixed;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    background-color: transparent !important;
    z-index: 20000;
    display: flex;
    justify-content: center;
    align-items: flex-end;
    opacity: 1;
    pointer-events: auto;
}

.bottom-sheet-content {
    width: 100%;
    max-width: 600px;
    background-color: var(--ui-bg);
    border-top-left-radius: 16px;
    border-top-right-radius: 16px;
    padding-bottom: calc(10px + var(--sab));
    transform: translateY(0);
    max-height: 95vh;
    box-shadow: 0 -5px 15px rgba(0,0,0,0.1);
    display: flex;
    flex-direction: column;
    position: relative;
}

.sheet-header-area {
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    flex-shrink: 0;
    touch-action: none;
    z-index: 10;
    padding-bottom: 12px;
    pointer-events: none;
}

.sheet-header-area::before {
    content: '';
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    background: linear-gradient(to bottom, 
        rgba(var(--ui-bg-rgb), 0.85) 0%, 
        rgba(var(--ui-bg-rgb), 0) 100%
    );
    backdrop-filter: blur(16px);
    -webkit-backdrop-filter: blur(16px);
    mask-image: linear-gradient(to bottom, 
        black 0%, 
        black 40%, 
        transparent 100%
    );
    -webkit-mask-image: linear-gradient(to bottom, 
        black 0%, 
        black 40%, 
        transparent 100%
    );
    z-index: -1;
    border-top-left-radius: 20px;
    border-top-right-radius: 20px;
}

.sheet-header-area > * {
    pointer-events: auto;
}

.sheet-handle-bar {
    width: 100%;
    height: 24px;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    cursor: grab;
    touch-action: none;
}

.sheet-handle-bar::after {
    content: '';
    width: 32px;
    height: 4px;
    background-color: #e0e0e0;
    border-radius: 2px;
}

.sheet-scroll-container {
    overflow-y: auto;
    max-height: 70vh;
    width: 100%;
    overscroll-behavior: contain;
    padding-top: 24px;
}

.sheet-scroll-container::-webkit-scrollbar-track {
    margin-top: 24px;
}

.sheet-scroll-container.has-header {
    padding-top: 72px;
}

.sheet-scroll-container.has-header::-webkit-scrollbar-track {
    margin-top: 72px;
}

.bottom-sheet-content.is-sidebar .sheet-scroll-container {
    padding-top: 0;
}

.bottom-sheet-content.is-sidebar .sheet-scroll-container::-webkit-scrollbar-track {
    margin-top: 0;
}

.bottom-sheet-content.is-sidebar .sheet-scroll-container.has-header {
    padding-top: 48px;
}

.bottom-sheet-content.is-sidebar .sheet-scroll-container.has-header::-webkit-scrollbar-track {
    margin-top: 48px;
}

.sheet-header {
    padding: 8px 20px 16px;
    display: flex;
    justify-content: space-between;
    align-items: center;
}

.sheet-title {
    font-size: 18px;
    font-weight: 500;
    display: flex;
    align-items: center;
    gap: 8px;
}

.sheet-action-btn {
    font-size: 24px;
    color: var(--vk-blue);
    cursor: pointer;
    line-height: 1;
}

.sheet-action-btn svg {
    width: 24px;
    height: 24px;
    fill: currentColor;
}

.sheet-list {
    overflow-y: auto;
    padding: 8px 16px 24px 16px;
}

.sheet-group-card {
    background: rgba(128, 128, 128, 0.12);
    border: 1px solid rgba(128, 128, 128, 0.2);
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.05);
    border-radius: 16px;
    overflow: clip;
}

.sheet-item {
    position: relative;
    padding: 14px 16px;
    display: flex;
    align-items: center;
    cursor: pointer;
}

.sheet-item:active {
    background-color: var(--bg-gray, rgba(128, 128, 128, 0.1));
}

.sheet-item-card {
    position: relative;
    padding: 14px 16px;
    display: flex;
    align-items: center;
    cursor: pointer;
    background: rgba(128, 128, 128, 0.12);
    border: 1px solid rgba(128, 128, 128, 0.2);
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.05);
    border-radius: 16px;
    margin-bottom: 10px;
    transition: background-color 0.2s;
}

.sheet-item-card:active {
    background-color: var(--bg-gray, rgba(128, 128, 128, 0.2));
}

.sheet-item-icon {
    width: 24px;
    height: 24px;
    margin-right: 16px;
    fill: var(--text-gray);
    display: flex;
    align-items: center;
    justify-content: center;
}

.sheet-item-icon svg {
    width: 24px;
    height: 24px;
}

.sheet-item-content {
    flex: 1;
    font-size: 16px;
    color: var(--text-black);
    word-break: break-word;
    white-space: pre-wrap;
    display: flex;
    flex-direction: column;
    gap: 2px;
}

.sheet-item-hint {
    font-size: 12px;
    color: var(--text-gray);
    font-weight: normal;
    white-space: normal;
    line-height: 1.3;
}

.sheet-item.has-hint {
    align-items: center;
}

.sheet-item-remove, .sheet-item-edit {
    padding: 8px;
    color: var(--text-gray);
    cursor: pointer;
}

.sheet-item-remove svg, .sheet-item-edit svg {
    width: 24px;
    height: 24px;
    fill: currentColor;
}

.sheet-item-actions {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-right: -5px;
}

.sheet-item-action-btn {
    padding: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 50%;
    cursor: pointer;
}

.sheet-item-action-btn svg {
    width: 24px;
    height: 24px;
    fill: currentColor;
}

.sheet-item-action-btn:active {
    background-color: rgba(0,0,0,0.05);
}

.text-destructive {
    color: #ff4444;
}

.sheet-big-info {
    display: flex;
    flex-direction: column;
    align-items: center;
    padding: 20px 20px 10px;
    text-align: center;
}

.big-info-icon {
    width: 64px;
    height: 64px;
    margin-bottom: 16px;
    color: var(--text-gray);
    opacity: 0.5;
}

.big-info-desc {
    font-size: 16px;
    color: var(--text-black);
    margin-bottom: 24px;
    line-height: 1.5;
    word-break: break-word;
    white-space: pre-wrap;
}

.big-info-chip-line {
    font-size: 14px;
    color: var(--text-gray);
    margin-bottom: 18px;
    line-height: 1.5;
}

.big-info-chip {
    display: inline-flex;
    align-items: center;
    padding: 2px 10px;
    border-radius: 6px;
    background: rgba(var(--vk-blue-rgb), 0.12);
    color: var(--vk-blue);
    font-size: 13px;
    font-weight: 600;
    font-family: inherit;
    border: 1px solid rgba(var(--vk-blue-rgb), 0.2);
    cursor: pointer;
    vertical-align: baseline;
    transition: background 0.15s, opacity 0.15s;
    -webkit-tap-highlight-color: transparent;
}
.big-info-chip:active {
    background: rgba(var(--vk-blue-rgb), 0.22);
    opacity: 0.8;
}

.sheet-big-info-btn {
    width: 100%;
    padding: 12px;
    background-color: var(--vk-blue);
    color: white;
    border-radius: 8px;
    font-weight: 500;
    cursor: pointer;
    text-align: center;
}

.session-item {
    padding: 12px 16px;
    display: flex;
    align-items: center;
    justify-content: space-between;
}
.session-content {
    flex: 1;
    overflow: hidden;
    margin-right: 12px;
}
.session-title {
    font-weight: 600;
    font-size: 16px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    margin-bottom: 4px;
    display: flex;
    align-items: center;
}
.session-count { 
    color: var(--text-gray); 
    font-size: 0.85em; 
    font-weight: normal; 
    display: flex;
    align-items: center;
    gap: 4px;
    margin-left: 8px;
}
.session-count svg { width: 14px; height: 14px; fill: currentColor; opacity: 0.7; }
.session-meta-right { display: flex; align-items: center; gap: 8px; }
.session-time { font-size: 0.85em; color: var(--text-gray); white-space: nowrap; }
.session-preview { font-size: 0.9em; color: var(--text-gray); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; opacity: 0.8; }
.session-right { display: flex; flex-direction: column; align-items: flex-end; gap: 4px; min-width: fit-content; }
.active-dot {
    width: 8px; height: 8px; background-color: var(--vk-blue); border-radius: 50%;
    flex-shrink: 0;
}
.session-delete-btn {
    color: #ff4444; 
    padding: 4px; 
    cursor: pointer; 
    display: flex; 
    align-items: center; 
    justify-content: center;
    opacity: 0.7; 
    transition: opacity 0.2s;
}
.session-delete-btn:active { opacity: 1; }
.session-delete-btn svg { 
    width: 20px; 
    height: 20px; 
    fill: currentColor; 
}

/* Fix for blur during animation: separate backdrop opacity from content */
.modal-overlay {
    background-color: transparent !important;
    opacity: 1 !important;
    z-index: 20000 !important;
}

.bottom-sheet-enter-active,
.bottom-sheet-leave-active {
    transition: opacity 0.3s ease;
}
.bottom-sheet-enter-active .modal-backdrop,
.bottom-sheet-leave-active .modal-backdrop {
    transition: opacity 0.3s ease;
}
.bottom-sheet-enter-active .bottom-sheet-content,
.bottom-sheet-leave-active .bottom-sheet-content {
    transition: background-color 0.3s ease, transform 0.3s cubic-bezier(0.2, 0.8, 0.2, 1);
}

.bottom-sheet-enter-from,
.bottom-sheet-leave-to {
    opacity: 0;
}
.bottom-sheet-enter-from .bottom-sheet-content:not(.is-sidebar),
.bottom-sheet-leave-to .bottom-sheet-content:not(.is-sidebar) {
    transform: translateY(100%);
}
.bottom-sheet-enter-from .bottom-sheet-content.is-sidebar,
.bottom-sheet-leave-to .bottom-sheet-content.is-sidebar {
    transform: translateX(100%) !important;
}

.modal-backdrop {
    position: absolute;
    top: 0; left: 0; width: 100%; height: 100%;
    background-color: rgba(0,0,0,0.5);
    opacity: 1;
}

.bottom-sheet-content {
    z-index: 2;
    background-color: rgba(var(--theme-ui-color-rgb, 30, 30, 30), var(--element-opacity, 0.8)) !important;
    backdrop-filter: blur(var(--element-blur, 20px));
    -webkit-backdrop-filter: blur(var(--element-blur, 20px));
    background-image: url("data:image/svg+xml,%3Csvg width='200' height='200' viewBox='0 0 200 200' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noiseFilter'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.8' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noiseFilter)' opacity='0.03'/%3E%3C/svg%3E");
    border-top: 1px solid rgba(255, 255, 255, 0.1);
    box-shadow: 0 -5px 20px rgba(0,0,0,0.3);
    transition: background-color 0.3s ease, transform 0.3s cubic-bezier(0.2, 0.8, 0.2, 1);
    border-top-left-radius: 20px;
    border-top-right-radius: 20px;
}
.bottom-sheet-content.is-solid {
    background-color: var(--app-bg) !important;
    backdrop-filter: none !important;
    -webkit-backdrop-filter: none !important;
    background-image: none !important;
}

.bottom-sheet-sidebar-wrapper {
    position: absolute;
    inset: 0;
    background: transparent;
    flex: none;
    min-height: 0;
    width: 100%;
    flex-direction: column;
    align-items: stretch;
}

.bottom-sheet-content.is-sidebar {
    height: 100% !important;
    max-height: none !important;
    border-radius: 0 !important;
    border: none !important;
    box-shadow: none !important;
    transform: translateX(0) !important;
    background-color: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8)) !important;
    backdrop-filter: none !important;
    -webkit-backdrop-filter: none !important;
    padding-bottom: 20px !important;
    background-image: none !important;
}

.bottom-sheet-content.is-sidebar .sheet-scroll-container {
    max-height: none !important;
    flex: 1;
}

.bottom-sheet-content.is-sidebar .sheet-header {
    padding: 16px 16px 16px;
}

.sheet-back-btn {
    width: 32px;
    height: 32px;
    display: flex;
    align-items: center;
    justify-content: center;
    margin-right: 8px;
    border-radius: 50%;
    cursor: pointer;
    color: var(--text-gray);
    transition: background 0.2s;
}

.sheet-back-btn:active {
    background: rgba(255, 255, 255, 0.1);
}

.sheet-back-btn svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
}

.bottom-sheet-content.keyboard-open {
    padding-bottom: calc(var(--keyboard-overlap, 0px) + 10px + var(--sab, 0px));
    max-height: 95vh;
}

.bottom-sheet-content.is-dragging {
    transition: none;
}



/* Card Items (Triggered style) */
.sheet-card-list {
    padding: 8px 16px 20px;
    display: flex;
    flex-direction: column;
    gap: 10px;
}

.triggered-item-card {
    display: flex;
    align-items: center;
    padding: 10px 12px;
    background: var(--menu-group-bg, rgba(0, 0, 0, 0.02));
    border: 1px solid #555555;
    border-radius: 12px;
    gap: 12px;
    cursor: pointer;
    transition: background 0.2s, transform 0.1s;
    position: relative;
    overflow: hidden;
    background-size: cover;
    background-position: center center;
}

.triggered-item-card.has-bg {
    min-height: 160px; /* Provide more space for the background image to show */
    align-items: flex-end; /* Push text to the bottom if desired, or keep center */
    padding: 12px 16px;
}

.card-overlay {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    background: linear-gradient(to top, rgba(0,0,0,0.8) 0%, rgba(0,0,0,0.3) 100%);
    z-index: 1;
}

.triggered-item-card > *:not(.card-overlay):not(.featured-badge) {
    position: relative;
    z-index: 2;
}

.triggered-item-card:active {
    background-color: rgba(var(--vk-blue-rgb), 0.1);
    transform: scale(0.98);
}

.triggered-item-card.is-active {
    background: rgba(var(--vk-blue-rgb), 0.2);
    border-color: rgba(var(--vk-blue-rgb), 0.4);
}

.triggered-item-card.has-bg:active .card-overlay {
    background: linear-gradient(to top, rgba(0,0,0,0.9) 0%, rgba(0,0,0,0.4) 100%);
}

.triggered-item-card .item-icon {
    width: 40px;
    height: 40px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(var(--vk-blue-rgb), 0.1);
    color: var(--vk-blue);
    border-radius: 50%;
    flex-shrink: 0;
    overflow: hidden;
    box-shadow: 0 2px 5px rgba(0,0,0,0.1);
}

.triggered-item-card.has-bg .item-icon {
    display: none; /* Hide standard icon if we have a full background, or keep it as an overlay badge */
}

.triggered-item-card .item-icon svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
}

.triggered-item-card .item-icon img,
.triggered-item-card .item-icon > div {
    width: 100%;
    height: 100%;
    object-fit: cover;
    border-radius: inherit;
    display: flex;
    align-items: center;
    justify-content: center;
}

.triggered-item-card .item-info {
    display: flex;
    flex-direction: column;
    min-width: 0;
    flex: 1;
}

.card-actions-right {
    margin-left: auto;
}

.triggered-item-card .item-label {
    font-size: 15px;
    font-weight: 600;
    color: var(--text-black);
    text-shadow: none; /* Reset for non-bg */
}

.item-label-row {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
    margin-bottom: 2px;
}

.item-badge {
    display: flex;
    align-items: center;
    gap: 4px;
    font-size: 10px;
    font-weight: 700;
    padding: 2px 8px;
    border-radius: 12px;
    background: rgba(0, 0, 0, 0.05);
    color: var(--text-gray);
    flex-shrink: 0;
}

.item-badge.with-bg {
    background: rgba(255, 255, 255, 0.2);
    color: white;
    backdrop-filter: blur(4px);
    -webkit-backdrop-filter: blur(4px);
    border: 1px solid rgba(255, 255, 255, 0.1);
}

.badge-icon {
    width: 12px;
    height: 12px;
    fill: currentColor;
    opacity: 0.7;
}

.triggered-item-card .item-label.with-bg {
    color: #ffffff;
    text-shadow: 0 1px 3px rgba(0,0,0,0.8);
    font-size: 16px;
}

.triggered-item-card .item-sublabel {
    font-size: 12px;
    color: var(--text-gray);
    display: -webkit-box;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
}

.triggered-item-card .item-sublabel.with-bg {
    color: rgba(255,255,255,0.7);
    text-shadow: 0 1px 2px rgba(0,0,0,0.8);
}

.featured-badge {
    position: absolute;
    top: 10px;
    left: 12px;
    background: transparent;
    color: rgba(255, 255, 255, 0.5);
    font-size: 9px;
    font-weight: 700;
    padding: 0;
    border-radius: 0;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    z-index: 3;
    text-shadow: 0 1px 2px rgba(0,0,0,0.5);
}

.card-action-btn {
    padding: 6px;
}

.card-action-btn svg {
    width: 20px;
    height: 20px;
}

.card-action-btn.with-bg {
    color: white !important;
    background: rgba(0, 0, 0, 0.4);
    border-radius: 50%;
    backdrop-filter: blur(4px);
}

/* Sidebar Mode Styles */
.bottom-sheet-content.is-sidebar {
    height: 100% !important;
    max-height: none !important;
    border-radius: 0 !important;
    border: none !important;
    box-shadow: none !important;
    transform: none !important;
    background-color: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8)) !important;
    backdrop-filter: none !important;
    -webkit-backdrop-filter: none !important;
    background-image: none !important;
    position: relative !important;
    padding-top: 0 !important;
}

.bottom-sheet-content.is-sidebar .sheet-scroll-container {
    max-height: none !important;
    flex: 1;
    min-height: 0;
}

.bottom-sheet-content.is-sidebar .sheet-header {
    background: transparent !important;
    padding: 0 16px !important;
    min-height: 56px;
}

.sheet-back-btn {
    width: 40px;
    height: 40px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    margin-left: -8px;
    cursor: pointer;
    flex-shrink: 0;
    border-radius: 50%;
    color: var(--accent-color, var(--vk-blue));
    background-color: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 20px));
    -webkit-backdrop-filter: blur(var(--element-blur, 20px));
    border: 1px solid rgba(255, 255, 255, 0.1);
    box-shadow: 0 4px 15px rgba(0, 0, 0, 0.3);
    transition: all 0.2s ease;
}

.sheet-back-btn:active {
    opacity: 0.8;
}

.sheet-back-btn svg {
    width: 20px !important;
    height: 20px !important;
    fill: currentColor !important;
}

.bottom-sheet-sidebar-wrapper {
    position: absolute;
    inset: 0;
    z-index: 1000;
    flex: none;
    min-height: 0;
    display: flex;
    flex-direction: column;
    width: 100%;
    pointer-events: auto;
}
</style>


