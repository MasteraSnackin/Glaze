function clonePromptMetaList(items) {
    return Array.isArray(items)
        ? items.map(item => ({ ...item }))
        : [];
}

export function usePromptMetadataSnapshots() {
    const promptMetaSnapshots = new Map();

    return {
        snapshotPromptMeta(message) {
            if (!message?.id || promptMetaSnapshots.has(message.id)) return;

            promptMetaSnapshots.set(message.id, {
                hasTriggeredLorebooks: Object.prototype.hasOwnProperty.call(message, 'triggeredLorebooks'),
                hasTriggeredMemories: Object.prototype.hasOwnProperty.call(message, 'triggeredMemories'),
                hasContextRefs: Object.prototype.hasOwnProperty.call(message, 'contextRefs'),
                triggeredLorebooks: clonePromptMetaList(message.triggeredLorebooks),
                triggeredMemories: clonePromptMetaList(message.triggeredMemories),
                contextRefs: clonePromptMetaList(message.contextRefs)
            });
        },

        restorePromptMetaOnMessages(messages) {
            if (!Array.isArray(messages) || promptMetaSnapshots.size === 0) return false;

            let changed = false;
            const restored = new Set();
            messages.forEach(message => {
                const snapshot = message?.id ? promptMetaSnapshots.get(message.id) : null;
                if (!snapshot) return;

                if (snapshot.hasTriggeredLorebooks) message.triggeredLorebooks = clonePromptMetaList(snapshot.triggeredLorebooks);
                else delete message.triggeredLorebooks;

                if (snapshot.hasTriggeredMemories) message.triggeredMemories = clonePromptMetaList(snapshot.triggeredMemories);
                else delete message.triggeredMemories;

                if (snapshot.hasContextRefs) message.contextRefs = clonePromptMetaList(snapshot.contextRefs);
                else delete message.contextRefs;

                restored.add(message.id);
                changed = true;
            });

            for (const id of restored) {
                promptMetaSnapshots.delete(id);
            }

            return changed;
        },

        clearSnapshots() {
            promptMetaSnapshots.clear();
        }
    };
}

export function createPromptMetadataSnapshots() {
    return usePromptMetadataSnapshots();
}
