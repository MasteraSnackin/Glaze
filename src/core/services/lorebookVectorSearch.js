import { lorebookState } from '@/core/states/lorebookState.js';
import { getEmbeddings } from '@/core/services/embeddingService.js';
import { getEmbeddingConfig, isEmbeddingConfigured } from '@/core/config/embeddingSettings.js';
import { findTopKMulti } from '@/utils/vectorMath.js';
import { estimateTokens } from '@/utils/tokenizer.js';
import { getEntryIndexingText, computeTextHash, buildEmbeddingFingerprint } from '@/core/services/lorebookEmbeddingService.js';
import { db } from '@/utils/db.js';

function normalizeHybridText(text = '') {
    return text
        .toLowerCase()
        .replace(/[^\p{L}\p{N}\s-]+/gu, ' ')
        .replace(/\s+/g, ' ')
        .trim();
}

function getHybridTokens(text = '') {
    return normalizeHybridText(text)
        .split(' ')
        .filter(token => token.length >= 3);
}

function getEntryDescriptorTexts(entry) {
    const descriptors = [];
    if (entry.comment) descriptors.push(String(entry.comment));
    if (Array.isArray(entry.keys)) descriptors.push(...entry.keys.map(v => String(v)));

    const content = String(entry.content || '');
    if (content) {
        const lines = content
            .split(/\r?\n/)
            .map(line => line.trim())
            .filter(Boolean)
            .slice(0, 4);
        descriptors.push(...lines);
    }

    return descriptors;
}

function htmlToPlainText(text) {
    if (typeof document === 'undefined') {
        return text.replace(/<br\s*\/?>/gi, '\n').replace(/<[^>]+>/g, ' ');
    }

    const div = document.createElement('div');
    div.innerHTML = text.replace(/<br\s*\/?>/gi, '\n');
    return div.textContent || div.innerText || text;
}

function sanitizeVectorQueryText(text = '') {
    if (!text) return '';

    const withoutHeavyBlocks = String(text)
        .replace(/<style[\s\S]*?(?:<\/style>|$)/gi, ' ')
        .replace(/<script[\s\S]*?(?:<\/script>|$)/gi, ' ')
        .replace(/<svg[\s\S]*?(?:<\/svg>|$)/gi, ' ')
        .replace(/<figure[\s\S]*?(?:<\/figure>|$)/gi, ' ')
        .replace(/<img\b[^>]*>/gi, ' ')
        .replace(/!\[[^\]]*\]\((?:data:image[^)]*|https?:\/\/[^)\s]+\.(?:png|jpe?g|gif|webp|bmp|svg)(?:\?[^)]*)?)\)/gi, ' ')
        .replace(/data:image\/[a-zA-Z0-9.+-]+;base64,[a-zA-Z0-9+/=\s_-]+/g, ' ')
        .replace(/https?:\/\/\S+\.(?:png|jpe?g|gif|webp|bmp|svg)(?:\?\S*)?/gi, ' ')
        .replace(/\bimggen-(?:loading|result|error|disabled|options-btn|result-wrapper)\b/gi, ' ');

    const plainText = htmlToPlainText(withoutHeavyBlocks);

    return plainText
        .replace(/<lemma[\s\S]*?<\/think>/gi, ' ')
        .replace(/\[image omitted\]/gi, ' ')
        .replace(/[\t\r ]+/g, ' ')
        .replace(/\n{3,}/g, '\n\n')
        .trim();
}

function scoreHybridBoost(entry, queryText) {
    const normalizedQuery = normalizeHybridText(queryText);
    if (!normalizedQuery) return 0;

    const queryTokens = new Set(getHybridTokens(queryText));
    if (queryTokens.size === 0) return 0;

    let boost = 0;
    const names = [entry.comment, ...(Array.isArray(entry.keys) ? entry.keys : [])]
        .filter(Boolean)
        .map(value => String(value));

    for (const name of names) {
        const normalizedName = normalizeHybridText(name);
        if (!normalizedName) continue;

        if (normalizedQuery.includes(normalizedName)) {
            boost = Math.max(boost, 0.18);
        }

        const nameTokens = getHybridTokens(name);
        let overlap = 0;
        for (const token of nameTokens) {
            if (queryTokens.has(token)) overlap++;
        }

        if (overlap > 0) {
            boost = Math.max(boost, Math.min(0.12, overlap * 0.04));
        }
    }

    return boost;
}

