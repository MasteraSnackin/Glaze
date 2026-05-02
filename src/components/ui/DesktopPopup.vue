<script setup>
import { watch, ref, computed, nextTick } from 'vue';
import { DesktopPopupState, closeDesktopPopup, getLastClickPosition } from '@/core/states/DesktopPopupState.js';

const props = defineProps({
    visible: { type: Boolean, default: undefined },
    title: { type: String, default: undefined },
    headerAction: { type: Object, default: undefined },
    bigInfo: { type: Object, default: undefined },
    items: { type: Array, default: undefined },
    isTriggered: { type: Boolean, default: undefined },
    x: { type: Number, default: undefined },
    y: { type: Number, default: undefined },
    width: { type: Number, default: undefined },
    sessionItems: { type: Array, default: undefined },
    cardItems: { type: Array, default: undefined },
    input: { type: Object, default: undefined },
    content: { type: [String, Object], default: undefined },
    estimatedHeight: { type: Number, default: 0 }
});

const emit = defineEmits(['close']);

// When props.visible is explicitly provided, this is a LOCAL popup (e.g. BottomSheet wrapper).
// Only fall back to global DesktopPopupState for truly global (singleton) usage.
const isGlobal = computed(() => props.visible === undefined);
const g = (propVal, stateKey) => propVal !== undefined ? propVal : (isGlobal.value ? DesktopPopupState.value[stateKey] : undefined);

const isVisible = computed(() => g(props.visible, 'visible'));
const resolvedTitle = computed(() => g(props.title, 'title'));
const resolvedHeaderAction = computed(() => g(props.headerAction, 'headerAction'));
const resolvedBigInfo = computed(() => g(props.bigInfo, 'bigInfo'));
const resolvedItems = computed(() => g(props.items, 'items'));
const resolvedSessionItems = computed(() => g(props.sessionItems, 'sessionItems'));
const resolvedCardItems = computed(() => g(props.cardItems, 'cardItems'));
const resolvedInput = computed(() => g(props.input, 'input'));
const resolvedContent = computed(() => g(props.content, 'content'));
const resolvedIsTriggered = computed(() => g(props.isTriggered, 'isTriggered'));
const resolvedX = computed(() => g(props.x, 'x'));
const resolvedY = computed(() => g(props.y, 'y'));

const dropdownStyle = ref({});
const PADDING = 12;
const MAX_VISIBLE_ITEMS = 12;

const domContent = ref(null);
watch(() => [domContent.value, resolvedContent.value], () => {
    if (domContent.value && resolvedContent.value && typeof resolvedContent.value !== 'string') {
        domContent.value.innerHTML = '';
        if (resolvedContent.value instanceof HTMLElement || resolvedContent.value instanceof DocumentFragment) {
            domContent.value.appendChild(resolvedContent.value);
        }
    }
}, { immediate: true });

const inputValue = ref('');
const inputRef = ref(null);

watch(resolvedInput, (newVal) => {
    if (newVal) {
        inputValue.value = newVal.value || '';
        nextTick(() => {
            if (inputRef.value) {
                inputRef.value.focus({ preventScroll: true });
            }
        });
    }
}, { immediate: true });

function onInputConfirm() {
    if (resolvedInput.value && resolvedInput.value.onConfirm && inputValue.value.trim()) {
        resolvedInput.value.onConfirm(inputValue.value.trim());
        handleClose();
    }
}

const handleCardClick = (event, item) => {
    if (event.currentTarget && event.currentTarget._checkLongPress && event.currentTarget._checkLongPress()) return;
    if (item.disabled) return;
    handleClose();
    if (item.onClick) item.onClick(event);
};

const handleSessionClick = (event, item) => {
    if (item.disabled) return;
    handleClose();
    if (item.onClick) item.onClick(event);
};

