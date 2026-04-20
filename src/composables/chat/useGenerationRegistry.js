const generationStates = {};
let generationIdCounter = 0;

function getGeneratingStorageKey(charId, sessionId) {
    return `gz_generating_${charId}_${sessionId}`;
}

export function useGenerationRegistry() {
    return {
        nextGenerationId() {
            generationIdCounter += 1;
            return generationIdCounter;
        },

        listGeneratingCharIds() {
            return Object.keys(generationStates);
        },

        getGenerationState(charId) {
            return generationStates[charId] || null;
        },

        hasGenerationState(charId) {
            return !!generationStates[charId];
        },

        setGenerationState(charId, state) {
            generationStates[charId] = state;
            return generationStates[charId];
        },

        clearGenerationState(charId, expectedGenId = null) {
            const currentState = generationStates[charId];
            if (!currentState) return false;
            if (expectedGenId !== null && currentState.genId !== expectedGenId) return false;

            delete generationStates[charId];
            return true;
        },

        markGenerationPersisted(charId, sessionId) {
            localStorage.setItem(getGeneratingStorageKey(charId, sessionId), 'true');
        },

        clearPersistedGeneration(charId, sessionId) {
            localStorage.removeItem(getGeneratingStorageKey(charId, sessionId));
        }
    };
}
