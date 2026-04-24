import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { getEffectiveApiConfig } from '@/core/llm/usecases/promptConfigReaders.js';
import { buildSummaryRequestPayload } from '@/core/llm/assemblers/requestAssemblers.js';
import { executeRequest } from '@/core/llm/transport/requestOrchestrator.js';
import { executeSummaryRequest } from '@/core/llm/usecases/summaryRequest.js';
import { buildReasoningHeaders, getNotificationBody } from '@/core/llm/usecases/reasoningHeaders.js';

export async function generateSummary({ history, prompt, debugKey, controller, apiConfigOverride = null }) {
    const effectiveDebugKey = debugKey || `summary:${Date.now()}:${Math.random().toString(36).slice(2, 8)}`;
    const reasoningHeaders = buildReasoningHeaders();
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
            headerModel: reasoningHeaders.headerModel,
            headerInline: reasoningHeaders.headerInline,
            notificationBody: getNotificationBody(),
            setLastPrompt: (promptBody) => {
                publishAppEvent(APP_EVENTS.debug.promptPreviewUpdated, { debugKey: effectiveDebugKey, prompt: promptBody });
            }
        }
    });
}
