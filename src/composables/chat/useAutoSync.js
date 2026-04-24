import { Capacitor } from '@capacitor/core';
import { incrementMessageCounter, shouldAutoSync, resetMessageCounter, isAutoSyncRunning, setAutoSyncRunning, getAutoSyncCooldownUntil, setAutoSyncCooldownUntil } from '@/core/states/syncState.js';
import { fullSync } from '@/core/services/syncService.js';

export async function triggerAutoSyncCheck({ isGenerating } = {}) {
    incrementMessageCounter();
    if (!shouldAutoSync()) return;
    if (isAutoSyncRunning()) return;
    if (Capacitor.isNativePlatform() && Date.now() < getAutoSyncCooldownUntil()) return;
    if (Capacitor.isNativePlatform() && (isGenerating?.value || document.visibilityState !== 'visible')) return;
    setAutoSyncRunning(true);
    resetMessageCounter();
    try {
        await fullSync();
        if (Capacitor.isNativePlatform()) {
            setAutoSyncCooldownUntil(Date.now() + 60000);
        }
    } catch (e) {
        console.warn('[AutoSync] failed:', e);
    } finally {
        setAutoSyncRunning(false);
    }
}
