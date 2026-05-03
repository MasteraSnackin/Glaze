import { getEffectivePreset } from '@/core/states/presetState.js';
import { replaceMacros } from '@/utils/macroEngine.js';

function escapeRegex(string) {
    return string.replace(/[/\-\\^$*+?.()|[\]{}]/g, '\\$&');
}

/**
 * Applies a list of regex scripts to a string based on placement and ephemerality filters.
 * 
 * @param {string} text The input text to process.
 * @param {number} placementFilter 1=User Input, 2=AI Output, 3=Slash Commands, 4=World Info, 5=Reasoning.
 * @param {number} ephemeralityFilter 1=Alter Chat Display, 2=Alter Outgoing Prompt.
 * @param {Array} options Extra options { charId, sessionId, globalScripts, char, persona, depth }
 * @param {number} [options.depth] Optional message depth (0=newest). If provided, scripts with
 *   minDepth/maxDepth are only applied when the message's depth falls within their range.
 * @returns {string} Processed text.
 */
let _globalScriptsCache = null;
let _globalScriptsCacheKey = null;

function _loadGlobalScripts(providedGlobalScripts) {
    if (providedGlobalScripts) return providedGlobalScripts;
    try {
        const raw = localStorage.getItem('regex_scripts');
        if (raw === _globalScriptsCacheKey && _globalScriptsCache) return _globalScriptsCache;
        _globalScriptsCacheKey = raw;
        _globalScriptsCache = raw ? JSON.parse(raw) : [];
        for (const script of _globalScriptsCache) {
            if (script.findRegex && !script.regex) {
                script.regex = script.findRegex;
            }
            if (script.replaceString !== undefined && script.replacement === undefined) {
                script.replacement = script.replaceString;
            }
            if (typeof script.placement === 'number') script.placement = [script.placement];
            if (typeof script.ephemerality === 'number') script.ephemerality = [script.ephemerality];
        }
    } catch (e) {
        console.error('Failed to load global regex scripts', e);
        _globalScriptsCache = [];
        _globalScriptsCacheKey = null;
    }
    return _globalScriptsCache;
}

export function invalidateRegexCache() {
    _globalScriptsCache = null;
    _globalScriptsCacheKey = null;
}

export function applyRegexes(text, placementFilter, ephemeralityFilter, options = {}) {
    if (!text) return "";
    let processedText = text;

    const { charId, sessionId, char, persona, depth } = options;

    const globalScripts = _loadGlobalScripts(options.globalScripts);

    // Load preset scripts if possible
    let presetRegexes = [];
    if (charId && sessionId) {
        const chatId = `${charId}_${sessionId}`;
        const preset = getEffectivePreset(charId, chatId);
        if (preset && preset.regexes) {
            presetRegexes = preset.regexes;
            for (const script of presetRegexes) {
                if (typeof script.placement === 'number') script.placement = [script.placement];
                if (typeof script.ephemerality === 'number') script.ephemerality = [script.ephemerality];
            }
        }
    }

    const allScripts = [...presetRegexes, ...globalScripts];

    for (const script of allScripts) {
        if (script.disabled) continue;

        const sPlacement = Array.isArray(script.placement) ? script.placement : (typeof script.placement === 'number' ? [script.placement] : null);
        if (sPlacement && !sPlacement.includes(placementFilter)) continue;

        const sEphemerality = Array.isArray(script.ephemerality) ? script.ephemerality : (typeof script.ephemerality === 'number' ? [script.ephemerality] : null);
        if (sEphemerality && !sEphemerality.includes(ephemeralityFilter)) continue;

        if (depth !== undefined && depth !== null) {
            const minD = script.minDepth ?? null;
            const maxD = script.maxDepth ?? null;
            if (minD !== null && depth < minD) continue;
            if (maxD !== null && depth > maxD) continue;
        }

        try {
            let triggered = false;

            // 1. Trim Tokens
            if (script.trimOut) {
                const trimTokens = script.trimOut.split('\n').filter(t => t.trim());
                for (const token of trimTokens) {
                    const before = processedText;
                    processedText = processedText.replaceAll(token, '');
                    if (processedText !== before) triggered = true;
                }
            }

            // 2. Regex Pattern
            if (script.regex) {
                let pattern = script.regex;
                let replacement = script.replacement || '';
                let flags = 'g';

                // Handle Macros
                if (script.macroRules && script.macroRules !== '0') {
                    if (script.macroRules === '1') { // Raw
                        pattern = replaceMacros(pattern, char, persona);
                        replacement = replaceMacros(replacement, char, persona);
                    } else if (script.macroRules === '2') { // Escaped
                        // For regex pattern, we must escape the substituted values
                        pattern = pattern.replace(/{{user}}/gi, persona ? escapeRegex(persona.name) : 'User')
                            .replace(/{{char}}/gi, char ? escapeRegex(char.name) : 'Character');
                        // Other macros might still need raw replacement or escaping
                        pattern = replaceMacros(pattern, char, persona);

                        replacement = replaceMacros(replacement, char, persona);
                    }
                }

                // Support /pattern/flags format
                if (pattern.startsWith('/') && pattern.lastIndexOf('/') > 0) {
                    const lastSlash = pattern.lastIndexOf('/');
                    const extractedFlags = pattern.substring(lastSlash + 1);
                    pattern = pattern.substring(1, lastSlash);
                    flags = extractedFlags.includes('g') ? extractedFlags : extractedFlags + 'g';
                }

                const regex = new RegExp(pattern, flags);
                const before = processedText;
                processedText = processedText.replace(regex, replacement);
                if (processedText !== before) triggered = true;
            }

            if (triggered && options.triggeredRegexes) {
                if (!options.triggeredRegexes.some(r => r.id === script.id)) {
                    options.triggeredRegexes.push(script);
                }
            }
        } catch (e) {
            console.error(`Error executing regex script "${script.name}":`, e, script);
        }
    }

    return processedText;
}

// Exports
export function exportSTRegex(script) {
    return {
        id: script.id || Date.now().toString(),
        scriptName: script.name || 'Unnamed Regex',
        findRegex: script.regex || '',
        replaceString: script.replacement || '',
        trimStrings: script.trimOut ? script.trimOut.split('\n').filter(s => s) : [],
        placement: script.placement || [2],
        disabled: script.disabled ?? false,
        markdownOnly: script.ephemerality ? script.ephemerality.includes(1) && !script.ephemerality.includes(2) : (script.markdownOnly ?? false),
        promptOnly: script.ephemerality ? script.ephemerality.includes(2) && !script.ephemerality.includes(1) : (script.promptOnly ?? false),
        runOnEdit: script.runOnEdit ?? false,
        substituteRegex: script.macroRules ? parseInt(script.macroRules) || 0 : 0,
        ephemerality: script.ephemerality || [1, 2],
        minDepth: script.minDepth ?? null,
        maxDepth: script.maxDepth ?? null
    };
}
