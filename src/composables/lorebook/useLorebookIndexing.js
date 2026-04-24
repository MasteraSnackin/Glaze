import { ref } from 'vue';
import { lorebookState, deleteLorebookEmbeddings, indexLorebookEntries, indexLorebookEntry, getEmbeddingStatus, getEmbeddingRecord } from '@/core/states/lorebookState.js';

export function useLorebookIndexing({ activeLorebook, activeEntry }) {
    const indexingEntry = ref(false);
    const entryEmbeddingStatus = ref('none');
    const indexProgress = ref(null);
    const indexedEntryIds = ref(new Set());
    const needsVectorReindex = ref(false);
    const missingVectorCount = ref(0);
    const rateLimitCooldown = ref(0);
    let rateLimitTimer = null;

    function startRateLimitCooldown(seconds) {
        rateLimitCooldown.value = seconds;
        if (rateLimitTimer) clearInterval(rateLimitTimer);
        rateLimitTimer = setInterval(() => {
            rateLimitCooldown.value--;
            if (rateLimitCooldown.value <= 0) {
                rateLimitCooldown.value = 0;
                clearInterval(rateLimitTimer);
                rateLimitTimer = null;
            }
        }, 1000);
    }

    async function checkEntryEmbeddingStatus() {
        if (activeEntry.value?.vectorSearch && activeEntry.value?.id) {
            entryEmbeddingStatus.value = await getEmbeddingStatus(activeEntry.value);
        } else {
            entryEmbeddingStatus.value = 'none';
        }
    }

    async function updateVectorReindexNotice() {
        const vectorEntries = lorebookState.lorebooks.flatMap(lb =>
            (lb.entries || []).filter(entry => entry.enabled !== false && entry.vectorSearch && entry.id)
        );

        if (vectorEntries.length === 0) {
            missingVectorCount.value = 0;
            needsVectorReindex.value = false;
            return;
        }

        let missing = 0;
        for (const entry of vectorEntries) {
            const status = await getEmbeddingStatus(entry);
            if (status !== 'indexed') missing++;
        }

        missingVectorCount.value = missing;
        needsVectorReindex.value = missing > 0;
    }

    async function loadIndexedStatuses() {
        if (!activeLorebook.value) return;
        const ids = new Set();
        const failed = new Map();
        for (const entry of activeLorebook.value.entries) {
            if (entry.vectorSearch && entry.id) {
                const status = await getEmbeddingStatus(entry);
                if (status === 'indexed') ids.add(entry.id);
                if (status === 'error') {
                    const record = await getEmbeddingRecord(entry.id);
                    if (record?.error) failed.set(entry.id, record.error);
                }
            }
        }
        indexedEntryIds.value = ids;
        return failed;
    }

    async function handleIndexEntry() {
        if (!activeEntry.value || !activeLorebook.value) return;
        indexingEntry.value = true;
        try {
            await indexLorebookEntry(activeEntry.value, activeLorebook.value.id);
        } catch (e) {
            console.warn('Failed to index entry:', e);
        } finally {
            await loadIndexedStatuses();
            await checkEntryEmbeddingStatus();
            indexingEntry.value = false;
        }
    }

    async function handleIndexAllEntries() {
        if (!activeLorebook.value) return;
        indexingEntry.value = true;
        indexProgress.value = null;
        try {
            const result = await indexLorebookEntries(activeLorebook.value.id, (done, total) => {
                indexProgress.value = { done, total };
            });
            indexProgress.value = result;
            if (result.rateLimited) {
                startRateLimitCooldown(result.retryAfter || 60);
            }
            await loadIndexedStatuses();
        } catch (e) {
            console.warn('Failed to index lorebook:', e);
        } finally {
            indexingEntry.value = false;
        }
    }

    async function handleRetryFailedEntries() {
        if (!activeLorebook.value) return;
        indexingEntry.value = true;
        indexProgress.value = null;
        try {
            const result = await indexLorebookEntries(activeLorebook.value.id, (done, total) => {
                indexProgress.value = { done, total };
            }, { retryFailedOnly: true });
            indexProgress.value = result;
            if (result.rateLimited) {
                startRateLimitCooldown(result.retryAfter || 60);
            }
            await loadIndexedStatuses();
            await updateVectorReindexNotice();
        } catch (e) {
            console.warn('Failed to retry failed lorebook entries:', e);
        } finally {
            indexingEntry.value = false;
        }
    }

    async function handleDeleteAllIndexes() {
        if (!activeLorebook.value) return;
        indexingEntry.value = true;
        indexProgress.value = null;
        try {
            await deleteLorebookEmbeddings(activeLorebook.value.id);
            indexedEntryIds.value = new Set();
            entryEmbeddingStatus.value = 'none';
            await updateVectorReindexNotice();
        } catch (e) {
            console.warn('Failed to delete lorebook embeddings:', e);
        } finally {
            indexingEntry.value = false;
        }
    }

    return {
        indexingEntry,
        entryEmbeddingStatus,
        indexProgress,
        indexedEntryIds,
        needsVectorReindex,
        missingVectorCount,
        rateLimitCooldown,
        checkEntryEmbeddingStatus,
        updateVectorReindexNotice,
        loadIndexedStatuses,
        handleIndexEntry,
        handleIndexAllEntries,
        handleRetryFailedEntries,
        handleDeleteAllIndexes
    };
}
