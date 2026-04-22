import { estimateTokens } from '@/utils/tokenizer.js';
import { db } from '@/utils/db.js';
import { getEmbeddings } from '@/core/services/embeddingService.js';
import { getEmbeddingConfig, isEmbeddingConfigured } from '@/core/config/embeddingSettings.js';
import { findTopK } from '@/utils/vectorMath.js';

function normalizeMessageIdList(entry) {
    if (!entry || typeof entry !== 'object') return [];
    if (Array.isArray(entry.messageIds)) return [...new Set(entry.messageIds.filter(Boolean))];
    const ids = [];
    if (entry.messageRange?.startMessageId) ids.push(entry.messageRange.startMessageId);
    if (entry.messageRange?.endMessageId && entry.messageRange.endMessageId !== entry.messageRange.startMessageId) ids.push(entry.messageRange.endMessageId);
    return [...new Set(ids.filter(Boolean))];
}

function buildSummaryExcerpt(summary) {
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

function escapeRegex(string) {
    return String(string || '').replace(/[/\\-\\^$*+?.()|[\]{}]/g, '\\$&');
}

const GLAZE_BOUNDARIES = '[\\s.,!?;:"\'\u201C\u201D\u2018\u2019\u00AB\u00BB(){}\\[\\]\u2014\u2013]';

function tryCreateRegex(pattern, flags = 'g') {
    try {
        return new RegExp(pattern, flags);
    } catch {
        return null;
    }
}

function normalizeHybridText(text = '') {
    return String(text || '')
        .toLowerCase()
        .replace(/[^\p{L}\p{N}\s-]+/gu, ' ')
        .replace(/\s+/g, ' ')
        .trim();
}

function uniqueStrings(values = [], limit = 32) {
    const seen = new Set();
    const result = [];
    for (const value of values) {
        const raw = String(value || '').trim();
        const normalized = normalizeHybridText(raw);
        if (!normalized || seen.has(normalized)) continue;
        seen.add(normalized);
        result.push(raw);
        if (result.length >= limit) break;
    }
    return result;
}

function extractMemoryRetrievalHints(entry) {
    const hints = [];
    if (entry?.title) hints.push(String(entry.title));
    if (Array.isArray(entry?.keys)) hints.push(...entry.keys.map(v => String(v)));
    if (Array.isArray(entry?.glazeKeys)) hints.push(...entry.glazeKeys.map(v => String(v)));
    const content = String(entry?.content || '');
    if (content) {
        const lines = content.split(/\r?\n/).map(line => line.trim()).filter(Boolean).slice(0, 8);
        hints.push(...lines);
    }
    return uniqueStrings(hints, 32);
}

function checkKeyMatch(key, text, { glaze = false, caseSensitive = false } = {}) {
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

async function vectorSearchMemoryEntries(entries, history = [], currentText = '') {
    const config = getEmbeddingConfig();
    if (!config.enabled || !isEmbeddingConfigured()) return [];
    const vectorEntries = entries.filter(entry => entry?.vectorSearch);
    if (!vectorEntries.length) return [];

    const allEmbeddings = await db.getEmbeddingsBySource('memory_entry');
    const embeddingMap = new Map(allEmbeddings.map(e => [e.id, e]));
    const candidates = vectorEntries
        .map(entry => {
            const emb = embeddingMap.get(entry.id);
            if (emb && (emb.vectors || emb.vector)) {
                const candidate = { ...entry, retrievalHints: emb.retrievalHints || [] };
                if (emb.vectors) {
                    candidate.vectors = emb.vectors;
                } else if (emb.vector) {
                    candidate.vector = emb.vector;
                }
                return candidate;
            }
            return null;
        })
        .filter(Boolean);
    if (!candidates.length) return [];

    const recentHistory = history.slice(-(config.scanDepth || 5));
    const focusedQueryParts = recentHistory.filter(m => m.role === 'user').map(m => m.content).filter(Boolean);
    if (currentText && currentText.trim()) focusedQueryParts.push(currentText.trim());
    const queryText = focusedQueryParts.join('\n').trim();
    if (!queryText) return [];

    const queryVectorsData = await getEmbeddings([queryText]);
    if (!queryVectorsData || !queryVectorsData[0] || !queryVectorsData[0][0]?.vector) return [];

    const queryVector = queryVectorsData[0][0].vector;
    return findTopK(queryVector, candidates, candidates.length, 0)
        .filter(result => result.score >= (config.threshold || 0.6))
        .slice(0, config.topK || 5)
        .map(result => ({ ...result, vectorScore: result.score, vector: undefined }));
}

async function ensureMemoryEntryEmbedding(entry, charId, sessionId) {
    if (!entry?.id || !entry.vectorSearch || !isEmbeddingConfigured()) return;
    const config = getEmbeddingConfig();
    if (!config.enabled) return;
    const text = (config.target === 'keys'
        ? [...(entry.keys || []), ...(entry.glazeKeys || [])].join(', ')
        : String(entry.content || '')).trim();
    if (!text) return;
    const existing = await db.getEmbedding(entry.id);
    const retrievalHints = extractMemoryRetrievalHints(entry);
    const textHash = JSON.stringify({ text, retrievalHints });
    if (existing && existing.textHash === textHash) return;
    const vectorsData = await getEmbeddings([text]);
    if (!vectorsData || !vectorsData[0]) return;
    await db.saveEmbedding({
        id: entry.id,
        sourceType: 'memory_entry',
        sourceId: `memorybook_${charId}_${sessionId}`,
        vectors: vectorsData[0],
        vector: null,
        textHash,
        retrievalHints,
        updatedAt: Date.now()
    });
}

export async function indexMemoryEntryForSession(entry, charId, sessionId) {
    await ensureMemoryEntryEmbedding(entry, charId, sessionId);
}

export async function deleteMemoryEntryIndex(entryId) {
    if (!entryId) return;
    await db.deleteEmbedding(entryId);
}

export async function buildMemoryInjection({ char, history, summary, safeContext, cutoffOriginalIndex = -1 }) {
    const charId = char?.id;
    const sessionId = char?.sessionId;
    if (!charId || !sessionId) return { messages: [], entries: [], tokens: 0, injectionTarget: 'summary_block', macroContent: '' };

    const chatData = await db.getChat(charId);
    const memoryBook = chatData?.memoryBooks?.[sessionId];
    const settings = memoryBook?.settings || {};
    const activeEntries = (Array.isArray(memoryBook?.entries) ? memoryBook.entries : [])
        .filter(entry => entry && (entry.status || 'active') === 'active' && (entry.content || '').trim());

    if (!settings.enabled || !activeEntries.length) {
        return {
            messages: [],
            entries: [],
            tokens: 0,
            injectionTarget: settings.injectionTarget === 'summary_macro' ? 'summary_macro' : 'summary_block',
            macroContent: ''
        };
    }

    const recentHistory = Array.isArray(history) ? history.slice(-12) : [];
    const historyText = recentHistory.map(item => item?.content || item?.text || '').filter(Boolean).join('\n').toLowerCase();

    const inPromptMessageIds = new Set();
    if (cutoffOriginalIndex >= 0 && Array.isArray(history)) {
        for (const m of history) {
            if ((m.chatId ?? -1) >= cutoffOriginalIndex && m.messageId) {
                inPromptMessageIds.add(m.messageId);
            }
        }
    } else {
        recentHistory.forEach(item => {
            if (item?.messageId) inPromptMessageIds.add(item.messageId);
        });
    }

    const recentLabels = new Set();
    recentHistory.forEach(item => {
        (Array.isArray(item?.contextRefs) ? item.contextRefs : []).forEach(ref => {
            if (ref?.label) recentLabels.add(String(ref.label).toLowerCase());
        });
    });

    const uniqueWords = [...new Set(historyText.match(/[\p{L}\p{N}_-]{4,}/gu) || [])].slice(0, 40);
    const currentText = recentHistory[recentHistory.length - 1]?.content || '';
    const keywordMatchedIds = new Set();
    const scanText = `${recentHistory.map(item => item?.content || '').join('\n')}\n${currentText}`;
    const keyMatchMode = ['plain', 'glaze', 'both'].includes(settings.keyMatchMode) ? settings.keyMatchMode : 'plain';

    activeEntries.forEach(entry => {
        const directKeys = Array.isArray(entry.keys) ? entry.keys : [];
        const plainMatch = keyMatchMode !== 'glaze' && directKeys.some(key => checkKeyMatch(key, scanText));
        const glazeMatch = keyMatchMode !== 'plain' && directKeys.some(key => checkKeyMatch(key, scanText, { glaze: true }));
        if (plainMatch || glazeMatch) {
            keywordMatchedIds.add(entry.id);
        }
    });

    const vectorResults = await vectorSearchMemoryEntries(activeEntries, history, currentText).catch(() => []);
    const vectorScores = new Map(vectorResults.map(item => [item.id, item.vectorScore || item.score || 0]));

    const eligibleEntries = activeEntries.filter(entry => {
        const messageIds = normalizeMessageIdList(entry);
        if (!messageIds.length) return true;
        return !messageIds.some(id => inPromptMessageIds.has(id));
    });

    const scoredEntries = eligibleEntries.map((entry, index) => {
        const haystack = `${entry.title || ''}\n${entry.content || ''}`.toLowerCase();
        const messageIds = normalizeMessageIdList(entry);
        let score = 0;
        if (messageIds.length > 0) score += 2;
        if (keywordMatchedIds.has(entry.id)) score += 6;
        if (vectorScores.has(entry.id)) score += Math.max(0, (vectorScores.get(entry.id) || 0) * 5);
        (Array.isArray(entry.contextRefs) ? entry.contextRefs : []).forEach(ref => {
            const label = String(ref?.label || '').toLowerCase();
            if (label && recentLabels.has(label)) score += 3;
        });
        uniqueWords.forEach(word => {
            if (haystack.includes(word)) score += 1;
        });
        score += Math.min(3, index / Math.max(eligibleEntries.length, 1));
        return { entry, score };
    });

    const topEntries = scoredEntries
        .filter(item => item.score > 0)
        .sort((a, b) => b.score - a.score)
        .slice(0, Math.max(1, Math.min(5, settings.maxInjectedEntries || 3)))
        .map(item => item.entry);

    if (!topEntries.length) {
        return {
            messages: [],
            entries: [],
            tokens: 0,
            injectionTarget: settings.injectionTarget === 'summary_macro' ? 'summary_macro' : 'summary_block',
            macroContent: ''
        };
    }

    const summaryExcerpt = buildSummaryExcerpt(summary);
    const macroContent = topEntries
        .map(entry => (entry.content || '').trim())
        .filter(Boolean)
        .join('\n\n');
    const content = [
        summaryExcerpt ? `Summary excerpt:\n${summaryExcerpt}` : '',
        'Memory context:',
        ...topEntries.map(entry => `- ${(entry.title || 'Memory').trim()}: ${(entry.content || '').trim()}`)
    ].filter(Boolean).join('\n\n');
    const tokens = estimateTokens(content);
    if (!content || tokens <= 0 || tokens >= Math.max(256, Math.floor(safeContext * 0.35))) {
        return {
            messages: [],
            entries: [],
            tokens: 0,
            injectionTarget: settings.injectionTarget === 'summary_macro' ? 'summary_macro' : 'summary_block',
            macroContent: ''
        };
    }

    return {
        messages: [{
            role: 'system',
            content,
            blockName: 'Memory Book',
            isMemory: true,
            sources: [{ source: 'memory', tokens }],
            _allSources: [{ source: 'memory', tokens }]
        }],
        entries: topEntries,
        tokens,
        injectionTarget: settings.injectionTarget === 'summary_macro' ? 'summary_macro' : 'summary_block',
        macroContent
    };
}
