import { getApiConfig, getApiRuntimeStorage } from '@/core/config/APISettings.js';
import { getEffectivePreset } from '@/core/states/presetState.js';

export function getEffectiveApiConfig() {
    const config = getApiConfig();
    const runtime = getApiRuntimeStorage();
    let { maxTokens, contextSize } = config;

    if (!contextSize) contextSize = runtime.contextSize || 32000;
    if (maxTokens === undefined || maxTokens === null) {
        maxTokens = runtime.maxTokens || 8000;
    }

    return { ...config, maxTokens, contextSize };
}

export function loadActivePreset(char, sessionId) {
    const charId = char?.id;
    const chatId = charId && sessionId ? `${charId}_${sessionId}` : null;
    return getEffectivePreset(charId, chatId);
}

export function getSafeContextLimit(contextSize, maxTokens) {
    return contextSize - maxTokens > 0 ? contextSize - maxTokens : 8000;
}

export function trimHistoryForContextWindow(history, safeContextLimit) {
    const isIOS = typeof navigator !== 'undefined' && /iPad|iPhone|iPod/.test(navigator.userAgent || '');
    const memoryLimitFactor = isIOS ? 15 : 5;
    const maxHistoryRetention = Math.max(100, Math.ceil(safeContextLimit / memoryLimitFactor));

    if (history && history.length > maxHistoryRetention) {
        return history.slice(-maxHistoryRetention);
    }

    return history;
}

export function loadSessionVars(char) {
    const charId = char?.id || 'default';
    const sessionId = char?.sessionId || 'current';
    const varsKey = `gz_vars_${charId}_${sessionId}`;
    let sessionVars = {};
    try { sessionVars = JSON.parse(localStorage.getItem(varsKey)) || {}; } catch (e) { }
    return { varsKey, sessionVars };
}

export function loadGlobalRegexes() {
    let globalRegexes = [];
    try { globalRegexes = JSON.parse(localStorage.getItem('regex_scripts')) || []; } catch (e) { }
    for (const script of globalRegexes) {
        if (script.findRegex && !script.regex) {
            script.regex = script.findRegex;
        }
        if (script.replaceString !== undefined && script.replacement === undefined) {
            script.replacement = script.replaceString;
        }
        if (typeof script.placement === 'number') script.placement = [script.placement];
        if (typeof script.ephemerality === 'number') script.ephemerality = [script.ephemerality];
    }
    return globalRegexes;
}
