<script setup>
import { reactive, computed, ref, onBeforeUnmount, nextTick } from 'vue';
import { forceMobileLayout } from '@/core/config/APPSettings.js';

const props = defineProps({
    items: { type: Array, required: true },
    placement: { type: String, default: 'left' },
});

const GAP = 8;
const PADDING_H = 28; // 14px left + 14px right padding

const state = reactive({
    visible: false,
    currentItemId: null,
    text: '',
    subtitle: null,
    meta: null,
    textKey: 0,
    width: null, // explicit px width for transition; null = auto on first show
    position: { top: 0, left: 0 },
});

const bubbleRef = ref(null);
let hideTimer = null;

// Off-screen canvas for measuring text width
let _canvas = null;
function measureTextWidth(text) {
    if (!_canvas) _canvas = document.createElement('canvas');
    const ctx = _canvas.getContext('2d');
    ctx.font = '500 15px/1.4 ' + getComputedStyle(document.body).fontFamily;
    return Math.ceil(ctx.measureText(text).width) + PADDING_H;
}

const tooltipStyle = computed(() => {
    const transforms = {
        left: 'translate(-100%, -50%)',
        right: 'translateY(-50%)',
        top: 'translate(-50%, -100%)',
        bottom: 'translateX(-50%)',
    };
    return {
        top: state.position.top + 'px',
        left: state.position.left + 'px',
        transform: transforms[props.placement] ?? 'translate(-100%, -50%)',
        ...(state.width !== null ? { width: state.width + 'px' } : {}),
    };
});

function updatePosition(element) {
    try {
        const rect = element.getBoundingClientRect();
        let top = rect.top + rect.height / 2;
        let left;

        if (props.placement === 'left') {
            left = rect.left - GAP;
        } else if (props.placement === 'right') {
            left = rect.right + GAP;
        } else if (props.placement === 'bottom') {
            left = rect.left + rect.width / 2;
            top = rect.bottom + GAP;
        } else {
            left = rect.left + rect.width / 2;
            top = rect.top - GAP;
        }

        if (top < 10) top = 10;
        if (top > window.innerHeight - 50) top = window.innerHeight - 50;

        state.position = { top, left };
    } catch (e) {
        console.warn('[ToolStripTooltip] position calculation failed:', e);
        state.visible = false;
    }
}

function handleItemEnter(itemId, event) {
    if (typeof window !== 'undefined' && (window.innerWidth < 768 || forceMobileLayout.value)) return;

    const item = props.items.find(i => i.id === itemId);
    if (!item || !item.label) return;

    if (hideTimer) {
        clearTimeout(hideTimer);
        hideTimer = null;
    }

    // Measure width based on longest line (label, subtitle, or meta)
    let maxWidth = measureTextWidth(item.label);
    if (item.subtitle) {
        const subtitleWidth = measureTextWidth(item.subtitle);
        if (subtitleWidth > maxWidth) maxWidth = subtitleWidth;
    }
    if (item.meta) {
        const metaWidth = measureTextWidth(item.meta);
        if (metaWidth > maxWidth) maxWidth = metaWidth;
    }

    if (!state.visible) {
        // First show: set width without transition by skipping it on first render
        state.text = item.label;
        state.subtitle = item.subtitle || null;
        state.meta = item.meta || null;
        state.textKey++;
        state.visible = true;
        state.currentItemId = itemId;
        updatePosition(event.currentTarget ?? event.target);
        // Let the bubble render at natural size, then lock in the width
        nextTick(() => {
            if (bubbleRef.value) {
                const naturalWidth = bubbleRef.value.offsetWidth;
                state.width = naturalWidth;
            }
        });
    } else {
        // Already visible: animate width to new size, swap text
        const contentChanged = state.text !== item.label || state.subtitle !== (item.subtitle || null) || state.meta !== (item.meta || null);
        if (contentChanged) {
            state.textKey++;
            state.text = item.label;
            state.subtitle = item.subtitle || null;
            state.meta = item.meta || null;
            state.width = maxWidth;
        }
        state.currentItemId = itemId;
        updatePosition(event.currentTarget ?? event.target);
    }
}

function handleItemLeave() {
    hideTimer = setTimeout(() => {
        state.visible = false;
        state.currentItemId = null;
        state.subtitle = null;
        state.meta = null;
        state.width = null;
        hideTimer = null;
    }, 50);
}

onBeforeUnmount(() => {
    if (hideTimer) clearTimeout(hideTimer);
    state.visible = false;
});
</script>

