import { computed } from 'vue';
import { estimateTokens } from '@/utils/tokenizer.js';

export function useContextBreakdown({
    contextBreakdown,
    currentMessages,
    historyFillThreshold,
    historyHidePercent
}) {
    const contextSegments = computed(() => {
        const breakdown = contextBreakdown.value;
        if (!breakdown || !breakdown.safeContext) return { used: [], reserve: null };

        const total = breakdown.safeContext;
        const toPercent = (value) => Math.max(0, Math.min(100, (value / total) * 100));
        const used = [];

        if (breakdown.character > 0) {
            used.push({ key: 'character', value: breakdown.character, percent: toPercent(breakdown.character), className: 'segment-character' });
        }
        if (breakdown.preset > 0) {
            used.push({ key: 'preset', value: breakdown.preset, percent: toPercent(breakdown.preset), className: 'segment-fixed' });
        }
        if (breakdown.persona > 0) {
            used.push({ key: 'persona', value: breakdown.persona, percent: toPercent(breakdown.persona), className: 'segment-persona' });
        }
        if (breakdown.authorsNote > 0) {
            used.push({ key: 'authorsNote', value: breakdown.authorsNote, percent: toPercent(breakdown.authorsNote), className: 'segment-authors-note' });
        }
        if (breakdown.summary > 0) {
            used.push({ key: 'summary', value: breakdown.summary, percent: toPercent(breakdown.summary), className: 'segment-summary' });
        }
        if (breakdown.memory > 0) {
            used.push({ key: 'memory', value: breakdown.memory, percent: toPercent(breakdown.memory), className: 'segment-memory' });
        }
        if (breakdown.history > 0) {
            used.push({ key: 'history', value: breakdown.history, percent: toPercent(breakdown.history), className: 'segment-history' });
        }

        let reserve = null;
        if (breakdown.lorebookReserve > 0) {
            const reserveUsed = [];
            if (breakdown.lorebook > 0) {
                reserveUsed.push({ key: 'lorebook', value: breakdown.lorebook, percent: toPercent(breakdown.lorebook), className: 'segment-lorebook' });
            }
            if (breakdown.vectorLore > 0) {
                reserveUsed.push({ key: 'vectorLore', value: breakdown.vectorLore, percent: toPercent(breakdown.vectorLore), className: 'segment-vector-lore' });
            }
            const totalLoreUsed = (breakdown.lorebook || 0) + (breakdown.vectorLore || 0);
            const reserveRemaining = breakdown.lorebookReserve - totalLoreUsed;

            reserve = {
                key: 'lorebookReserve',
                value: breakdown.lorebookReserve,
                percent: toPercent(breakdown.lorebookReserve),
                className: 'segment-lorebook-reserve',
                used: reserveUsed,
                remaining: reserveRemaining > 0 ? reserveRemaining : 0
            };
        }

        return { used, reserve };
    });

    const contextBreakdownItems = computed(() => {
        const breakdown = contextBreakdown.value;
        if (!breakdown) return [];

        return [
            { key: 'character', label: 'Character', value: breakdown.character || 0 },
            { key: 'preset', label: 'Preset', value: breakdown.preset || 0 },
            { key: 'persona', label: 'Persona', value: breakdown.persona || 0 },
            { key: 'authorsNote', label: 'Author\'s Note', value: breakdown.authorsNote || 0 },
            { key: 'summary', label: 'Summary Base', value: breakdown.summaryBase ?? breakdown.summary ?? 0 },
            { key: 'memory', label: 'Memory', value: breakdown.memory || 0 },
            { key: 'summaryCombined', label: 'Summary Total', value: breakdown.summary || 0 },
            { key: 'lorebook', label: 'Keyword Lorebook', value: breakdown.lorebook || 0 },
            { key: 'vectorLore', label: 'Vector Lorebook', value: breakdown.vectorLore || 0 },
            { key: 'lorebookTotal', label: 'Lorebook Total', value: (breakdown.lorebook || 0) + (breakdown.vectorLore || 0) },
            { key: 'lorebookReserve', label: 'Lorebook Reserve', value: breakdown.lorebookReserve || 0 },
            { key: 'history', label: 'History', value: breakdown.history || 0 }
        ];
    });

    const contextLegendItems = computed(() => [
        { key: 'character', label: 'Character', className: 'segment-character' },
        { key: 'preset', label: 'Preset', className: 'segment-fixed' },
        { key: 'persona', label: 'Persona', className: 'segment-persona' },
        { key: 'authorsNote', label: 'Author\'s Note', className: 'segment-authors-note' },
        { key: 'summary', label: 'Summary', className: 'segment-summary' },
        { key: 'memory', label: 'Memory', className: 'segment-memory' },
        { key: 'lorebook', label: 'Keyword Lorebook', className: 'segment-lorebook' },
        { key: 'vectorLore', label: 'Vector Lorebook', className: 'segment-vector-lore' },
        { key: 'history', label: 'History', className: 'segment-history' },
        { key: 'lorebookReserve', label: 'Lorebook Reserve', className: 'segment-lorebook-reserve' }
    ]);

    const visibleHistoryMessages = computed(() => {
        return currentMessages.value.filter(m => m && !m.isTyping && !m.isHidden);
    });

    const historyUsagePercent = computed(() => {
        const breakdown = contextBreakdown.value;
        if (!breakdown) return 0;
        const available = breakdown.availableForHistory || 0;
        if (available <= 0) return breakdown.history > 0 ? 100 : 0;
        return Math.max(0, Math.min(100, Math.round(((breakdown.history || 0) / available) * 100)));
    });

    const historyHidePreview = computed(() => {
        const messages = visibleHistoryMessages.value;
        const percent = Math.max(1, Math.min(95, historyHidePercent.value || 30));
        if (!messages.length) return { count: 0, tokens: 0 };

        const count = Math.max(1, Math.min(messages.length, Math.ceil(messages.length * percent / 100)));
        const tokens = messages
            .slice(0, count)
            .reduce((sum, msg) => sum + estimateTokens(msg.text || ''), 0);

        return { count, tokens };
    });

    const shouldRecommendHide = computed(() => {
        const breakdown = contextBreakdown.value;
        if (!breakdown || !breakdown.history) return false;
        const threshold = Math.max(1, Math.min(100, historyFillThreshold.value || 85));
        return historyUsagePercent.value >= threshold;
    });

    return {
        contextSegments,
        contextBreakdownItems,
        contextLegendItems,
        visibleHistoryMessages,
        historyUsagePercent,
        historyHidePreview,
        shouldRecommendHide
    };
}
