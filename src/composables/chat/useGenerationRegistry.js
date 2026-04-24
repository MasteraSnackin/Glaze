import {
    nextGenerationId,
    buildGenerationOwnerKey,
    createGenerationRequestToken,
    listGeneratingCharIds,
    getGenerationState,
    hasGenerationState,
    setGenerationState,
    isGenerationStateCurrent,
    clearGenerationState,
    markGenerationPersisted,
    clearPersistedGeneration
} from '@/core/states/generationState.js';

export function useGenerationRegistry() {
    return {
        nextGenerationId,
        buildGenerationOwnerKey,
        createGenerationRequestToken,
        listGeneratingCharIds,
        getGenerationState,
        hasGenerationState,
        setGenerationState,
        isGenerationStateCurrent,
        clearGenerationState,
        markGenerationPersisted,
        clearPersistedGeneration
    };
}

export {
    nextGenerationId,
    buildGenerationOwnerKey,
    createGenerationRequestToken,
    getGenerationState,
    hasGenerationState,
    setGenerationState,
    isGenerationStateCurrent,
    clearGenerationState,
    markGenerationPersisted,
    clearPersistedGeneration
};
