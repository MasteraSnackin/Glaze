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

export function nextGenerationId() {
    generationIdCounter += 1;
    return generationIdCounter;
}

export { buildGenerationOwnerKey, createGenerationRequestToken };

export function listGeneratingCharIds() {
    return Object.keys(generationStates);
}

export function getGenerationState(charId) {
    return generationStates[charId] || null;
}

export function hasGenerationState(charId) {
    return !!generationStates[charId];
}

export function setGenerationState(charId, state) {
    generationStates[charId] = state;
    return generationStates[charId];
}

export function isGenerationStateCurrent(charId, expected = null) {
    return matchesExpectedState(generationStates[charId], expected);
}

export function clearGenerationState(charId, expectedGenId = null) {
    const currentState = generationStates[charId];
    if (!currentState) return false;
    if (!matchesExpectedState(currentState, expectedGenId)) return false;

    delete generationStates[charId];
    return true;
}

export function markGenerationPersisted(charId, sessionId) {
    localStorage.setItem(getGeneratingStorageKey(charId, sessionId), 'true');
}

export function clearPersistedGeneration(charId, sessionId) {
    localStorage.removeItem(getGeneratingStorageKey(charId, sessionId));
}
