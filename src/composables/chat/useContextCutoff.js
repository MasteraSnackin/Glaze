import { ref } from 'vue';
import { calculateContext } from '@/core/llm/usecases/calculateContext.js';
import { buildGenerationAuthorsNote } from '@/composables/chat/useGenerationPreparation.js';
import { getApiRuntimeStorage } from '@/core/config/APISettings.js';
import * as contextService from '@/core/services/contextService.js';
import { useContextBreakdown } from '@/composables/chat/useContextBreakdown.js';

export function useContextCutoff({
    getActiveChatChar,
    currentMessages,
    isOpeningChat,
    isBatterySaverUI,
    getChatData,
    db,
    getEffectivePreset,
    showBottomSheet,
    closeBottomSheet,
    showToast,
    tokenizerSheet,
    presetView
}) {
    const cutoffIndex = ref(-1);
    const contextBreakdown = ref(null);
    let isCalculatingCutoff = false;
    let pendingCutoffRecalc = false;
    let cutoffRerunTimer = null;
    let cutoffDebounceTimer = null;
    let contextCutoffCache = null;

    const { fillThreshold: initialFillThreshold, hidePercent: initialHidePercent } = contextService.loadHistoryContextSettings();
    const historyFillThreshold = ref(initialFillThreshold);
    const historyHidePercent = ref(initialHidePercent);

    const {
        contextSegments,
        contextBreakdownItems,
        contextLegendItems,
        visibleHistoryMessages,
        historyUsagePercent,
        historyHidePreview,
        shouldRecommendHide
    } = useContextBreakdown({
        contextBreakdown,
        currentMessages,
        historyFillThreshold,
        historyHidePercent
    });

    async function saveCurrentMessages() {
        const activeChatChar = getActiveChatChar();
        if (!activeChatChar) return;
        const data = await getChatData(activeChatChar.id);
        if (!data) return;
        const sessionId = activeChatChar.sessionId || data.currentId;
        data.sessions[sessionId] = currentMessages.value;
        await db.saveChat(activeChatChar.id, data);
    }

    async function updateContextCutoff() {
        const activeChatChar = getActiveChatChar();
        if (!activeChatChar || !currentMessages.value) return;

        const currentCharId = activeChatChar.id;
        const currentSessionId = activeChatChar.sessionId;

        if (isOpeningChat()) {
            pendingCutoffRecalc = true;
            return;
        }

        if (isCalculatingCutoff) {
            pendingCutoffRecalc = true;
            return;
        }

        isCalculatingCutoff = true;

        const visibleMessages = currentMessages.value.filter(m => m && !m.isTyping && !m.isHidden);
        const messageCount = visibleMessages.length;

        try {
            const cutoffChatData = await getChatData(activeChatChar.id);
            if (getActiveChatChar()?.id !== currentCharId) return;

            const sessionId = cutoffChatData.currentId;

            const runtime = getApiRuntimeStorage();
            const contextSize = String(runtime.contextSize || 32000);
            const maxTokens = String(runtime.maxTokens || 8000);
            const cacheKey = `${currentCharId}_${sessionId}_${messageCount}_${contextSize}_${maxTokens}`;

            if (contextCutoffCache && contextCutoffCache.hash === cacheKey) {
                cutoffIndex.value = contextCutoffCache.result?.cutoffIndex ?? 0;
                contextBreakdown.value = contextCutoffCache.result?.contextBreakdown || null;
                return;
            }

            const history = visibleMessages
                .map((m, i) => ({ role: m.role === 'user' ? 'user' : 'assistant', content: m.text || "", originalIndex: i }));

            const summary = cutoffChatData.summaries?.[sessionId];

            let authorsNote = null;
            if (cutoffChatData.authorsNotes && cutoffChatData.authorsNotes[sessionId]) {
                authorsNote = buildGenerationAuthorsNote({
                    getEffectivePreset,
                    charId: activeChatChar.id,
                    sessionId,
                    anContent: cutoffChatData.authorsNotes[sessionId]
                });
            }

            const charSnapshot = JSON.parse(JSON.stringify(activeChatChar));
            const result = await calculateContext({
                char: charSnapshot,
                history,
                authorsNote,
                summary
            });

            if (getActiveChatChar()?.id !== currentCharId) return;

            cutoffIndex.value = result?.cutoffIndex ?? 0;
            contextBreakdown.value = result?.contextBreakdown || null;
            contextCutoffCache = {
                hash: cacheKey,
                charId: currentCharId,
                sessionId,
                messageCount,
                result
            };
        } finally {
            isCalculatingCutoff = false;
            if (pendingCutoffRecalc) {
                pendingCutoffRecalc = false;
                if (cutoffRerunTimer) clearTimeout(cutoffRerunTimer);
                cutoffRerunTimer = setTimeout(() => {
                    updateContextCutoff();
                }, 0);
            }
        }
    }

    function debouncedUpdateContextCutoff(delay = 300) {
        const effectiveDelay = isBatterySaverUI.value ? Math.max(delay, 700) : delay;
        if (cutoffDebounceTimer) clearTimeout(cutoffDebounceTimer);
        cutoffDebounceTimer = setTimeout(() => {
            updateContextCutoff();
        }, effectiveDelay);
    }

    function invalidateContextCache() {
        contextCutoffCache = null;
        contextBreakdown.value = null;
    }

    function handleSaveContextSettings({ fillThreshold, hidePercent }) {
        const clamped = contextService.persistHistoryContextSettings(fillThreshold, hidePercent);
        historyFillThreshold.value = clamped.fillThreshold;
        historyHidePercent.value = clamped.hidePercent;
    }

    async function hideTopMessagesNow() {
        const count = historyHidePreview.value.count;
        const activeChatChar = getActiveChatChar();
        if (!count || !activeChatChar) return;

        let hidden = 0;
        for (const msg of currentMessages.value) {
            if (!msg || msg.isTyping || msg.isHidden) continue;
            msg.isHidden = true;
            hidden += 1;
            if (hidden >= count) break;
        }

        if (!hidden) return;

        await saveCurrentMessages();
        await updateContextCutoff();
        closeBottomSheet();
        showToast(`Hidden ${hidden} top message${hidden === 1 ? '' : 's'}`);
    }

    function confirmHideTopMessages() {
        const preview = historyHidePreview.value;
        if (!preview.count) return;

        showBottomSheet({
            title: 'Hide Top Messages',
            items: [
                {
                    label: 'Open Summary',
                    hint: 'Review or generate a summary first',
                    icon: '<svg viewBox="0 0 24 24"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-2 14H7v-2h10v2zm0-4H7v-2h10v2zm0-4H7V7h10v2z"/></svg>',
                    onClick: () => {
                        closeBottomSheet();
                        setTimeout(() => presetView.value?.openSummarySheet(), 250);
                    }
                },
                {
                    label: `Hide ${preview.count} message${preview.count === 1 ? '' : 's'} now`,
                    hint: `Free about ${preview.tokens} tokens`,
                    icon: '<svg viewBox="0 0 24 24"><path d="M12 7c2.76 0 5 2.24 5 5 0 .65-.13 1.26-.36 1.83l2.92 2.92c1.51-1.26 2.7-2.89 3.43-4.75-1.73-4.39-6-7.5-11-7.5-1.4 0-2.74.25-3.98.7l2.16 2.16C10.74 7.13 11.35 7 12 7zM2 4.27l2.28 2.28.46.46C3.08 8.3 1.78 10.02 1 12c1.73 4.39 6 7.5 11 7.5 1.55 0 3.03-.3 4.38-.84l.42.42L19.73 22 21 20.73 3.27 3 2 4.27z"/></svg>',
                    onClick: () => {
                        hideTopMessagesNow();
                    }
                },
                {
                    label: 'Cancel',
                    onClick: () => {
                        closeBottomSheet();
                        setTimeout(() => {
                            isCalculatingCutoff = false;
                            tokenizerSheet.value?.open();
                        }, 50);
                    }
                }
            ]
        });
    }

    async function unhideAllMessages() {
        const activeChatChar = getActiveChatChar();
        if (!activeChatChar) return;

        let changed = 0;
        for (const msg of currentMessages.value) {
            if (!msg || msg.isTyping || !msg.isHidden) continue;
            msg.isHidden = false;
            changed += 1;
        }

        if (!changed) return;

        await saveCurrentMessages();
        await updateContextCutoff();
        closeBottomSheet();
        showToast(`Unhid ${changed} message${changed === 1 ? '' : 's'}`);
    }

    async function openContextSheet() {
        const activeChatChar = getActiveChatChar();
        if (activeChatChar) {
            const calculatePromise = updateContextCutoff();
            const timeoutPromise = new Promise(resolve => { setTimeout(resolve, 5000) });
            await Promise.race([calculatePromise, timeoutPromise]);

            if (isCalculatingCutoff) {
                await new Promise(resolve => { setTimeout(resolve, 3000) });
            }
        }

        if (!contextBreakdown.value) {
            console.warn('[openContextSheet] contextBreakdown is still null, retrying...');
            try {
                const retryPromise = updateContextCutoff();
                const retryTimeout = new Promise(resolve => { setTimeout(resolve, 8000) });
                await Promise.race([retryPromise, retryTimeout]);
            } catch (e) {
                console.error('[openContextSheet] retry failed:', e);
            }
        }

        if (!contextBreakdown.value) {
            showBottomSheet({
                title: 'Context',
                bigInfo: {
                    icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;"><path d="M11 17h2v-6h-2v6zm0-8h2V7h-2v2zm1-7C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2z"/></svg>',
                    description: 'Context calculation is taking longer than expected. Please check that your API settings are configured correctly and try again.',
                    buttonText: 'Close',
                    onButtonClick: () => closeBottomSheet()
                }
            });
            return;
        }

        tokenizerSheet.value?.open();
    }

    function resetCutoffState() {
        contextCutoffCache = null;
        cutoffIndex.value = -1;
        contextBreakdown.value = null;
    }

    function consumePendingCutoffRecalc() {
        const was = pendingCutoffRecalc;
        pendingCutoffRecalc = false;
        return was;
    }

    function clearCutoffTimers() {
        if (cutoffRerunTimer) {
            clearTimeout(cutoffRerunTimer);
            cutoffRerunTimer = null;
        }
        if (cutoffDebounceTimer) {
            clearTimeout(cutoffDebounceTimer);
        }
    }

    return {
        cutoffIndex,
        contextBreakdown,
        contextSegments,
        contextBreakdownItems,
        contextLegendItems,
        visibleHistoryMessages,
        historyUsagePercent,
        historyHidePreview,
        shouldRecommendHide,
        historyFillThreshold,
        historyHidePercent,
        saveCurrentMessages,
        updateContextCutoff,
        debouncedUpdateContextCutoff,
        invalidateContextCache,
        handleSaveContextSettings,
        hideTopMessagesNow,
        confirmHideTopMessages,
        unhideAllMessages,
        openContextSheet,
        resetCutoffState,
        clearCutoffTimers,
        consumePendingCutoffRecalc,
        getIsCalculatingCutoff: () => isCalculatingCutoff,
        setPendingCutoffRecalc: (v) => { pendingCutoffRecalc = v; }
    };
}
