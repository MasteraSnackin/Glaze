import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { getEffectiveApiConfig } from '@/core/llm/usecases/promptConfigReaders.js';
import { buildSummaryRequestPayload } from '@/core/llm/assemblers/requestAssemblers.js';
import { executeRequest } from '@/core/services/llmApi.js';
import { executeSummaryRequest } from '@/core/llm/usecases/summaryRequest.js';

export async function generateSummary({ history, prompt, debugKey, controller, apiConfigOverride = null }) {
    const effectiveDebugKey = debugKey || `summary:${Date.now()}:${Math.random().toString(36).slice(2, 8)}`;
    return executeSummaryRequest({
        history,
        prompt,
        debugKey: effectiveDebugKey,
        controller,
        apiConfigOverride,
        deps: {
            getEffectiveApiConfig,
            buildSummaryRequestPayload,
            executeRequest,
            setLastPrompt: (promptBody) => {
                publishAppEvent(APP_EVENTS.debug.promptPreviewUpdated, { debugKey: effectiveDebugKey, prompt: promptBody });
            }
        }
    });
}
