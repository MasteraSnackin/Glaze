const generationStates = {};
let generationIdCounter = 0;

function buildGenerationOwnerKey(charId, sessionId = 'unknown', scope = 'chat') {
    return `${scope}:${charId}:${sessionId}`;
}

function createGenerationRequestToken(ownerKey, genId) {
    return `${ownerKey}:${genId}`;
}

function matchesExpectedState(currentState, expected) {
    if (!currentState) return false;
    if (expected === null || expected === undefined) return true;
    if (typeof expected !== 'object') {
        return currentState.genId === expected;
    }

    if (expected.genId !== undefined && currentState.genId !== expected.genId) return false;
    if (expected.requestToken !== undefined && currentState.requestToken !== expected.requestToken) return false;
    if (expected.ownerKey !== undefined && currentState.ownerKey !== expected.ownerKey) return false;
    if (expected.sessionId !== undefined && currentState.sessionId !== expected.sessionId) return false;
    if (expected.type !== undefined && currentState.type !== expected.type) return false;

    return true;
}

function getGeneratingStorageKey(charId, sessionId) {
    return `gz_generating_${charId}_${sessionId}`;
}

export function useGenerationRegistry() {
    return {
        nextGenerationId() {
            generationIdCounter += 1;
            return generationIdCounter;
        },

        buildGenerationOwnerKey,

        createGenerationRequestToken,

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

        isGenerationStateCurrent(charId, expected = null) {
            return matchesExpectedState(generationStates[charId], expected);
        },

        clearGenerationState(charId, expectedGenId = null) {
            const currentState = generationStates[charId];
            if (!currentState) return false;
            if (!matchesExpectedState(currentState, expectedGenId)) return false;

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
