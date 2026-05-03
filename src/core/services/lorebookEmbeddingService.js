import { lorebookState } from '@/core/states/lorebookState.js';
import { getEmbeddings } from '@/core/services/embeddingService.js';
import { getEmbeddingConfig, isEmbeddingConfigured } from '@/core/config/embeddingSettings.js';
import { db } from '@/utils/db.js';

function uniqueStrings(values = [], limit = 32) {
    const seen = new Set();
    const result = [];
    for (const value of values) {
        const raw = String(value || '').trim();
        const normalized = raw
            .toLowerCase()
            .replace(/[^\p{L}\p{N}\s-]+/gu, ' ')
            .replace(/\s+/g, ' ')
            .trim();
        if (!normalized || seen.has(normalized)) continue;
        seen.add(normalized);
        result.push(raw);
        if (result.length >= limit) break;
    }
    return result;
}

function extractRetrievalHints(entry) {
    const hints = [];

    if (entry.comment) hints.push(String(entry.comment));
    if (Array.isArray(entry.keys)) hints.push(...entry.keys.map(v => String(v)));

    const content = String(entry.content || '');
    if (content) {
        const lines = content
            .split(/\r?\n/)
            .map(line => line.trim())
            .filter(Boolean)
            .slice(0, 8);

        hints.push(...lines);

        for (const line of lines) {
            const colonIndex = line.indexOf(':');
            if (colonIndex > 0) {
                const label = line.slice(0, colonIndex).trim();
                const value = line.slice(colonIndex + 1).trim();
                if (label) hints.push(label);
                if (value) {
                    hints.push(value);
                    value.split(/[;,]|\band\b|\bи\b/iu)
                        .map(part => part.trim())
                        .filter(Boolean)
                        .forEach(part => hints.push(part));
                }
            }
        }
    }

    return uniqueStrings(hints, 32);
}

function buildEmbeddingRecord(entry, lorebookId, vectorsData, textHash) {
    return {
        id: entry.id,
        sourceType: 'lorebook_entry',
        sourceId: lorebookId,
        vectors: vectorsData,
        vector: null,
        textHash,
        retrievalHints: extractRetrievalHints(entry),
        updatedAt: Date.now()
    };
}

function buildEmbeddingErrorRecord(entry, lorebookId, textHash, error) {
    return {
        id: entry.id,
        sourceType: 'lorebook_entry',
        sourceId: lorebookId,
        vectors: null,
        vector: null,
        textHash,
        retrievalHints: extractRetrievalHints(entry),
        error,
        updatedAt: Date.now()
    };
}

function getIndexingErrorDetails(type, message = '') {
    const safeMessage = String(message || '').trim();
    return {
        type,
        message: safeMessage,
        retryable: !['empty_text', 'missing_entry_id'].includes(type),
        updatedAt: Date.now()
    };
}

function classifyIndexingError(error) {
    const message = String(error?.message || error || '').trim();
    const lower = message.toLowerCase();

    if (lower.includes('timeout') || lower.includes('timed out') || lower.includes('abort')) {
        return getIndexingErrorDetails('timeout', message || 'Embedding request timed out');
    }
    if (lower.includes('endpoint not configured')) {
        return getIndexingErrorDetails('config_endpoint', message || 'Embedding endpoint not configured');
    }
    if (lower.includes('model not configured')) {
        return getIndexingErrorDetails('config_model', message || 'Embedding model not configured');
    }
    if (lower.includes('embedding api error')) {
        if (error?.status === 429 || lower.includes('429') || lower.includes('rate limit')) {
            return getIndexingErrorDetails('rate_limit', message || 'Provider rate limit reached (429)');
        }
        return getIndexingErrorDetails('api_error', message || 'Embedding API request failed');
    }
    if (lower.includes('embedding provider error')) {
        return getIndexingErrorDetails('api_error', message || 'Embedding provider request failed');
    }
    if (error?.name === 'RateLimitError' || error?.status === 429) {
        return getIndexingErrorDetails('rate_limit', message || 'Provider rate limit reached (429)');
    }
    if (lower.includes('failed to fetch') || lower.includes('networkerror') || lower.includes('network error')) {
        return getIndexingErrorDetails('network_error', message || 'Network error while requesting embeddings');
    }
    if (lower.includes('invalid embedding response')) {
        return getIndexingErrorDetails('invalid_response', message || 'Embedding API returned an invalid response');
    }

    return getIndexingErrorDetails('unknown', message || 'Unknown indexing error');
}