function recalcPosition() {
    const clickPos = getLastClickPosition();
    const x = resolvedX.value !== undefined ? resolvedX.value : clickPos.x;
    const y = resolvedY.value !== undefined ? resolvedY.value : clickPos.y;
    const title = resolvedTitle.value;
    const headerAction = resolvedHeaderAction.value;
    const bigInfo = resolvedBigInfo.value;
    const items = resolvedItems.value;
    const sessionItems = resolvedSessionItems.value;
    const cardItems = resolvedCardItems.value;
    const input = resolvedInput.value;
    const content = resolvedContent.value;
    const isTriggered = resolvedIsTriggered.value;
    
    // Explicit width prop > 'Triggered' design > Default design
    const width = props.width ? props.width : (isTriggered ? 280 : 220);

    let height = 16;

    if (title || headerAction) height += 32;
    if (bigInfo) height += 120;
    
    if (props.estimatedHeight) {
        height += props.estimatedHeight;
    }

    const visibleItems = items ? items.slice(0, MAX_VISIBLE_ITEMS) : [];
    
    let itemsH = 0;
    for (const item of visibleItems) {
        if (item.image) {
            itemsH += 80;
        } else {
            let itemH = isTriggered ? 48 : 38;
            if (item.sublabel) itemH += 15;
            if (item.hint) itemH += 15;
            itemsH += itemH;
        }
    }
    
    if (isTriggered && visibleItems.length > 0) {
        itemsH += (visibleItems.length - 1) * 8;
    }
    
    height += itemsH;

    if (sessionItems) height += Math.min(sessionItems.length, MAX_VISIBLE_ITEMS) * 58;
    if (cardItems) {
        const visibleCardItems = cardItems.slice(0, MAX_VISIBLE_ITEMS);
        for (const item of visibleCardItems) {
            height += item.image ? 80 : 42;
        }
    }
    if (input) height += 90;
    if (content) height += 100; // rough estimation

    let left = x;
    let top = y;

    const windowWidth = window.innerWidth;
    const windowHeight = window.innerHeight;

    let originX = 'left';
    let originY = 'top';

    if (left + width > windowWidth - PADDING) {
        left = x - width;
        originX = 'right';
        if (left < PADDING) {
            left = windowWidth - width - PADDING;
            if (left < PADDING) left = PADDING;
        }
    }

    if (top + height > windowHeight - PADDING) {
        top = y - height;
        originY = 'bottom';
        if (top < PADDING) {
            top = windowHeight - height - PADDING;
            if (top < PADDING) top = PADDING;
        }
    }

    const maxAllowedHeight = windowHeight - top - PADDING;

    dropdownStyle.value = {
        top: Math.round(top) + 'px',
        left: Math.round(left) + 'px',
        width: width + 'px',
        maxHeight: Math.max(100, maxAllowedHeight) + 'px', 
        transformOrigin: originX + ' ' + originY,
    };
}

function handleItemClick(item) {
    if (item.disabled) return;
    handleClose();
    item.onClick?.();
}

function handleClose() {
    if (props.visible !== undefined) {
        emit('close');
    } else {
        closeDesktopPopup();
    }
}

watch(isVisible, (val) => {
    if (val) recalcPosition();
}, { immediate: true });
</script>

