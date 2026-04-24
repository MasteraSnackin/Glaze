import { db } from '@/utils/db.js';
import { getEmbeddings } from '@/core/services/embeddingService.js';
import { getEmbeddingConfig, isEmbeddingConfigured } from '@/core/config/embeddingSettings.js';

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
    const seen = new Set();
    const result = [];
    for (const value of hints) {
        const raw = String(value || '').trim();
        const normalized = String(raw || '')
            .toLowerCase()
            .replace(/[^\p{L}\p{N}\s-]+/gu, ' ')
            .replace(/\s+/g, ' ')
            .trim();
        if (!normalized || seen.has(normalized)) continue;
        seen.add(normalized);
        result.push(raw);
        if (result.length >= 32) break;
    }
    return result;
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
