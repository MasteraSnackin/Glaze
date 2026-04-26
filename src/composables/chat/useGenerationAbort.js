export function useGenerationAbort({
    getGenerationState,
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
                state.userAborted = true;
                state.controller.userAborted = true;
                state.controller.abort();
            } catch (abortErr) {
                console.warn('[generation] Failed to abort controller:', abortErr);
            }
        }

        if (typeof state.clearGenerationTimer === 'function') {
            state.clearGenerationTimer();
        } else if (state.timerId) {
            clearTimeout(state.timerId);
            state.timerId = null;
        }

        if (typeof state.clearStreamFlushTimer === 'function') {
            state.clearStreamFlushTimer();
        }

        if (activeChatChar?.value && activeChatChar.value.id === charId) {
            isGenerating.value = false;
        }

        return true;
    }

    function abortImpersonation(charId, state) {
        if (state?.controller) {
            try {
                state.userAborted = true;
                state.controller.userAborted = true;
                state.controller.abort();
            } catch (e) {}
        }
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
