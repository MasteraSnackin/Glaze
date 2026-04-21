import { BackgroundMode } from '@anuradev/capacitor-background-mode';
import { Capacitor } from '@capacitor/core';
import { startGenerationNotification, stopGenerationNotification } from '@/core/services/notificationService.js';

export async function setupRequestRuntimePolicy({ notificationTitle, notificationBody }) {
    let wakeLock = null;

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
        if (document.visibilityState === 'visible') requestWakeLock();
    };
    document.addEventListener('visibilitychange', handleVisibilityChange);

    const platform = Capacitor.getPlatform();
    const isAndroid = platform === 'android';
    const isIos = platform === 'ios';

    if (isAndroid) {
        await startGenerationNotification(notificationTitle, notificationBody);
    } else if (isIos) {
        try {
            await BackgroundMode.enable();
        } catch (e) {
            console.warn('BackgroundMode enable failed:', e);
        }
    }

    return {
        async cleanup() {
            document.removeEventListener('visibilitychange', handleVisibilityChange);
            if (wakeLock) {
                try {
                    await wakeLock.release();
                } catch (e) { }
            }

            if (isAndroid) {
                await stopGenerationNotification();
            } else if (isIos) {
                try {
                    await BackgroundMode.disable();
                } catch (e) { }
            }
        }
    };
}
