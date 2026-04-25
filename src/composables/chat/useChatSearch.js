import { ref, computed, watch } from 'vue';

export function useChatSearch({ currentMessages, scrollToIndex, displayMessages }) {
    const isSearchMode = ref(false);
    const searchQuery = ref('');
    const searchResults = ref([]);
    const currentSearchIndex = ref(-1);

    watch(searchQuery, (newVal) => {
        if (!newVal || !isSearchMode.value) {
            searchResults.value = [];
            currentSearchIndex.value = -1;
            return;
        }
        const query = newVal.toLowerCase();
        const results = [];
        currentMessages.value.forEach((msg, idx) => {
            if (msg && msg.text) {
                const text = msg.text.toLowerCase();
                let lastIdx = -1;
                while ((lastIdx = text.indexOf(query, lastIdx + 1)) !== -1) {
                    results.push({ msgIdx: idx, matchIdx: lastIdx });
                }
            }
        });
        searchResults.value = results;
        if (results.length > 0) {
            currentSearchIndex.value = results.length - 1;
            scrollToSearchResult();
        } else {
            currentSearchIndex.value = -1;
        }
    });

    function scrollToSearchResult() {
        if (currentSearchIndex.value >= 0 && currentSearchIndex.value < searchResults.value.length) {
            const { msgIdx } = searchResults.value[currentSearchIndex.value];
            const displayIndex = displayMessages.value.findIndex(m => m.type === 'message' && m.originalIndex === msgIdx);
            if (displayIndex !== -1) {
                scrollToIndex(displayIndex, 'smooth').then(() => {
                    const el = document.getElementById(`msg-${msgIdx}`);
                    if (el) {
                        el.classList.add('search-highlight');
                        setTimeout(() => el.classList.remove('search-highlight'), 1500);
                    }
                });
            }
        }
    }

    function nextSearchResult() {
        if (searchResults.value.length === 0) return;
        currentSearchIndex.value = (currentSearchIndex.value + 1) % searchResults.value.length;
        scrollToSearchResult();
    }

    function prevSearchResult() {
        if (searchResults.value.length === 0) return;
        currentSearchIndex.value = (currentSearchIndex.value - 1 + searchResults.value.length) % searchResults.value.length;
        scrollToSearchResult();
    }

    const searchMatchState = computed(() => {
        if (!isSearchMode.value || searchResults.value.length === 0 || currentSearchIndex.value < 0) return { msgIdx: -1, occurrenceIdx: -1 };
        const activeMatch = searchResults.value[currentSearchIndex.value];
        let occurrenceIdx = 0;
        for (let i = 0; i < currentSearchIndex.value; i++) {
            if (searchResults.value[i].msgIdx === activeMatch.msgIdx) {
                occurrenceIdx++;
            }
        }
        return {
            msgIdx: activeMatch.msgIdx,
            occurrenceIdx: occurrenceIdx
        };
    });

    const onChatSearchToggle = (e) => {
        isSearchMode.value = e.detail;
        if (!isSearchMode.value) {
            searchQuery.value = '';
        }
    };

    const onChatSearch = (e) => {
        searchQuery.value = e.detail;
    };

    return {
        isSearchMode,
        searchQuery,
        searchResults,
        currentSearchIndex,
        searchMatchState,
        scrollToSearchResult,
        nextSearchResult,
        prevSearchResult,
        onChatSearchToggle,
        onChatSearch
    };
}