<template>
    <div class="tool-strip-tooltip-wrapper">
        <slot :on-item-enter="handleItemEnter" :on-item-leave="handleItemLeave" />

        <Teleport to="body">
            <Transition name="tooltip-bubble-fade">
                <div
                    v-if="state.visible"
                    ref="bubbleRef"
                    class="tool-strip-tooltip-bubble"
                    :class="[`tooltip-${placement}`, { 'has-subtitle': state.subtitle || state.meta }]"
                    :style="tooltipStyle"
                >
                    <Transition name="tooltip-text-fade">
                        <div :key="state.textKey" class="tooltip-content">
                            <div class="tooltip-text">{{ state.text }}</div>
                            <div v-if="state.meta" class="tooltip-meta">{{ state.meta }}</div>
                            <div v-if="state.subtitle" class="tooltip-subtitle">{{ state.subtitle }}</div>
                        </div>
                    </Transition>
                </div>
            </Transition>
        </Teleport>
    </div>
</template>

<style scoped>
.tool-strip-tooltip-wrapper {
    display: contents;
}

.tooltip-content {
    display: flex;
    flex-direction: column;
    gap: 2px;
}

.tooltip-text {
    display: block;
    font-weight: 600;
    line-height: 1.3;
}

.tooltip-subtitle {
    display: block;
    font-size: 13px;
    font-weight: 400;
    opacity: 0.75;
    line-height: 1.4;
    white-space: normal;
    word-wrap: break-word;
    max-width: 280px;
}

.tooltip-meta {
    display: block;
    font-size: 12px;
    font-weight: 500;
    opacity: 0.6;
    margin-bottom: 4px;
}
</style>

<style>
.tool-strip-tooltip-bubble {
    position: fixed;
    z-index: 99999;
    pointer-events: none;
    background-color: rgba(var(--ui-bg-rgb), 0.92);
    backdrop-filter: blur(12px);
    -webkit-backdrop-filter: blur(12px);
    border: 1px solid var(--border-color, rgba(255, 255, 255, 0.1));
    border-radius: 12px;
    padding: 7px 14px;
    font-size: 15px;
    font-weight: 500;
    color: var(--text-black, #e8e8e8);
    box-shadow: 0 4px 16px rgba(0, 0, 0, 0.25);
    line-height: 1.4;
    overflow: hidden;
    transition:
        top 200ms cubic-bezier(0.4, 0, 0.2, 1),
        left 200ms cubic-bezier(0.4, 0, 0.2, 1),
        width 200ms cubic-bezier(0.4, 0, 0.2, 1);
    will-change: top, left, width;
    max-width: 320px;
}

.tool-strip-tooltip-bubble.has-subtitle {
    white-space: normal;
    padding: 9px 14px;
}

/* Arrow border (outline) */
.tool-strip-tooltip-bubble::before {
    content: '';
    position: absolute;
    border: 6px solid transparent;
    z-index: -1;
}

/* Arrow fill */
.tool-strip-tooltip-bubble::after {
    content: '';
    position: absolute;
    border: 5px solid transparent;
}

.tool-strip-tooltip-bubble.tooltip-left::before {
    left: 100%;
    top: 50%;
    transform: translateY(-50%);
    border-left-color: var(--border-color, rgba(255, 255, 255, 0.1));
}

.tool-strip-tooltip-bubble.tooltip-left::after {
    left: 100%;
    top: 50%;
    transform: translateY(-50%);
    border-left-color: rgba(var(--ui-bg-rgb), 0.92);
}

.tool-strip-tooltip-bubble.tooltip-right::after {
    right: 100%;
    top: 50%;
    transform: translateY(-50%);
    border-right-color: rgba(var(--ui-bg-rgb), 0.92);
}

.tool-strip-tooltip-bubble.tooltip-top::after {
    top: 100%;
    left: 50%;
    transform: translateX(-50%);
    border-top-color: rgba(var(--ui-bg-rgb), 0.92);
}

.tool-strip-tooltip-bubble.tooltip-bottom::after {
    bottom: 100%;
    left: 50%;
    transform: translateX(-50%);
    border-bottom-color: rgba(var(--ui-bg-rgb), 0.92);
}

/* Bubble appear/disappear */
.tooltip-bubble-fade-enter-active {
    transition: opacity 150ms ease, scale 150ms cubic-bezier(0.2, 0, 0.2, 1);
}
.tooltip-bubble-fade-leave-active {
    transition: opacity 100ms ease;
}
.tooltip-bubble-fade-enter-from {
    opacity: 0;
    scale: 0.92;
}
.tooltip-bubble-fade-leave-to {
    opacity: 0;
}

/* Text fade-in only — new text fades in, no fade-out of old */
.tooltip-text-fade-enter-active {
    transition: opacity 120ms ease;
}
.tooltip-text-fade-leave-active {
    transition: none;
    position: absolute;
    opacity: 0;
}
.tooltip-text-fade-enter-from {
    opacity: 0;
}
</style>
