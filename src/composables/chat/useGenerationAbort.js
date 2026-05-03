import { clearPersistedGeneration } from '@/core/states/generationState.js';
import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';

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

        const { sessionId, type } = state;

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

        isGenerating.value = false;

        if (sessionId) {
            clearPersistedGeneration(charId, sessionId);
        }

        return true;
    }

    function abortImpersonation(charId, state) {
        const { sessionId, genId } = state || {};
        if (state?.controller) {
            try {
                state.userAborted = true;
                state.controller.userAborted = true;
                state.controller.abort();
            } catch (e) {}
        }
        isGenerating.value = false;
        if (isImpersonating) isImpersonating.value = false;
        if (sessionId) {
            clearPersistedGeneration(charId, sessionId);
        }
        clearGenerationState(charId);

        publishAppEvent(APP_EVENTS.domain.generation.ended, {
            charId,
            sessionId: sessionId ?? null,
            genId: genId ?? null,
            type: 'impersonation'
        });

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
