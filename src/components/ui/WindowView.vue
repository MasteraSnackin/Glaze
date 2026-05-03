<script setup>
import { ref, computed, watch } from 'vue';
import AppHeader from '@/components/layout/AppHeader.vue';

const props = defineProps({
    nav: { 
        type: Object, 
        default: null 
    },
    mode: {
        type: String,
        default: 'panel' // "panel" (620x82vh) or "dialog" (auto-height, 400px width)
    }
});

const emit = defineEmits(['close']);

const internalVisible = ref(false);

const isVisible = computed(() => {
    if (props.nav) return props.nav.isDesktopFloating.value;
    return internalVisible.value;
});

const open = () => {
    if (!props.nav) {
        internalVisible.value = true;
    }
};

const close = () => {
    if (props.nav) {
        if (props.nav.desktopPreMenuView && props.nav.currentView) {
            props.nav.currentView.value = props.nav.desktopPreMenuView.value;
        }
    } else {
        internalVisible.value = false;
    }
    emit('close');
};

watch(isVisible, (val) => {
    // Only fade out the background element completely if it's a standalone standalone dialog (e.g AboutView)
    if (!props.nav) {
        const appEl = document.getElementById('app');
        if (!appEl) return;
        if (val) {
            appEl.style.transition = 'opacity 0.4s ease, filter 0.4s ease';
            appEl.style.opacity = '0';
            appEl.style.pointerEvents = 'none';
            document.body.style.backgroundColor = 'transparent';
        } else {
            appEl.style.opacity = '1';
            appEl.style.filter = '';
            appEl.style.pointerEvents = '';
        }
    }
});

defineExpose({ open, close, visible: isVisible });
</script>

<template>
    <Teleport to="body">
        <Transition name="fade">
            <div v-if="isVisible" class="window-overlay" @click.self="close">
                <div class="window-container" :class="['mode-' + mode]">

                    <!-- Panel Mode uses the generic AppHeader to intercept events -->
                    <div v-if="mode === 'panel' && nav" class="window-header-wrapper">
                        <AppHeader 
                            class="window-app-header" 
                            :current-view="nav.currentView.value"
                            :is-active="true"
                            :is-window-header="true"
                        />
                        <!-- We put the absolute close button over the AppHeader padding area for uniformity -->
                        <button class="window-close-btn" @click="close">
                            <svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
                        </button>
                    </div>

                    <!-- Dialog Mode uses the plain close button -->
                    <button v-else class="window-close-btn" @click="close">
                        <svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
                    </button>

                    <slot></slot>
                </div>
            </div>
        </Transition>
    </Teleport>
</template>

<style scoped>
.window-overlay {
    position: fixed;
    inset: 0;
    z-index: 400;
    background-color: rgba(0, 0, 0, 0.5);
    display: flex;
    align-items: center;
    justify-content: center;
    backdrop-filter: blur(2px);
    -webkit-backdrop-filter: blur(2px);
}

.window-container {
    position: relative;
    border-radius: 16px;
    overflow: hidden;
    display: flex;
    flex-direction: column;
    background-color: var(--ui-bg, #1e1e1e);
    border: 1px solid rgba(255, 255, 255, 0.1);
    box-shadow: 0 24px 64px rgba(0, 0, 0, 0.6);
}

.window-container.mode-panel {
    width: 620px;
    max-width: 92vw;
    height: 82vh;
    max-height: 92vh;
}

.window-container.mode-dialog {
    width: calc(100% - 32px);
    max-width: 400px;
    height: auto;
}

/* fade transition for the window */
.fade-enter-active,
.fade-leave-active {
    transition: opacity 0.2s ease, transform 0.2s cubic-bezier(0.2, 0.8, 0.2, 1);
}

.fade-enter-from,
.fade-leave-to {
    opacity: 0;
    transform: translateY(16px) scale(0.97);
}

/* --- Window App Header overrides --- */
.window-header-wrapper {
    position: relative;
    flex-shrink: 0;
    height: 60px;
    z-index: 50;
    background-color: var(--ui-bg, #1e1e1e);
    border-bottom: 1px solid rgba(255, 255, 255, 0.08);
}

/* Root wrapper: just constrain the height */
:deep(.window-app-header) {
    height: 60px;
    min-height: 60px;
}

/* Target the actual visual header element to strip mobile-app styling */
:deep(.window-app-header .app-header) {
    margin: 0 !important;
    border-radius: 0 !important;
    border: none !important;
    background-color: transparent !important;
    backdrop-filter: none !important;
    -webkit-backdrop-filter: none !important;
    box-shadow: none !important;
    background-image: none !important;
    height: 60px !important;
    min-height: 60px !important;
}

:deep(.window-app-header .header-btn-right) {
    padding-right: 48px;
}

.window-header-wrapper .window-close-btn {
    z-index: 200 !important;
}
</style>
