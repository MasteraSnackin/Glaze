import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { getEffectiveApiConfig } from '@/core/llm/usecases/promptConfigReaders.js';
import { buildMemoryDraftRequestPayload } from '@/core/llm/assemblers/requestAssemblers.js';
import { executeRequest } from '@/core/llm/transport/requestOrchestrator.js';
import { executeMemoryDraftRequest } from '@/core/llm/usecases/memoryDraftRequest.js';
import { buildReasoningHeaders, getNotificationBody } from '@/core/llm/usecases/reasoningHeaders.js';

export async function generateMemoryDraft({ history, prompt, debugKey, controller, apiConfigOverride = null }) {
    const effectiveDebugKey = debugKey || `memory_draft:${Date.now()}:${Math.random().toString(36).slice(2, 8)}`;
    const reasoningHeaders = buildReasoningHeaders();
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
            headerModel: reasoningHeaders.headerModel,
            headerInline: reasoningHeaders.headerInline,
            notificationBody: getNotificationBody(),
            setLastPrompt: (promptBody) => {
                publishAppEvent(APP_EVENTS.debug.promptPreviewUpdated, { debugKey: effectiveDebugKey, prompt: promptBody });
            }
        }
    });
}
