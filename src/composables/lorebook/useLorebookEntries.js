import { ref, computed } from 'vue';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { deleteLorebookEntryEmbedding } from '@/core/states/lorebookState.js';
import { saveFile } from '@/core/services/fileSaver.js';
import { exportSTLorebook } from '@/core/states/lorebookState.js';
import { showToast } from '@/core/states/toastState.js';

export function useLorebookEntries({ activeLorebook, activeEntry, activeEntryIndex, currentView, t, indexingDeps }) {
    const searchQuery = ref('');
    const failedEntryMap = ref(new Map());

    const {
        checkEntryEmbeddingStatus,
        loadIndexedStatuses,
        updateVectorReindexNotice,
        handleIndexAllEntries,
        handleDeleteAllIndexes
    } = indexingDeps;

    const filteredEntries = computed(() => {
        if (!activeLorebook.value) return [];
        if (!searchQuery.value) return activeLorebook.value.entries;
        const q = searchQuery.value.toLowerCase();
        return activeLorebook.value.entries.filter(e =>
            e.keys.some(k => k.toLowerCase().includes(q)) ||
            e.content.toLowerCase().includes(q)
        );
    });

    const failedEntries = computed(() => {
        if (!activeLorebook.value) return [];
        return activeLorebook.value.entries
            .filter(entry => failedEntryMap.value.has(entry.id))
            .map(entry => ({ entry, error: failedEntryMap.value.get(entry.id) }));
    });

    const allVectorEnabled = computed(() => {
        if (!activeLorebook.value || activeLorebook.value.entries.length === 0) return false;
        return activeLorebook.value.entries.every(e => e.vectorSearch);
    });

    const characterFilterExclude = computed({
        get: () => activeEntry.value?.characterFilter?.isExclude || false,
        set: (val) => {
            if (activeEntry.value) {
                if (!activeEntry.value.characterFilter) {
                    activeEntry.value.characterFilter = { names: [], isExclude: false };
                }
                activeEntry.value.characterFilter.isExclude = val;
            }
        }
    });

    function handleCreateEntry() {
        if (!activeLorebook.value) return;
        const newEntry = {
            id: Date.now().toString(36) + Math.random().toString(36).substr(2, 5),
            keys: [],
            content: '',
            enabled: true,
            secondary_keys: [],
            comment: '',
            order: 100,
            caseSensitive: null,
            matchWholeWords: null,
            useGroupScoring: null,
            vectorSearch: false,
            useKeywordSearch: true
        };
        activeLorebook.value.entries.push(newEntry);
        selectEntry(newEntry, activeLorebook.value.entries.length - 1);
    }

    function selectEntry(entry, index) {
        if (entry.useKeywordSearch === undefined) {
            entry.useKeywordSearch = true;
        }
        activeEntry.value = entry;
        activeEntryIndex.value = index;
        if (currentView) currentView.value = 'edit_entry';
        checkEntryEmbeddingStatus();
    }

    async function handleDeleteEntry(index) {
        if (!activeLorebook.value) return;
        const entry = activeLorebook.value.entries[index];
        if (entry?.id) {
            await deleteLorebookEntryEmbedding(entry.id);
            failedEntryMap.value.delete(entry.id);
        }
        activeLorebook.value.entries.splice(index, 1);
        await updateVectorReindexNotice();
        await loadIndexedStatuses();
    }

    async function handleConstantToggle(isEnabled) {
        if (!activeEntry.value?.id) return;
        if (!isEnabled) return;
        activeEntry.value.vectorSearch = false;
        await deleteLorebookEntryEmbedding(activeEntry.value.id);
        await loadIndexedStatuses();
        await checkEntryEmbeddingStatus();
        await updateVectorReindexNotice();
    }

    function handleEntryMenu(entry, index) {
        const entryError = failedEntryMap.value.get(entry.id);
        showBottomSheet({
            title: entry.comment || t('unnamed_entry'),
            items: [
                ...(entryError ? [{
                    label: t('vector_status_error') || 'Index error',
                    description: getEmbeddingErrorMessage(entryError),
                    icon: '<svg viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>',
                    iconColor: '#ff9500',
                    onClick: () => { closeBottomSheet(); }
                }] : []),
                {
                    label: t('action_export') || 'Export',
                    icon: '<svg viewBox="0 0 24 24"><path d="M19 12v7H5v-7H3v7c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2v-7h-2zm-6 .67l2.59-2.58L17 11.5l-5 5-5-5 1.41-1.41L11 12.67V3h2v9.67z"/></svg>',
                    onClick: async () => {
                        closeBottomSheet();
                        const stLb = exportSTLorebook({ entries: [entry] });
                        const filename = (entry.comment || 'entry') + '.json';
                        await saveFile(filename, JSON.stringify(stLb, null, 2), 'application/json', 'lorebooks');
                    }
                },
                {
                    label: t('btn_delete') || 'Delete',
                    icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                    iconColor: '#ff4444',
                    isDestructive: true,
                    onClick: async () => {
                        await handleDeleteEntry(index);
                        closeBottomSheet();
                    }
                }
            ]
        });
    }

    function openEntriesMenu() {
        if (!activeLorebook.value) return;
        const allVector = activeLorebook.value.entries.every(e => e.vectorSearch);
        showBottomSheet({
            title: t('section_entries_actions') || 'Entries Actions',
            items: [
                {
                    label: allVector ? (t('action_disable_vector_all') || 'Disable Vector Search All') : (t('action_enable_vector_all') || 'Enable Vector Search All'),
                    icon: '<svg viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z"/></svg>',
                    onClick: () => {
                        activeLorebook.value.entries.forEach(e => { e.vectorSearch = !allVector; });
                        closeBottomSheet();
                    }
                },
                {
                    label: t('action_index_all') || 'Index All Vector Entries',
                    icon: '<svg viewBox="0 0 24 24"><path d="M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96zM14 13v4h-4v-4H7l5-5 5 5h-3z"/></svg>',
                    onClick: async () => {
                        closeBottomSheet();
                        await handleIndexAllEntries();
                    }
                },
                {
                    label: t('action_delete_indexes') || 'Delete Vector Indexes',
                    icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                    iconColor: '#ff4444',
                    isDestructive: true,
                    onClick: async () => {
                        closeBottomSheet();
                        await handleDeleteAllIndexes();
                    }
                }
            ]
        });
    }

    function updateEntryKeys(val) {
        if (activeEntry.value) {
            activeEntry.value.keys = val.split(',').map(k => k.trim()).filter(k => k);
        }
    }

    function updateEntrySecondaryKeys(val) {
        if (activeEntry.value) {
            activeEntry.value.secondary_keys = val.split(',').map(k => k.trim()).filter(k => k);
        }
    }

    function updateCharacterFilter(val) {
        if (activeEntry.value) {
            if (!activeEntry.value.characterFilter) {
                activeEntry.value.characterFilter = { names: [], isExclude: false };
            }
            activeEntry.value.characterFilter.names = val.split(',').map(n => n.trim()).filter(n => n);
        }
    }

    function toggleAllVector() {
        if (!activeLorebook.value) return;
        const enable = !allVectorEnabled.value;
        activeLorebook.value.entries.forEach(e => { e.vectorSearch = enable; });
    }

    function resetAllEntriesToGlobal() {
        if (!activeLorebook.value) return;
        let changedCount = 0;
        activeLorebook.value.entries.forEach(entry => {
            const didChange = entry.caseSensitive !== null
                || entry.matchWholeWords !== null
                || entry.useGroupScoring !== null
                || entry.position !== 'matchGlobal'
                || entry.scanDepth !== null;
            entry.caseSensitive = null;
            entry.matchWholeWords = null;
            entry.useGroupScoring = null;
            entry.position = 'matchGlobal';
            entry.scanDepth = null;
            if (didChange) changedCount += 1;
        });
        showToast(changedCount > 0
            ? `${changedCount} entries reset to ${t('match_global')}`
            : 'All entries already match global settings');
    }

    function getEntryDisplayName(entry) {
        return entry.comment || entry.keys?.[0] || t('unnamed_entry');
    }

    function getEmbeddingErrorLabel(error) {
        if (!error?.type) return t('vector_error_unknown');
        return t(`vector_error_${error.type}`) || error.message || t('vector_error_unknown');
    }

    function getEmbeddingErrorMessage(error) {
        return error?.message || getEmbeddingErrorLabel(error);
    }

    return {
        searchQuery,
        failedEntryMap,
        filteredEntries,
        failedEntries,
        allVectorEnabled,
        characterFilterExclude,
        handleCreateEntry,
        selectEntry,
        handleDeleteEntry,
        handleConstantToggle,
        handleEntryMenu,
        openEntriesMenu,
        updateEntryKeys,
        updateEntrySecondaryKeys,
        updateCharacterFilter,
        toggleAllVector,
        resetAllEntriesToGlobal,
        getEntryDisplayName,
        getEmbeddingErrorLabel,
        getEmbeddingErrorMessage
    };
}