export function getEntryIndexingText(entry, target) {
    return (target === 'keys'
        ? (entry.keys || []).join(', ')
        : (entry.content || '')).trim();
}

async function saveEmbeddingError(entry, lorebookId, textHash, error) {
    await db.saveEmbedding(buildEmbeddingErrorRecord(entry, lorebookId, textHash, error));
}

export function buildEmbeddingFingerprint(entry, text) {
    return JSON.stringify({
        text,
        retrievalHints: extractRetrievalHints(entry)
    });
}

export async function computeTextHash(text) {
    const encoder = new TextEncoder();
    const data = encoder.encode(text);
    const hashBuffer = await crypto.subtle.digest('SHA-256', data);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
}

export async function indexLorebookEntry(entry, lorebookId) {
    if (!isEmbeddingConfigured()) return;
    if (!entry.id) {
        throw new Error('Entry ID is missing');
    }

    const config = getEmbeddingConfig();
    const target = lorebookState.globalSettings.embeddingTarget || config.target || 'content';
    const text = getEntryIndexingText(entry, target);

    const textHash = await computeTextHash(buildEmbeddingFingerprint(entry, text));

    if (!text) {
        const error = getIndexingErrorDetails('empty_text', 'Entry text is empty for current embedding target');
        await saveEmbeddingError(entry, lorebookId, textHash, error);
        throw new Error(error.message);
    }

    const existing = await db.getEmbedding(entry.id);
    if (existing && existing.textHash === textHash) return;

    const vectorsData = await getEmbeddings([text]);
    console.log('[indexLorebookEntry] embedding result', {
        entryId: entry.id,
        entryName: entry.comment || entry.keys?.[0],
        textLength: text.length,
        vectorsData,
        hasVectorsData: !!vectorsData,
        firstChunk: vectorsData?.[0]?.[0]
    });
    
    if (!vectorsData || !vectorsData[0] || vectorsData[0].length === 0) {
        const error = getIndexingErrorDetails('empty_embedding', 'Embedding API returned no vector');
        await saveEmbeddingError(entry, lorebookId, textHash, error);
        throw new Error(error.message);
    }

    await db.saveEmbedding(buildEmbeddingRecord(entry, lorebookId, vectorsData[0], textHash));
}

