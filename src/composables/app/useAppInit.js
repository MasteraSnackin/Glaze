import { onMounted, onBeforeUnmount } from 'vue';
import { Capacitor } from '@capacitor/core';
import { initSettings, applyApiRuntimeConfig } from '@/core/config/APISettings.js';
import { initTheme } from '@/core/states/themeState.js';
import { loadPersonas } from '@/core/states/personaState.js';
import { initLorebookState } from '@/core/states/lorebookState.js';
import { initPresetState } from '@/core/states/presetState.js';
import { initSyncState, syncProvider } from '@/core/states/syncState.js';
import { checkSyncReadiness, fullPull } from '@/core/services/syncService.js';
import { startTracking } from '@/core/services/timeTracker.js';
import { initRipple, initThemeToggle, initHeaderDropdown, initBackButton, initViewportFix } from '@/core/services/ui.js';
import { checkAndRequestNotifications, consumePendingNotificationData } from '@/core/services/notificationService.js';
import { generateMissingThumbnails } from '@/utils/characterIO.js';
import { migrateScToGz } from '@/utils/db.js';
import { isKeyboardOpen, onKeyboardShow, onKeyboardHide } from '@/core/services/keyboardHandler.js';
import { updateLanguage } from '@/utils/i18n.js';

export function useAppInit({
    isOnboarding,
    isDataLoaded,
    isDesktop,
    checkDesktop,
    updateLayoutMetrics,
    headerContainer,
    footerContainer,
    categories,
    activeCategories,
    appEventUnsubs,
    handleOpenChatEvent
}) {
    let layoutObserver = null;
    const kbListeners = [];

    onMounted(async () => {
        await migrateScToGz();

        isOnboarding.value = localStorage.getItem('glaze_onboarding_completed') !== 'true';

        initSettings();
        await initTheme();
        await Promise.all([
            initLorebookState(),
            initPresetState(),
            loadPersonas(),
            initSyncState()
        ]);

        startTracking();

        if (syncProvider.value) {
            checkSyncReadiness().then(ready => {
                if (ready.ready) {
                    fullPull().catch(e => console.warn('[App] Background pull failed:', e));
                }
            });
        }

        initRipple();
        initThemeToggle();
        initViewportFix();
        initBackButton();

        initHeaderDropdown(categories, activeCategories, () => {});

        const pendingData = consumePendingNotificationData();
        if (pendingData) {
            handleOpenChatEvent(pendingData);
        }

        layoutObserver = new ResizeObserver(() => {
            requestAnimationFrame(updateLayoutMetrics);
        });
        if (headerContainer.value) layoutObserver.observe(headerContainer.value);
        if (footerContainer.value) layoutObserver.observe(footerContainer.value);
        updateLayoutMetrics();

        updateLanguage();
        isDataLoaded.value = true;

        generateMissingThumbnails();

        checkDesktop();
        window.addEventListener('resize', checkDesktop);

        setTimeout(() => {
            document.body.classList.remove('preload');
            document.body.classList.add('app-loaded');
        }, 100);

        setTimeout(checkAndRequestNotifications, 1000);

        if (Capacitor.isNativePlatform()) {
            kbListeners.push(await onKeyboardShow(() => { isKeyboardOpen.value = true; }));
            kbListeners.push(await onKeyboardHide(() => { isKeyboardOpen.value = false; }));
        }
    });

    onBeforeUnmount(() => {
        if (layoutObserver) layoutObserver.disconnect();
        appEventUnsubs.forEach(unsub => unsub());
        appEventUnsubs.length = 0;
        kbListeners.forEach(l => l.remove());
        window.removeEventListener('resize', checkDesktop);
    });

    return { kbListeners };
}
