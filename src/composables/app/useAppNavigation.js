import { ref, computed, watch } from 'vue';
import { forceMobileLayout } from '@/core/config/APPSettings.js';
import { App } from '@capacitor/app';
import { isKeyboardOpen, hideKeyboard } from '@/core/services/keyboardHandler.js';
import { closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { showToast } from '@/core/states/toastState.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { publishCancelableAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';

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

    function initBackButton() {
        let lastBackPress = 0;

        const handleBackButton = async () => {
            // --- Hierarchical Back Navigation Dispatch ---
            const backNavEvent = publishCancelableAppEvent(APP_EVENTS.ui.backNavigation);
            if (backNavEvent.defaultPrevented) return;

            // 0. If keyboard is open — dismiss it
            if (isKeyboardOpen.value) {
                await hideKeyboard();
                return;
            }

            // 1. Check for open Bottom Sheets
            const openSheet = document.querySelector('.modal-overlay.visible');
            if (openSheet) {
                closeBottomSheet();
                return;
            }

            // 1.1 Check full-screen editor (z-index 12000, above SheetView at 11000)
            // When FS editor is open, AppHeader is in "editor" mode with showBack=true.
            // Clicking #header-back routes through AppHeader.handleBack → state.onBack() → fsEditorVisible=false.
            const fsEditor = document.getElementById('full-screen-editor');
            if (fsEditor) {
                const headerBack = document.getElementById('header-back');
                if (headerBack) {
                    headerBack.click();
                } else {
                    const closeBtn = document.getElementById('fs-editor-close');
                    if (closeBtn) closeBtn.click();
                }
                return;
            }

            // 1.2 Check SheetView
            const openSheetView = document.querySelector('.sheet-view-overlay.visible');
            if (openSheetView) {
                const backEvent = new CustomEvent('hw-back', { cancelable: true });
                openSheetView.dispatchEvent(backEvent);
                if (!backEvent.defaultPrevented) {
                    openSheetView.click();
                }
                return;
            }

            // 1.3 Check Magic Drawer (ChatInput)
            // Skip if it is already in the process of closing (leave animation)
            const magicDrawer = document.querySelector('.magic-drawer');
            if (magicDrawer && !magicDrawer.classList.contains('drawer-leave-active')) {
                const btn = document.getElementById('btn-magic');
                if (btn) btn.click();
                return;
            }

            // 1.25 Check chat search mode
            const searchBackBtn = document.querySelector('.chat-search-back');
            if (searchBackBtn && searchBackBtn.offsetParent !== null) {
                searchBackBtn.click();
                return;
            }

            // 1.4 Check message selection mode
            const cancelSelectionBtn = document.querySelector('.btn-cancel-selection');
            if (cancelSelectionBtn && cancelSelectionBtn.offsetParent !== null) {
                cancelSelectionBtn.click();
                return;
            }

            // Check Viewers (Image Viewer & Holo Cards)
            const visibleViewer = document.querySelector('.viewer-overlay.visible');
            if (visibleViewer) {
                const closeBtn = visibleViewer.querySelector('.close-btn-trigger') || visibleViewer.querySelector('#image-viewer-close-btn') || visibleViewer.querySelector('#holocards-close-btn');
                if (closeBtn) closeBtn.click();
                return;
            }

            // 2. Check onboarding (back arrow)
            const onboardingBack = document.querySelector('.onboarding-overlay .nav-back-btn');
            if (onboardingBack) {
                onboardingBack.click();
                return;
            }

            // 3. Check header back button
            const backBtn = document.getElementById('header-back');
            if (backBtn && backBtn.offsetParent !== null) {
                backBtn.click();
                return;
            }

            // 4. App exit logic (main screen)
            const now = Date.now();
            if (now - lastBackPress < 2000) {
                App.exitApp();
            } else {
                lastBackPress = now;
                const text = (translations[currentLang.value] && translations[currentLang.value].exit_hint) || 'Press again to exit';
                showToast(text, 2500);
            }
        };

        App.addListener('backButton', handleBackButton);
        window.addEventListener('popstate', handleBackButton);
        window.simulateBackButton = handleBackButton;

        window.addEventListener('keydown', (e) => {
            if (e.key === 'Escape') {
                handleBackButton();
            }
        });
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
        setLayoutMetricsUpdater,
        initBackButton
    };
}
