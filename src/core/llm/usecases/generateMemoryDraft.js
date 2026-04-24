import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { getEffectiveApiConfig } from '@/core/llm/usecases/promptConfigReaders.js';
import { buildMemoryDraftRequestPayload } from '@/core/llm/assemblers/requestAssemblers.js';
import { executeRequest } from '@/core/services/llmApi.js';
import { executeMemoryDraftRequest } from '@/core/llm/usecases/memoryDraftRequest.js';

export async function generateMemoryDraft({ history, prompt, debugKey, controller, apiConfigOverride = null }) {
    const effectiveDebugKey = debugKey || `memory_draft:${Date.now()}:${Math.random().toString(36).slice(2, 8)}`;
    return executeMemoryDraftRequest({
        history,
        prompt,
        debugKey: effectiveDebugKey,
        controller,
        apiConfigOverride,
        deps: {
            getEffectiveApiConfig,
            buildMemoryDraftRequestPayload,
            executeRequest,
            setLastPrompt: (promptBody) => {
                publishAppEvent(APP_EVENTS.debug.promptPreviewUpdated, { debugKey: effectiveDebugKey, prompt: promptBody });
            }
        }
    });
}