function scoreDescriptorBoost(entry, queryText) {
    const queryTokens = new Set(getHybridTokens(queryText));
    if (queryTokens.size === 0) return 0;

    let boost = 0;
    const descriptors = [
        ...getEntryDescriptorTexts(entry),
        ...(Array.isArray(entry.retrievalHints) ? entry.retrievalHints : [])
    ];

    for (const descriptor of descriptors) {
        const descriptorTokens = getHybridTokens(descriptor);
        if (descriptorTokens.length === 0) continue;

        let overlap = 0;
        for (const token of descriptorTokens) {
            if (queryTokens.has(token)) overlap++;
        }

        if (overlap > 0) {
            boost = Math.max(boost, Math.min(0.1, overlap * 0.025));
        }
    }

    return boost;
}

function buildBoundedQueryText(parts, {
    maxTokens = 1536,
    maxChars = 12000,
    trimEachPartToChars = 4000
} = {}) {
    const normalizedParts = [];

    for (let i = parts.length - 1; i >= 0; i--) {
        const raw = String(parts[i] || '').trim();
        if (!raw) continue;

        const trimmedPart = raw.length > trimEachPartToChars
            ? raw.slice(-trimEachPartToChars)
            : raw;

        normalizedParts.unshift(trimmedPart);

        const candidate = normalizedParts.join('\n');
        if (candidate.length > maxChars || estimateTokens(candidate) > maxTokens) {
            normalizedParts.shift();
            break;
        }
    }

    return normalizedParts.join('\n');
}

function stripOOC(text) {
    return text.replace(/\[OOC:\s*/gi, '').replace(/\(OOC:\s*/gi, '').replace(/\s*\]\s*/g, ' ').replace(/\s*\)\s*/g, ' ').trim();
}

