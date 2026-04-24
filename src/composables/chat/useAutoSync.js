import { Capacitor } from '@capacitor/core';
import { incrementMessageCounter, shouldAutoSync, resetMessageCounter } from '@/core/states/syncState.js';
import { fullSync } from '@/core/services/syncService.js';

let autoSyncRunning = false;
let autoSyncCooldownUntil = 0;

export async function triggerAutoSyncCheck({ isGenerating } = {}) {
    incrementMessageCounter();
    if (!shouldAutoSync()) return;
    if (autoSyncRunning) return;
    if (Capacitor.isNativePlatform() && Date.now() < autoSyncCooldownUntil) return;
    if (Capacitor.isNativePlatform() && (isGenerating?.value || document.visibilityState !== 'visible')) return;
    autoSyncRunning = true;
    resetMessageCounter();
    try {
        await fullSync();
        if (Capacitor.isNativePlatform()) {
            autoSyncCooldownUntil = Date.now() + 60000;
        }
    } catch (e) {
        console.warn('[AutoSync] failed:', e);
    } finally {
        autoSyncRunning = false;
    }
}
