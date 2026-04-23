export function useGenerationAbort({
    getGenerationState,
    clearGenerationState,
    isGenerating,
    isImpersonating,
    activeChatChar
}) {
    async function abortActiveChatGeneration(charId, { restore = true } = {}) {
        const state = getGenerationState(charId);
        if (!state) return false;

        if (state.type === 'impersonation') {
            return abortImpersonation(charId, state);
        }

        if (state.controller) {
            try {
                state.controller.abort();
            } catch (abortErr) {
                console.warn('[generation] Failed to abort controller:', abortErr);
            }
        }

        if (restore && state.restoreState) {
            try {
                await state.restoreState();
            } catch (restoreErr) {
                console.error('[generation] Failed to restore state after abort:', restoreErr);
            }
        }

        clearGenerationState(charId, state.genId);

        if (activeChatChar && activeChatChar.value && activeChatChar.value.id === charId) {
            isGenerating.value = false;
        }

        return true;
    }

    function abortImpersonation(charId, state) {
        if (state?.controller) {
            try { state.controller.abort(); } catch (e) {}
        }
        clearGenerationState(charId);
        isGenerating.value = false;
        if (isImpersonating) isImpersonating.value = false;
        return true;
    }

    async function abortAnyActiveGeneration(charId) {
        const state = getGenerationState(charId);
        if (state?.type === 'impersonation') {
            return abortImpersonation(charId, state);
        } else if (state) {
            return abortActiveChatGeneration(charId);
        } else {
            isGenerating.value = false;
            return false;
        }
    }

    return { abortActiveChatGeneration, abortImpersonation, abortAnyActiveGeneration };
}