<template>
    <Teleport to="body">
        <Transition name="dd-fade">
            <div
                v-if="isVisible"
                class="dd-overlay"
                @mousedown.self="handleClose"
                @contextmenu.prevent
            >
                <div class="dd-panel" :style="dropdownStyle" @click.stop :class="{ 'dd-panel--triggered': resolvedIsTriggered }">
                    <div v-if="resolvedTitle || resolvedHeaderAction" class="dd-header">
                        <div v-if="resolvedTitle" class="dd-title">
                            {{ resolvedTitle }}
                        </div>
                        <div v-if="resolvedHeaderAction" class="dd-header-action" @click="resolvedHeaderAction.onClick" v-html="resolvedHeaderAction.icon"></div>
                    </div>

                    <!-- Big Info Block -->
                    <div v-if="resolvedBigInfo" class="dd-big-info">
                        <div v-if="resolvedBigInfo.icon" class="dd-big-info-icon" v-html="resolvedBigInfo.icon"></div>
                        <div class="dd-big-info-label" v-if="resolvedBigInfo.label">
                            {{ resolvedBigInfo.label }}
                        </div>
                        <div class="dd-big-info-desc" v-if="resolvedBigInfo.description">
                            {{ resolvedBigInfo.description }}
                        </div>
                        <div v-if="resolvedBigInfo.buttonText" class="dd-big-info-btn" @click="resolvedBigInfo.onButtonClick">
                            {{ resolvedBigInfo.buttonText }}
                        </div>
                    </div>

                    <!-- Items & Slot -->
                    <div class="dd-items-scroll" :class="{ 'dd-items-scroll--triggered': resolvedIsTriggered }">
                        <!-- Custom Content (HTML) -->
                        <div v-if="typeof resolvedContent === 'string'" class="sheet-custom-content" v-html="resolvedContent" style="padding: 12px 14px;"></div>
                        <div v-else-if="resolvedContent" class="sheet-custom-content" ref="domContent" style="padding: 12px 14px;"></div>
                        
                        <slot></slot>

                        <!-- Session Items (Custom Layout) -->
                        <div v-if="resolvedSessionItems && resolvedSessionItems.length">
                            <div v-for="(item, index) in resolvedSessionItems" :key="index" class="dd-item" style="padding: 10px 12px; align-items: flex-start;" @click="handleSessionClick($event, item)">
                                <div class="dd-item-info" style="flex: 1;">
                                    <div style="font-weight: 600; font-size: 15px; margin-bottom: 2px;">{{ item.title }} <span style="font-weight: 400; opacity: 0.7; font-size: 13px;">({{ item.count }})</span></div>
                                    <div style="font-size: 12px; opacity: 0.7;">{{ item.preview }}</div>
                                </div>
                                <div style="display: flex; flex-direction: column; align-items: flex-end; font-size: 11px; opacity: 0.6; min-width: max-content;">
                                    <div>{{ item.time }}</div>
                                </div>
                            </div>
                        </div>
                
                        <!-- Card Items -->
                        <div v-if="resolvedCardItems && resolvedCardItems.length">
                            <div v-for="(item, index) in resolvedCardItems" :key="index" 
                                 class="dd-item" 
                                 :class="{ 'dd-item--has-bg': item.image }"
                                 :style="item.image ? { backgroundImage: 'url(' + item.image + ')' } : {}"
                                 @click="handleCardClick($event, item)">
                                <div v-if="item.image" class="dd-card-overlay"></div>
                                <span v-if="item.icon && !item.image" class="dd-item-icon" v-html="item.icon"></span>
                                <div class="dd-item-info">
                                    <span class="dd-item-label" :class="{ 'with-bg': item.image }">{{ item.label }}</span>
                                    <span v-if="item.sublabel" class="dd-item-sublabel" :class="{ 'with-bg': item.image }">{{ item.sublabel }}</span>
                                </div>
                            </div>
                        </div>

                        <!-- Input Sheet -->
                        <div v-if="resolvedInput" style="padding: 12px; display: flex; flex-direction: column; gap: 8px;">
                            <input type="text" ref="inputRef" v-model="inputValue" :placeholder="resolvedInput.placeholder" @keydown.enter="onInputConfirm" style="width: 100%; border-radius: 8px; border: 1px solid rgba(255,255,255,0.2); background: rgba(0,0,0,0.2); color: white; padding: 10px; font-size: 14px;">
                            <div class="dd-big-info-btn" @click="onInputConfirm">{{ resolvedInput.confirmLabel || 'Save' }}</div>
                        </div>

                        <div
                        v-for="(item, idx) in resolvedItems"
                        :key="idx"
                        class="dd-item"
                        :class="{
                            'dd-item--destructive': item.isDestructive,
                            'dd-item--active': item.isActive,
                            'dd-item--disabled': item.disabled,
                            'dd-item--triggered': resolvedIsTriggered,
                            'dd-item--has-bg': item.image
                        }"
                        :style="item.image ? { backgroundImage: 'url(' + item.image + ')' } : {}"
                        @click="handleItemClick(item)"
                    >
                        <div v-if="item.image" class="dd-card-overlay"></div>
                        <div v-if="item.isFeatured" class="dd-featured-badge">
                            FEATURED
                        </div>

                        <!-- Icon slot -->
                        <span
                            v-if="item.icon && !item.image"
                            class="dd-item-icon"
                            :style="item.iconColor ? { color: item.iconColor } : {}"
                            v-html="item.icon"
                        ></span>
                        
                        <div class="dd-item-info">
                            <span class="dd-item-label" :class="{ 'with-bg': item.image }">{{ item.label }}</span>
                            <span v-if="item.sublabel" class="dd-item-sublabel" :class="{ 'with-bg': item.image }">{{ item.sublabel }}</span>
                            <span v-if="item.hint" class="dd-item-hint">{{ item.hint }}</span>
                        </div>

                        <!-- Item Actions (Buttons on the right) -->
                        <div class="dd-item-actions" v-if="item.actions && item.actions.length">
                            <div v-for="(action, aIndex) in item.actions" :key="aIndex" 
                                 class="dd-item-action-btn"
                                 :class="{ 'with-bg': item.image }"
                                 @click.stop="action.onClick"
                                 v-html="action.icon"
                                 :style="{ color: action.color }">
                            </div>
                        </div>

                        <!-- Active checkmark -->
                        <svg v-if="item.isActive" class="dd-item-check" viewBox="0 0 24 24">
                            <path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/>
                        </svg>
                    </div>
                    </div>
                </div>
            </div>
        </Transition>
    </Teleport>
