export function escapeRegex(string) {
    return String(string || '').replace(/[/\\-\\^$*+?.()|[\]{}]/g, '\\$&');
}

export const GLAZE_BOUNDARIES = '[\\s.,!?;:"\'\u201C\u201D\u2018\u2019\u00AB\u00BB(){}\\[\\]\u2014\u2013]';

export function tryCreateRegex(pattern, flags = 'g') {
    try {
        return new RegExp(pattern, flags);
    } catch {
        return null;
    }
}

export function checkKeyMatch(key, text, { glaze = false, caseSensitive = false } = {}) {
    if (!key || !text) return false;
    const sourceText = String(text || '');
    const sourceKey = String(key || '');
    const flags = caseSensitive ? '' : 'i';
    if (glaze) {
        const escaped = escapeRegex(sourceKey);
        const regex = tryCreateRegex(`(?:^|${GLAZE_BOUNDARIES})${escaped}(?:$|${GLAZE_BOUNDARIES})`, flags);
        return regex ? regex.test(sourceText) : false;
    }
    const regex = tryCreateRegex(`\\b${escapeRegex(sourceKey)}\\b`, flags);
    if (regex && regex.test(sourceText)) return true;
    const haystack = caseSensitive ? sourceText : sourceText.toLowerCase();
    const needle = caseSensitive ? sourceKey : sourceKey.toLowerCase();
    return haystack.includes(needle);
}

export function normalizeMessageIdList(entry) {
    if (!entry || typeof entry !== 'object') return [];
    if (Array.isArray(entry.messageIds)) return [...new Set(entry.messageIds.filter(Boolean))];
    const ids = [];
    if (entry.messageRange?.startMessageId) ids.push(entry.messageRange.startMessageId);
    if (entry.messageRange?.endMessageId && entry.messageRange.endMessageId !== entry.messageRange.startMessageId) ids.push(entry.messageRange.endMessageId);
    return [...new Set(ids.filter(Boolean))];
}

export function buildSummaryExcerpt(summary) {
    if (!summary) return '';
    if (typeof summary === 'string') return summary.trim().slice(0, 800);
    if (typeof summary === 'object') {
        if (typeof summary.content === 'string') return summary.content.trim().slice(0, 800);
        return ['timeline', 'characterArcs', 'conflictsThreads', 'notHappenedYet', 'notes']
            .map(key => summary[key])
            .filter(value => typeof value === 'string' && value.trim())
            .join('\n\n')
            .slice(0, 800);
    }
    return '';
}