export async function vectorSearchLorebooks(history = [], currentText = '', char = null, chatId = null) {
    if (lorebookState.globalSettings.searchType === 'keys') {
        console.info('[vectorSearchLorebooks] skipped: keys-only search mode');
        return [];
    }

    const config = getEmbeddingConfig();
    if (!isEmbeddingConfigured()) {
        console.info('[vectorSearchLorebooks] skipped: embedding config incomplete');
        return [];
    }

    const charId = char?.id;

    const activeLorebooks = lorebookState.lorebooks.filter(lb => {
        if (lb.enabled) return true;
        if (charId && lorebookState.activations?.character?.[charId]?.includes(lb.id)) return true;
        if (chatId && lorebookState.activations?.chat?.[chatId]?.includes(lb.id)) return true;
        return false;
    });

    if (activeLorebooks.length === 0) {
        console.info('[vectorSearchLorebooks] skipped: no active lorebooks for context', {
            charId,
            chatId,
            totalLorebooks: lorebookState.lorebooks.length
        });
        return [];
    }

    const vectorEntries = [];
    activeLorebooks.forEach(lb => {
        lb.entries.forEach(entry => {
            if (entry.enabled !== false && entry.vectorSearch) {
                if (char && entry.characterFilter) {
                    const { isExclude, names } = entry.characterFilter;
                    if (names && names.length > 0) {
                        const charName = (char.name || "").toLowerCase();
                        const isInCategory = names.some(n => charName.includes(n.toLowerCase()));
                        if (isExclude && isInCategory) return;
                        if (!isExclude && !isInCategory) return;
                    }
                }
                vectorEntries.push({ ...entry, lorebookName: lb.name, lorebookId: lb.id });
            }
        });
    });

    if (vectorEntries.length === 0) {
        console.info('[vectorSearchLorebooks] skipped: no vector-enabled entries', {
            activeLorebooks: activeLorebooks.length
        });
        return [];
    }

    const allEmbeddings = await db.getEmbeddingsBySource('lorebook_entry');
    const embeddingMap = new Map(allEmbeddings.map(e => [e.id, e]));

    const candidates = [];
    const missingEmbeddings = [];
    const target = lorebookState.globalSettings.embeddingTarget || config.target || 'content';
    for (const entry of vectorEntries) {
        const emb = embeddingMap.get(entry.id);
        const currentText = getEntryIndexingText(entry, target);
        const currentHash = await computeTextHash(buildEmbeddingFingerprint(entry, currentText));
        const isFresh = emb?.textHash === currentHash;

        if (emb && isFresh && (emb.vectors || emb.vector)) {
            const candidate = { ...entry, retrievalHints: emb.retrievalHints || [] };
            if (emb.vectors) {
                candidate.vectors = emb.vectors;
            } else if (emb.vector) {
                candidate.vector = emb.vector;
            }
            candidates.push(candidate);
        } else {
            missingEmbeddings.push({
                id: entry.id,
                comment: entry.comment,
                hasEmb: !!emb,
                isFresh,
                hasVectors: emb?.vectors ? true : false,
                hasVector: emb?.vector ? true : false,
                reason: emb ? 'stale_or_invalid' : 'missing'
            });
        }
    }
    
    if (missingEmbeddings.length > 0) {
        console.warn('[vectorSearchLorebooks] entries missing embeddings', {
            count: missingEmbeddings.length,
            entries: missingEmbeddings
        });
    }

    if (candidates.length === 0) {
        console.info('[vectorSearchLorebooks] skipped: no indexed vector candidates', {
            vectorEntries: vectorEntries.length,
            storedEmbeddings: allEmbeddings.length
        });
        return [];
    }

    const scanDepth = config.scanDepth || 5;
    const recentHistory = history.slice(-scanDepth);
    const recentUserParts = recentHistory
        .filter(m => m.role === 'user')
        .map(m => m.content)
        .filter(Boolean);
    const currentTextTrimmed = currentText && currentText.trim() ? currentText.trim() : '';
    const focusedQueryParts = recentUserParts.length > 0 ? [...recentUserParts] : [];
    if (currentTextTrimmed) {
        focusedQueryParts.push(currentTextTrimmed);
    }
    const fallbackQueryParts = recentHistory.map(m => m.content).filter(Boolean);
    if (currentTextTrimmed) {
        fallbackQueryParts.push(currentTextTrimmed);
    }

    const embeddingConfig = getEmbeddingConfig();
    const queryChunkTokens = Math.max(embeddingConfig.maxChunkTokens || 512, 128);
    const focusedQueryText = buildBoundedQueryText(focusedQueryParts, {
        maxTokens: Math.min(queryChunkTokens * 2, 1024),
        maxChars: 6000,
        trimEachPartToChars: 3000
    });
    const fallbackQueryText = buildBoundedQueryText(fallbackQueryParts, {
        maxTokens: Math.min(queryChunkTokens * 3, 1536),
        maxChars: 10000,
        trimEachPartToChars: 4000
    });
    const queryText = focusedQueryText || fallbackQueryText;
    if (!queryText.trim()) {
        console.info('[vectorSearchLorebooks] skipped: empty query text', {
            historyMessages: history.length,
            hasCurrentText: !!(currentText && currentText.trim())
        });
        return [];
    }

    const globalSettings = lorebookState.globalSettings;
    const effectiveThreshold = globalSettings.vectorThreshold || 0.45;
    const effectiveTopK = globalSettings.vectorTopK || 10;

    console.info('[vectorSearchLorebooks] querying embeddings', {
        charId,
        chatId,
        activeLorebooks: activeLorebooks.length,
        vectorEntries: vectorEntries.length,
        indexedCandidates: candidates.length,
        historyMessages: history.length,
        userMessagesUsed: recentUserParts.length,
        rawFocusedParts: focusedQueryParts.length,
        rawFallbackParts: fallbackQueryParts.length,
        focusedQueryLength: focusedQueryText.length,
        fallbackQueryLength: fallbackQueryText.length,
        hasCurrentText: !!(currentText && currentText.trim()),
        queryLength: queryText.length,
        threshold: effectiveThreshold,
        topK: effectiveTopK,
        usingGlobalSettings: true
    });

    try {
        const hybridQueryText = focusedQueryText || fallbackQueryText;

        const runSearch = async (text, label) => {
            if (!text || !text.trim()) return [];
            const cleanText = sanitizeVectorQueryText(stripOOC(text));
            if (!cleanText) {
                console.info('[vectorSearchLorebooks] skipped: sanitized query became empty', { label });
                return [];
            }
            console.info('[vectorSearchLorebooks] embedding query', {
                label,
                queryLength: cleanText.length,
                queryPreview: cleanText.substring(0, 200),
                originalPreview: text.substring(0, 200)
            });
            const queryVectorsData = await getEmbeddings([cleanText]);
            if (!queryVectorsData || !queryVectorsData[0] || !queryVectorsData[0][0]?.vector) {
                console.info('[vectorSearchLorebooks] skipped: embedding API returned no query vector', { label });
                return [];
            }

            const queryChunks = queryVectorsData[0];
            console.info('[vectorSearchLorebooks] query chunks', {
                label,
                chunksCount: queryChunks.length,
                chunks: queryChunks.map(c => ({
                    textPreview: c.text?.substring(0, 80),
                    vectorLength: c.vector?.length
                }))
            });

            const vectorResults = findTopKMulti(queryChunks, candidates, candidates.length, 0);
            
            console.info('[vectorSearchLorebooks] raw similarity scores', {
                label,
                totalResults: vectorResults.length,
                top15: vectorResults.slice(0, 15).map(r => ({
                    id: r.id,
                    comment: r.comment,
                    rawScore: r.score.toFixed(4),
                    hasVectors: !!r.vectors,
                    hasVector: !!r.vector,
                    chunksCount: r.vectors?.length || 1
                }))
            });
            
            return vectorResults.map(result => {
                const hybridBoost = scoreHybridBoost(result, hybridQueryText);
                const descriptorBoost = scoreDescriptorBoost(result, hybridQueryText);
                return {
                    ...result,
                    score: Math.min(1, result.score + hybridBoost + descriptorBoost),
                    hybridBoost,
                    descriptorBoost,
                    searchLabel: label
                };
            });
        };

        const focusedResults = await runSearch(focusedQueryText, 'focused');
        let fallbackResults = [];
        if (fallbackQueryText && fallbackQueryText !== focusedQueryText) {
            console.info('[vectorSearchLorebooks] retrying with fallback query');
            fallbackResults = await runSearch(fallbackQueryText, 'fallback');
        }

        const combined = new Map();
        for (const result of [...focusedResults, ...fallbackResults]) {
            const existing = combined.get(result.id);
            if (!existing || result.score > existing.score) {
                combined.set(result.id, result);
            }
        }

        const results = Array.from(combined.values())
            .sort((a, b) => b.score - a.score)
            .filter(result => result.score >= effectiveThreshold)
            .slice(0, effectiveTopK);

        console.info('[vectorSearchLorebooks] results ready', {
            matches: results.length,
            topScores: results.slice(0, 15).map(r => ({
                id: r.id,
                name: r.comment || r.keys?.[0] || 'Entry',
                lorebookName: r.lorebookName,
                score: Number(r.score?.toFixed?.(4) || r.score),
                hybridBoost: Number(r.hybridBoost?.toFixed?.(4) || r.hybridBoost || 0),
                descriptorBoost: Number(r.descriptorBoost?.toFixed?.(4) || r.descriptorBoost || 0),
                source: r.searchLabel
            }))
        });
        return results.map(r => ({
            ...r,
            vectorScore: r.score,
            vector: undefined
        }));
    } catch (e) {
        console.warn('[vectorSearchLorebooks] Error:', e);
        throw e;
    }
}
