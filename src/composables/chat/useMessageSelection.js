import { ref, computed } from 'vue';

export function useMessageSelection(currentMessages) {
    const selectedMessages = ref(new Set());
    const isSelectionMode = computed(() => selectedMessages.value.size > 0);

    const selectionIncludesLast = computed(() => {
        if (selectedMessages.value.size === 0 || !currentMessages.value.length) return false;
        const msgs = currentMessages.value;
        for (let i = msgs.length - 1; i >= msgs.length - selectedMessages.value.size; i--) {
            if (i < 0 || !msgs[i] || !selectedMessages.value.has(msgs[i].id)) return false;
        }
        return true;
    });

    function toggleSelection(msgId) {
        if (selectedMessages.value.has(msgId)) {
            selectedMessages.value.delete(msgId);
        } else {
            selectedMessages.value.add(msgId);
        }
    }

    function clearSelection() {
        selectedMessages.value = new Set();
    }

    return {
        selectedMessages,
        isSelectionMode,
        selectionIncludesLast,
        toggleSelection,
        clearSelection
    };
}
