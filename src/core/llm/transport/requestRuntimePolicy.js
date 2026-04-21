import { BackgroundMode } from '@anuradev/capacitor-background-mode';
import { Capacitor } from '@capacitor/core';
import { startGenerationNotification, stopGenerationNotification } from '@/core/services/notificationService.js';

const LONG_REQUEST_THRESHOLD_MS = 2500;

export async function setupRequestRuntimePolicy({ notificationTitle, notificationBody }) {
    let wakeLock = null;
    let longRequestTimer = null;
    let foregroundRuntimeEnabled = false;

    const requestWakeLock = async () => {
        if ('wakeLock' in navigator && document.visibilityState === 'visible') {
            try {
                wakeLock = await navigator.wakeLock.request('screen');
            } catch (e) {
                console.warn('WakeLock error:', e);
            }
        }
    };

    await requestWakeLock();

    const handleVisibilityChange = () => {
        if (document.visibilityState === 'visible') {
            requestWakeLock();
            return;
        }

        if (Capacitor.isNativePlatform()) {
            enableForegroundRuntime();
        }
    };
    document.addEventListener('visibilitychange', handleVisibilityChange);

    const platform = Capacitor.getPlatform();
    const isAndroid = platform === 'android';
    const isIos = platform === 'ios';

    const enableForegroundRuntime = async () => {
        if (foregroundRuntimeEnabled) return;
        foregroundRuntimeEnabled = true;

        if (isAndroid) {
            await startGenerationNotification(notificationTitle, notificationBody);
        } else if (isIos) {
            try {
                await BackgroundMode.enable();
            } catch (e) {
                console.warn('BackgroundMode enable failed:', e);
            }
        }
    };

    if (Capacitor.isNativePlatform()) {
        longRequestTimer = setTimeout(() => {
            enableForegroundRuntime();
        }, LONG_REQUEST_THRESHOLD_MS);
    }

    return {
        async cleanup() {
            document.removeEventListener('visibilitychange', handleVisibilityChange);
            if (longRequestTimer) {
                clearTimeout(longRequestTimer);
                longRequestTimer = null;
            }
            if (wakeLock) {
                try {
                    await wakeLock.release();
                } catch (e) { }
            }

            if (foregroundRuntimeEnabled && isAndroid) {
                await stopGenerationNotification();
            } else if (foregroundRuntimeEnabled && isIos) {
                try {
                    await BackgroundMode.disable();
                } catch (e) { }
            }
        }
    };
}