</template>

<style>
/* ── Desktop Dropdown ─────────────────────────────────────── */
.dd-overlay {
    position: fixed;
    inset: 0;
    z-index: 21000;
}

.dd-panel {
    position: fixed;
    z-index: 21001;
    /* menu-group style: mirror base.css:359 */
    background-color: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 12px));
    -webkit-backdrop-filter: blur(var(--element-blur, 12px));
    background-image: url("data:image/svg+xml,%3Csvg width='200' height='200' viewBox='0 0 200 200' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noiseFilter'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.8' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noiseFilter)' opacity='0.03'/%3E%3C/svg%3E");
    border: var(--border-width, 1px) solid var(--border-color, rgba(255, 255, 255, 0.1));
    border-radius: 20px;
    padding: 8px;
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.25);
    transition: background-color 0.3s ease, border-color 0.3s ease, width 0.3s ease;
    overflow: clip;
    max-height: calc(100vh - 24px);
    display: flex;
    flex-direction: column;
}

.dd-items-scroll {
    overflow-y: auto;
    overscroll-behavior: contain;
    flex: 1;
    min-height: 0;
}

.dd-items-scroll::-webkit-scrollbar {
    width: 4px;
}
.dd-items-scroll::-webkit-scrollbar-thumb {
    background: rgba(128, 128, 128, 0.3);
    border-radius: 2px;
}

.dd-items-scroll--triggered {
    display: flex;
    flex-direction: column;
}

.dd-panel--triggered {
    gap: 8px;
    display: flex;
    flex-direction: column;
}

.dd-title {
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.6px;
    text-transform: uppercase;
    color: var(--text-gray, rgba(200,200,200,0.6));
    padding: 6px 12px 4px;
}

.dd-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 2px;
}

.dd-header-action {
    width: 28px;
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    border-radius: 50%;
    color: var(--vk-blue, #5b9ae8);
    transition: background-color 0.2s;
    margin-right: 4px;
}

.dd-header-action:hover {
    background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.15);
}

.dd-header-action svg {
    width: 18px;
    height: 18px;
    fill: currentColor;
}

.dd-big-info {
    padding: 20px 16px;
    display: flex;
    flex-direction: column;
    align-items: center;
    text-align: center;
    gap: 8px;
}

.dd-big-info-icon {
    width: 48px;
    height: 48px;
    color: var(--text-gray);
    opacity: 0.5;
    margin-bottom: 4px;
}

.dd-big-info-icon svg {
    width: 48px;
    height: 48px;
    fill: currentColor;
}

.dd-big-info-label {
    font-size: 16px;
    font-weight: 700;
}

.dd-big-info-desc {
    font-size: 13px;
    color: var(--text-gray);
    line-height: 1.4;
}

.dd-big-info-btn {
    margin-top: 10px;
    padding: 8px 16px;
    background-color: var(--vk-blue);
    color: white;
    border-radius: 12px;
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
    transition: opacity 0.2s;
}

.dd-big-info-btn:hover {
    opacity: 0.9;
}

.dd-item {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 9px 12px;
    border-radius: 12px;
    cursor: pointer;
    font-size: 14px;
    font-weight: 500;
    color: var(--text-black, #e8e8e8);
    transition: background-color 0.12s ease, color 0.12s ease, transform 0.1s ease;
    user-select: none;
    -webkit-tap-highlight-color: transparent;
}

.dd-item:hover {
    background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.18);
    color: var(--vk-blue, #5b9ae8);
}

.dd-item:active {
    transform: scale(0.98);
    background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.28);
}

.dd-item--triggered {
    border: 1px solid rgba(128, 128, 128, 0.2);
    background: var(--menu-group-bg, rgba(255, 255, 255, 0.03));
    padding: 10px 12px;
    margin-bottom: 8px;
}

