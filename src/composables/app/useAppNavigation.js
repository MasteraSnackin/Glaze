import { ref, computed, watch } from 'vue';
import { forceMobileLayout } from '@/core/config/APPSettings.js';

export function useAppNavigation() {
    const isDesktop = ref(typeof window !== 'undefined' && window.innerWidth >= 768 && !forceMobileLayout.value);
    const currentView = ref(isDesktop.value ? 'view-characters' : 'view-dialogs');
    const desktopPreMenuView = ref(isDesktop.value ? 'view-characters' : 'view-dialogs');
    const isChatInitialized = ref(false);
    const currentChatSessionId = ref(null);
    const activeChatCharObj = ref(null);
    const chatPreviousView = ref(null);
    const isHeaderEditorMode = ref(false);
    const isOnboarding = ref(false);

    const menuViews = ['view-menu', 'view-settings', 'view-theme-settings'];
    const isDesktopFloating = computed(() => isDesktop.value && menuViews.includes(currentView.value));

    const effectiveMainView = computed(() => {
        if (isDesktopFloating.value) return desktopPreMenuView.value;
        return currentView.value;
    });

    const checkDesktop = () => {
        const isDesk = typeof window !== 'undefined' && window.innerWidth >= 768 && !forceMobileLayout.value;
        if (isDesk !== isDesktop.value) {
            if (isDesk && currentView.value === 'view-dialogs') {
                currentView.value = 'view-characters';
            }
            isDesktop.value = isDesk;
        }
    };

    watch(currentView, () => {
        isHeaderEditorMode.value = false;
    });

    watch(isDesktop, () => {
        requestAnimationFrame(updateLayoutMetrics);
    });

    watch(forceMobileLayout, () => {
        checkDesktop();
    });

    watch(currentView, (newVal, oldVal) => {
        if (isDesktop.value && oldVal && !menuViews.includes(oldVal) && menuViews.includes(newVal)) {
            desktopPreMenuView.value = oldVal;
        }
    });

    function openChatWrapper(char, { chatViewRef, waitForComponent }) {
        currentChatSessionId.value = char.sessionId || null;
        activeChatCharObj.value = char;
        const previousView = currentView.value;
        chatPreviousView.value = previousView;
        currentView.value = 'view-chat';
        isChatInitialized.value = true;

        waitForComponent(chatViewRef, (comp) => {
            comp.openChat(char, () => {
                currentView.value = previousView;
            });
        });
    }

    function finishOnboarding() {
        localStorage.setItem('glaze_onboarding_completed', 'true');
        isOnboarding.value = false;
    }

    let _updateLayoutMetrics = null;

    function setLayoutMetricsUpdater(fn) {
        _updateLayoutMetrics = fn;
    }

    function updateLayoutMetrics() {
        if (_updateLayoutMetrics) _updateLayoutMetrics();
    }

    return {
        isDesktop,
        currentView,
        desktopPreMenuView,
        isChatInitialized,
        currentChatSessionId,
        activeChatCharObj,
        chatPreviousView,
        isHeaderEditorMode,
        isOnboarding,
        menuViews,
        isDesktopFloating,
        effectiveMainView,
        checkDesktop,
        openChatWrapper,
        finishOnboarding,
        updateLayoutMetrics,
        setLayoutMetricsUpdater
    };
}
