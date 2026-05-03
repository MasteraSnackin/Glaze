<script setup>
import { ref } from 'vue';

const props = defineProps({
    text: { type: String, required: true },
    placement: { type: String, default: 'top' }, // top | bottom | left | right
    delay: { type: Number, default: 200 },
    disabled: { type: Boolean, default: false },
});

const visible = ref(false);
const style = ref({});
const wrapRef = ref(null);
let showTimer = null;
const GAP = 8;

function calcStyle() {
    const el = wrapRef.value;
    if (!el) return;
    const r = el.getBoundingClientRect();
    const s = {};
    if (props.placement === 'left') {
        s.top = r.top + r.height / 2 + 'px';
        s.left = r.left - GAP + 'px';
        s.transform = 'translate(-100%, -50%)';
    } else if (props.placement === 'right') {
        s.top = r.top + r.height / 2 + 'px';
        s.left = r.right + GAP + 'px';
        s.transform = 'translateY(-50%)';
    } else if (props.placement === 'bottom') {
        s.top = r.bottom + GAP + 'px';
        s.left = r.left + r.width / 2 + 'px';
        s.transform = 'translateX(-50%)';
    } else {
        // top
        s.top = r.top - GAP + 'px';
        s.left = r.left + r.width / 2 + 'px';
        s.transform = 'translate(-50%, -100%)';
    }
    style.value = s;
}

function show() {
    if (props.disabled) return;
    showTimer = setTimeout(() => {
        calcStyle();
        visible.value = true;
    }, props.delay);
}

function hide() {
    clearTimeout(showTimer);
    visible.value = false;
}
</script>

<template>
    <div ref="wrapRef" class="tooltip-wrap" @mouseenter="show" @mouseleave="hide">
        <slot />
        <Teleport to="body">
            <Transition name="tooltip-fade">
                <div v-if="visible" class="tooltip-bubble" :class="`tooltip-${placement}`" :style="style">
                    {{ text }}
                </div>
            </Transition>
        </Teleport>
    </div>
</template>

<style scoped>
.tooltip-wrap {
    display: block;
}
</style>

<style>
.tooltip-bubble {
    position: fixed;
    z-index: 99999;
    white-space: nowrap;
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
}

/* ── Arrow ── */
.tooltip-bubble::after {
    content: '';
    position: absolute;
    border: 5px solid transparent;
}

.tooltip-left::after {
    left: 100%;
    top: 50%;
    transform: translateY(-50%);
    border-left-color: rgba(var(--ui-bg-rgb), 0.92);
}

.tooltip-right::after {
    right: 100%;
    top: 50%;
    transform: translateY(-50%);
    border-right-color: rgba(var(--ui-bg-rgb), 0.92);
}

.tooltip-top::after {
    top: 100%;
    left: 50%;
    transform: translateX(-50%);
    border-top-color: rgba(var(--ui-bg-rgb), 0.92);
}

.tooltip-bottom::after {
    bottom: 100%;
    left: 50%;
    transform: translateX(-50%);
    border-bottom-color: rgba(var(--ui-bg-rgb), 0.92);
}

/* ── Transition ── */
.tooltip-fade-enter-active {
    transition: opacity 0.15s ease, scale 0.15s cubic-bezier(0.2, 0, 0.2, 1);
}
.tooltip-fade-leave-active {
    transition: opacity 0.1s ease;
}
.tooltip-fade-enter-from {
    opacity: 0;
    scale: 0.92;
}
.tooltip-fade-leave-to {
    opacity: 0;
}
</style>