export async function indexLorebookEntries(lorebookId, onProgress, options = {}) {
    const lb = lorebookState.lorebooks.find(l => l.id === lorebookId);
    if (!lb) return { indexed: 0, skipped: 0, failed: 0, total: 0 };

    const retryFailedOnly = options.retryFailedOnly === true;
    const entries = lb.entries.filter(e => e.enabled !== false && e.vectorSearch);
    if (entries.length === 0) return { indexed: 0, skipped: 0, failed: 0, total: 0, failures: [], retriedFailedOnly: retryFailedOnly };

    const config = getEmbeddingConfig();
    let indexed = 0;
    let skipped = 0;
    let failed = 0;
    const failures = [];
    const processedEntries = [];

    for (const entry of entries) {
        if (!retryFailedOnly) {
            processedEntries.push(entry);
            continue;
        }

        const existing = await db.getEmbedding(entry.id);
        if (existing?.error) {
            processedEntries.push(entry);
        }
    }

    if (processedEntries.length === 0) {
        return { indexed: 0, skipped: 0, failed: 0, total: 0, failures: [], retriedFailedOnly: retryFailedOnly };
    }

    for (let i = 0; i < processedEntries.length; i++) {
        const entry = processedEntries[i];
        const target = lorebookState.globalSettings.embeddingTarget || config.target || 'content';
        const text = getEntryIndexingText(entry, target);
        const textHash = await computeTextHash(buildEmbeddingFingerprint(entry, text));

        if (!text) {
            const error = getIndexingErrorDetails('empty_text', 'Entry text is empty for current embedding target');
            await saveEmbeddingError(entry, lb.id, textHash, error);
            failures.push({ entryId: entry.id, comment: entry.comment || '', keys: entry.keys || [], error });
            failed++;
            if (onProgress) onProgress(i + 1, processedEntries.length);
            continue;
        }

        const existing = await db.getEmbedding(entry.id);
        const isLegacyFormat = existing && existing.vector && !existing.vectors;
        if (existing && existing.textHash === textHash && !isLegacyFormat && !existing.error) {
            console.log('[indexLorebookEntries] skipping (already indexed)', {
                entryId: entry.id,
                comment: entry.comment?.substring(0, 50),
                hasVectors: !!existing.vectors,
                hasVector: !!existing.vector
            });
            skipped++;
            if (onProgress) onProgress(i + 1, processedEntries.length);
            continue;
        }
        
        if (isLegacyFormat) {
            console.log('[indexLorebookEntries] reindexing legacy entry', {
                entryId: entry.id,
                comment: entry.comment?.substring(0, 50)
            });
        }

        try {
            const vectors = await getEmbeddings([text]);
            console.log('[indexLorebookEntry] embedding result', {
                entryId: entry.id,
                entryName: entry.comment?.substring(0, 50),
                textLength: text.length,
                vectorsData: vectors?.[0],
                hasVectorsData: !!vectors?.[0],
                firstChunk: vectors?.[0]?.[0]
            });
            if (vectors && vectors[0]) {
                await db.saveEmbedding(buildEmbeddingRecord(entry, lorebookId, vectors[0], textHash));
                indexed++;
            } else {
                const error = getIndexingErrorDetails('empty_embedding', 'Embedding API returned no vector');
                await saveEmbeddingError(entry, lb.id, textHash, error);
                failures.push({ entryId: entry.id, comment: entry.comment || '', keys: entry.keys || [], error });
                failed++;
            }
        } catch (e) {
            console.warn('[indexLorebookEntries] Failed for entry', entry.id, e);
            const error = classifyIndexingError(e);
            await saveEmbeddingError(entry, lb.id, textHash, error);
            failures.push({ entryId: entry.id, comment: entry.comment || '', keys: entry.keys || [], error });
            failed++;
            if (error.type === 'rate_limit') {
                const retryAfter = e.retryAfter || 60;
                for (let j = i + 1; j < processedEntries.length; j++) {
                    const skippedEntry = processedEntries[j];
                    const skippedText = getEntryIndexingText(skippedEntry, target);
                    const skippedHash = await computeTextHash(buildEmbeddingFingerprint(skippedEntry, skippedText));
                    const skipError = getIndexingErrorDetails('rate_limit', `Skipped due to rate limit (retry after ${retryAfter}s)`);
                    skipError.retryAfter = retryAfter;
                    await saveEmbeddingError(skippedEntry, lb.id, skippedHash, skipError);
                    failures.push({ entryId: skippedEntry.id, comment: skippedEntry.comment || '', keys: skippedEntry.keys || [], error: skipError });
                    failed++;
                }
                return { indexed, skipped, failed, total: processedEntries.length, failures, retriedFailedOnly: retryFailedOnly, rateLimited: true, retryAfter };
            }
        }

        if (onProgress) onProgress(i + 1, processedEntries.length);
    }

    return { indexed, skipped, failed, total: processedEntries.length, failures, retriedFailedOnly: retryFailedOnly };
}

export async function getEmbeddingRecord(entryId) {
    return db.getEmbedding(entryId);
}

export async function isLorebookEmbeddingFresh(entry) {
    if (!entry?.id) return false;
    const record = await db.getEmbedding(entry.id);
    if (!record || record.error) return false;

    const config = getEmbeddingConfig();
    const target = lorebookState.globalSettings.embeddingTarget || config.target || 'content';
    const text = getEntryIndexingText(entry, target);
    const textHash = await computeTextHash(buildEmbeddingFingerprint(entry, text));
    return record.textHash === textHash;
}

export async function getEmbeddingStatus(entryOrId) {
    const entryId = typeof entryOrId === 'string' ? entryOrId : entryOrId?.id;
    const record = await db.getEmbedding(entryId);
    if (!record) return 'none';
    if (record.error) return 'error';

    if (typeof entryOrId === 'object' && entryOrId) {
        const isFresh = await isLorebookEmbeddingFresh(entryOrId);
        return isFresh ? 'indexed' : 'stale';
    }

    return 'indexed';
}

export async function deleteLorebookEntryEmbedding(entryId) {
    if (!entryId) return;
    await db.deleteEmbedding(entryId);
}

export async function deleteLorebookEmbeddings(lorebookId) {
    const allEmbeddings = await db.getEmbeddingsBySource('lorebook_entry');
    const targets = allEmbeddings.filter(record => record.sourceId === lorebookId);
    for (const record of targets) {
        await db.deleteEmbedding(record.id);
    }
}
