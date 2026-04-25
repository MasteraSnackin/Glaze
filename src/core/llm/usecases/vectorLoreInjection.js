import { estimateTokens } from '@/utils/tokenizer.js';
import { lorebookState } from '@/core/states/lorebookState.js';

function normalizeKeywordLoreEntries(loreEntries = []) {
    if (!Array.isArray(loreEntries)) return [];
    loreEntries.forEach(entry => {
        if (entry && !entry._source) entry._source = 'keyword';
    });
    return loreEntries.filter(entry => entry?._source === 'keyword');
}

function combineLoreSources(messages = []) {
    const sourceMap = new Map();
    for (const item of messages.flatMap(msg => msg._allSources || msg.sources || [])) {
        if (!item?.source) continue;
        sourceMap.set(item.source, (sourceMap.get(item.source) || 0) + (item.tokens || 0));
    }
    return [...sourceMap.entries()].map(([source, tokens]) => ({ source, tokens }));
}

function limitVectorLoreEntries(vectorEntries = [], keywordEntries = []) {
    const maxInjectedEntries = Math.max(1, Math.min(100, Number(lorebookState.globalSettings?.maxInjectedEntries || 5)));
    const remainingSlots = Math.max(0, maxInjectedEntries - keywordEntries.length);
    if (remainingSlots <= 0) return [];

    return [...vectorEntries]
        .sort((a, b) => (b.vectorScore || 0) - (a.vectorScore || 0))
        .slice(0, remainingSlots);
}

function buildVectorLoreBlock(entries, position) {
    const combinedContent = entries.map(msg => msg.content || '').filter(Boolean).join('\n\n');
    if (!combinedContent) return null;
    const combinedSources = combineLoreSources(entries);
    return {
        role: 'system',
        content: combinedContent,
        blockName: position === 'worldInfoAfter' ? 'Vector Lorebook After' : 'Vector Lorebook Before',
        isLorebook: true,
        sources: combinedSources,
        _allSources: combinedSources
    };
}

function resolveLateVectorLorePosition(entry) {
    const rawPosition = entry?.position === 'matchGlobal'
        ? (lorebookState.globalSettings?.injectionPosition || 'worldInfoBefore')
        : (entry?.position || 'worldInfoBefore');

    if (rawPosition === 'worldInfoAfter') return 'worldInfoAfter';
    if (rawPosition === 'lorebooksMacro') return 'worldInfoAfter';
    return 'worldInfoBefore';
}

export function mergeLateVectorLoreEntries(result, vectorResults = []) {
    const keywordEntries = normalizeKeywordLoreEntries(result?.loreEntries || []);
    const keywordIds = new Set(keywordEntries.map(entry => entry.id));
    const vectorEntries = limitVectorLoreEntries(
        vectorResults.filter(entry => !keywordIds.has(entry.id)),
        keywordEntries
    );

    vectorEntries.forEach(entry => { entry._source = 'vector'; });

    if (Array.isArray(result?.loreEntries)) {
        result.loreEntries = [...keywordEntries, ...vectorEntries];
    }

    return {
        keywordEntries,
        vectorEntries
    };
}

export function estimateVectorLoreTokens(entries = []) {
    return entries.reduce((sum, entry) => sum + estimateTokens(entry?.content || ''), 0);
}

export function injectVectorLoreMessages(messages, loreEntries) {
    if (!Array.isArray(loreEntries) || !loreEntries.length) return messages;

    const beforeEntries = [];
    const afterEntries = [];
    loreEntries.forEach(entry => {
        if (resolveLateVectorLorePosition(entry) === 'worldInfoAfter') afterEntries.push(entry);
        else beforeEntries.push(entry);
    });

    const beforeBlock = buildVectorLoreBlock(beforeEntries, 'worldInfoBefore');
    const afterBlock = buildVectorLoreBlock(afterEntries, 'worldInfoAfter');
    if (!beforeBlock && !afterBlock) return messages;

    const firstHistoryIndex = messages.findIndex(m => m.isHistory);
    const charCardIndex = messages.findIndex(m => m.blockId === 'char_card');
    const afterInsertIndex = firstHistoryIndex === -1 ? messages.length : firstHistoryIndex;
    const beforeInsertIndex = charCardIndex >= 0 ? charCardIndex : afterInsertIndex;

    let nextMessages = [...messages];
    if (afterBlock) {
        nextMessages = [
            ...nextMessages.slice(0, afterInsertIndex),
            afterBlock,
            ...nextMessages.slice(afterInsertIndex)
        ];
    }
    if (beforeBlock) {
        nextMessages = [
            ...nextMessages.slice(0, beforeInsertIndex),
            beforeBlock,
            ...nextMessages.slice(beforeInsertIndex)
        ];
    }
    return nextMessages;
}

export function injectLateVectorLoreMessages({ messages, newVectorEntries, safeContext }) {
    if (!newVectorEntries.length) {
        return { messages, vectorLoreTokens: 0 };
    }

    const vectorLoreMessages = newVectorEntries
        .map(entry => {
            const content = entry.content || '';
            const tokens = estimateTokens(content);
            return {
                role: 'system',
                content,
                id: entry.id,
                position: entry.position,
                blockName: `Lorebook: ${entry.comment || entry.keys?.[0] || 'Entry'}`,
                isLorebook: true,
                sources: tokens > 0 ? [{ source: 'vectorLore', tokens }] : [],
                _allSources: tokens > 0 ? [{ source: 'vectorLore', tokens }] : []
            };
        })
        .filter(msg => msg.content && msg.content.trim().length > 0);

    const vectorLoreTokens = vectorLoreMessages.reduce((sum, m) => sum + (m._allSources?.[0]?.tokens || 0), 0);
    if (!vectorLoreMessages.length) {
        return { messages, vectorLoreTokens };
    }

    const injectedMessages = injectVectorLoreMessages(messages, vectorLoreMessages);

    const staticMessages = injectedMessages.filter(m => !m.isHistory);
    const historyMessages = injectedMessages.filter(m => m.isHistory);
    let staticTokens = 0;
    for (const msg of staticMessages) {
        staticTokens += estimateTokens(msg.content || '');
    }

    if (staticTokens >= safeContext) {
        return {
            messages: staticMessages,
            vectorLoreTokens
        };
    }

    const remainingHistoryBudget = safeContext - staticTokens;
    let includedHistoryCount = 0;
    let currentHistoryTokens = 0;

    for (let i = historyMessages.length - 1; i >= 0; i--) {
        const tokens = estimateTokens(historyMessages[i].content || '');
        if (currentHistoryTokens + tokens <= remainingHistoryBudget) {
            currentHistoryTokens += tokens;
            includedHistoryCount++;
        } else {
            break;
        }
    }

    const keptHistoryMessages = historyMessages.slice(historyMessages.length - includedHistoryCount);
    const finalMessages = [];

    for (const message of injectedMessages) {
        if (!message.isHistory || keptHistoryMessages.includes(message)) {
            finalMessages.push(message);
        }
    }

    return {
        messages: finalMessages,
        vectorLoreTokens
    };
}
