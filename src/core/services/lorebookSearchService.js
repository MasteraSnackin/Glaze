import { lorebookState } from '@/core/states/lorebookState.js';

function escapeRegex(string) {
    return string.replace(/[/\-\\^$*+?.()|[\]{}]/g, '\\$&');
}

const GLAZE_BOUNDARIES = '[\\s.,!?;:"\'\\u201C\\u201D\\u2018\\u2019\\u00AB\\u00BB(){}\\[\\]—–]';

export function scanLorebooks(history = [], char = null, textToScan = "", chatId = null) {
    const charId = char?.id;

    const activeLorebooks = lorebookState.lorebooks.filter(lb => {
        if (lb.enabled) return true;
        if (charId && lorebookState.activations?.character?.[charId]?.includes(lb.id)) return true;
        if (chatId && lorebookState.activations?.chat?.[chatId]?.includes(lb.id)) return true;
        return false;
    });

    if (activeLorebooks.length === 0) return [];

    const allRelevantEntries = [];

    const candidates = [];
    activeLorebooks.forEach(lb => {
        lb.entries.forEach(entry => {
            if (entry.enabled !== false) {
                if (char && entry.characterFilter) {
                    const { isExclude, names } = entry.characterFilter;
                    if (names && names.length > 0) {
                        const charName = (char.name || "").toLowerCase();
                        const isInCategory = names.some(n => charName.includes(n.toLowerCase()));
                        if (isExclude && isInCategory) return;
                        if (!isExclude && !isInCategory) return;
                    }
                }
                candidates.push({ ...entry, lorebookName: lb.name, lorebookId: lb.id });
            }
        });
    });

    candidates.filter(e => e.constant).forEach(entry => {
        if (!allRelevantEntries.some(e => e.id === entry.id)) {
            allRelevantEntries.push(entry);
        }
    });

    let changed = true;
    let iteration = 0;
    const maxIterations = (lorebookState.globalSettings.recursiveScan === false) ? 1 : 5;

    while (changed && iteration < maxIterations) {
        changed = false;
        iteration++;

        for (const entry of candidates) {
            if (allRelevantEntries.some(e => e === entry)) continue;
            if (entry.constant) continue;

            const primaryKeys = entry.keys || [];
            const secondaryKeys = (entry.secondary_keys || entry.keysecondary) || [];
            const logic = entry.selectiveLogic ?? 5;

            const caseSensitive = entry.caseSensitive ?? lorebookState.globalSettings.caseSensitive ?? false;
            const wholeWords = entry.matchWholeWords ?? lorebookState.globalSettings.matchWholeWords ?? false;

            const checkMatch = (key, text) => {
                if (!key) return false;
                const sourceText = `${text ?? ''}`;
                const sourceKey = `${key}`;
                const flags = caseSensitive ? '' : 'i';

                if (wholeWords === 'glaze') {
                    const escaped = escapeRegex(sourceKey);
                    const pattern = `(?:^|${GLAZE_BOUNDARIES})${escaped}(?:$|${GLAZE_BOUNDARIES})`;
                    try {
                        return new RegExp(pattern, flags).test(sourceText);
                    } catch (e) {
                        const haystack = caseSensitive ? sourceText : sourceText.toLowerCase();
                        const needle = caseSensitive ? sourceKey : sourceKey.toLowerCase();
                        if (!needle) return false;
                        const escapedNeedle = escapeRegex(needle);
                        try {
                            return new RegExp(`(?:^|${GLAZE_BOUNDARIES})${escapedNeedle}(?:$|${GLAZE_BOUNDARIES})`, caseSensitive ? '' : 'i').test(haystack);
                        } catch (e2) {
                            return false;
                        }
                    }
                }

                let pattern = sourceKey;
                if (wholeWords) {
                    pattern = `\\b${pattern}\\b`;
                }
                try {
                    const regex = new RegExp(pattern, flags);
                    return regex.test(sourceText);
                } catch (e) {
                    const haystack = caseSensitive ? sourceText : sourceText.toLowerCase();
                    const needle = caseSensitive ? sourceKey : sourceKey.toLowerCase();
                    if (!needle) return false;

                    if (wholeWords) {
                        const escaped = escapeRegex(needle);
                        const wordRegex = new RegExp(`\\b${escaped}\\b`, caseSensitive ? '' : 'i');
                        return wordRegex.test(haystack);
                    }

                    return haystack.includes(needle);
                }
            };

            const scanDepth = entry.scanDepth ?? lorebookState.globalSettings.scanDepth ?? 10;
            const temporalDepth = Math.max(entry.sticky || 0, entry.cooldown || 0);
            const effectiveScanDepth = temporalDepth > 0
                ? Math.min(scanDepth, temporalDepth)
                : scanDepth;
            const messagesToScan = history.slice(-effectiveScanDepth).map(m => m.content).join("\n");

            const scanSource = caseSensitive ?
                (messagesToScan + textToScan) :
                (messagesToScan.toLowerCase() + textToScan.toLowerCase());

            let isStickyActive = false;
            let isOnCooldown = false;

            if (entry.sticky > 0 || entry.cooldown > 0) {
                for (let i = 1; i <= Math.max(entry.sticky || 0, entry.cooldown || 0); i++) {
                    const histMsg = history[history.length - i];
                    if (!histMsg) break;

                    const histSource = caseSensitive ? histMsg.content : histMsg.content.toLowerCase();
                    const wasMatched = primaryKeys.some(key => checkMatch(key, histSource));

                    if (wasMatched) {
                        if (i <= (entry.sticky || 0)) isStickyActive = true;
                        if (i <= (entry.cooldown || 0)) isOnCooldown = true;
                        break;
                    }
                }
            }

            if (isOnCooldown) continue;

            const matchedPrimary = isStickyActive || primaryKeys.some(key => checkMatch(key, scanSource));

            if (matchedPrimary) {
                let secondaryMatches = true;

                if (logic === 4 || secondaryKeys.length === 0) {
                    secondaryMatches = true;
                } else if (secondaryKeys.length > 0) {
                    const matches = secondaryKeys.map(key => checkMatch(key, scanSource));
                    const anyMatch = matches.some(m => m);
                    const allMatch = matches.every(m => m);

                    if (logic === 0) secondaryMatches = anyMatch;
                    else if (logic === 1) secondaryMatches = allMatch;
                    else if (logic === 2) secondaryMatches = !anyMatch;
                    else if (logic === 3) secondaryMatches = !allMatch;
                }

                if (secondaryMatches) {
                    if (entry.probability !== undefined && entry.probability < 100) {
                        if (Math.random() * 100 > entry.probability) continue;
                    }

                    allRelevantEntries.push(entry);

                    if (!entry.preventRecursion && iteration < maxIterations) {
                        textToScan += "\n" + (entry.content || "").toLowerCase();
                        changed = true;
                    }
                }
            }
        }
    }

    const maxInjectedEntries = Math.max(1, Math.min(100, Number(lorebookState.globalSettings?.maxInjectedEntries || 5)));
    return allRelevantEntries
        .sort((a, b) => (a.order ?? 100) - (b.order ?? 100))
        .slice(0, maxInjectedEntries);
}