.dd-item--triggered:last-child {
    margin-bottom: 0;
}

.dd-item--triggered:hover {
    border-color: var(--border-color, rgba(255, 255, 255, 0.25));
    background: rgba(var(--vk-blue-rgb), 0.1);
}

.dd-item--has-bg {
    min-height: 80px;
    background-size: cover;
    background-position: center;
    position: relative;
    border: none;
    align-items: flex-end;
}

.dd-card-overlay {
    position: absolute;
    inset: 0;
    background: linear-gradient(to top, rgba(0,0,0,0.8) 0%, rgba(0,0,0,0.2) 100%);
    z-index: 1;
}

.dd-item--has-bg > *:not(.dd-card-overlay):not(.dd-featured-badge) {
    position: relative;
    z-index: 2;
}

.dd-featured-badge {
    position: absolute;
    top: 6px;
    left: 8px;
    font-size: 8px;
    font-weight: 800;
    letter-spacing: 0.1em;
    color: rgba(255, 255, 255, 0.6);
    z-index: 3;
}

.dd-item--destructive {
    color: #ff5252;
}

.dd-item--destructive:hover {
    background-color: rgba(255, 82, 82, 0.12);
    color: #ff5252;
}

.dd-item--active {
    color: var(--vk-blue, #5b9ae8);
    font-weight: 600;
}

.dd-item--disabled {
    opacity: 0.4;
    cursor: not-allowed;
    pointer-events: none;
}

.dd-item-icon {
    width: 20px;
    height: 20px;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    color: inherit;
    opacity: 0.85;
}

.dd-item-icon svg,
.dd-item-icon img {
    width: 20px;
    height: 20px;
    fill: currentColor;
    display: block;
}

.dd-item-label {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.dd-item-hint {
    font-size: 11px;
    color: var(--text-gray, rgba(180,180,180,0.7));
    font-weight: 400;
    flex-shrink: 0;
}

.dd-item-check {
    width: 16px;
    height: 16px;
    fill: var(--vk-blue, #5b9ae8);
    flex-shrink: 0;
    margin-left: auto;
}

.dd-item-info {
    flex: 1;
    display: flex;
    flex-direction: column;
    min-width: 0;
    gap: 1px;
}

.dd-item-label.with-bg {
    color: #fff;
    text-shadow: 0 1px 2px rgba(0,0,0,0.8);
}

.dd-item-sublabel {
    font-size: 11px;
    color: var(--text-gray, rgba(180, 180, 180, 0.7));
    font-weight: 400;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.dd-item-sublabel.with-bg {
    color: rgba(255, 255, 255, 0.7);
    text-shadow: 0 1px 1px rgba(0,0,0,0.8);
}

.dd-item-actions {
    display: flex;
    align-items: center;
    gap: 4px;
    margin-left: auto;
    z-index: 10;
}

.dd-item-action-btn {
    padding: 6px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 50%;
    color: var(--text-gray);
    transition: background 0.2s, color 0.2s;
}

.dd-item-action-btn:hover {
    background: rgba(var(--vk-blue-rgb), 0.15);
    color: var(--vk-blue);
}

.dd-item-action-btn svg {
    width: 18px;
    height: 18px;
    fill: currentColor;
}

.dd-item-action-btn.with-bg {
    color: white !important;
    background: rgba(0, 0, 0, 0.4);
    backdrop-filter: blur(4px);
}

.dd-item-action-btn.with-bg:hover {
    background: rgba(0, 0, 0, 0.6);
}

/* ── Animation ─────────────────────────────────────────── */
.dd-fade-enter-active {
    animation: dd-in 0.22s cubic-bezier(0.2, 0, 0.2, 1) both;
}

.dd-fade-leave-active {
    animation: dd-out 0.15s cubic-bezier(0.4, 0, 1, 1) both;
}

@keyframes dd-in {
    from {
        opacity: 0;
        transform: scale(0.96) translateY(-4px);
        filter: blur(4px);
    }
    to {
        opacity: 1;
        transform: scale(1) translateY(0);
        filter: blur(0);
    }
}

@keyframes dd-out {
    from {
        opacity: 1;
        transform: scale(1) translateY(0);
        filter: blur(0);
    }
    to {
        opacity: 0;
        transform: scale(0.96) translateY(-4px);
        filter: blur(4px);
    }
}
</style>



