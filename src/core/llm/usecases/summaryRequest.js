import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import {
    runNonChatCommitHook,
    runNonChatPromptBuildHooks,
    runNonChatRequestHooks
} from '@/core/llm/usecases/sharedRequestHooks.js';

export async function executeSummaryRequest({
    history,
    prompt,
    debugKey,
    controller,
    apiConfigOverride = null,
    deps
}) {
    const {
        getEffectiveApiConfig,
        buildSummaryRequestPayload,
        executeRequest,
        setLastPrompt
    } = deps;

    const effectiveConfig = {
        ...getEffectiveApiConfig(),
        ...(apiConfigOverride || {})
    };
    const { providerId, apiKey, apiUrl, model, temp } = effectiveConfig;

    if (!apiUrl || !model) {
        throw new Error('API Not Configured');
    }

    const defaultPrompt = 'Summarize the following roleplay conversation concisely, focusing on the current situation and key events:\n\n{{history}}';
    const template = prompt || defaultPrompt;

    let finalPrompt = template.replace('{{history}}', history);
    if (!template.includes('{{history}}')) {
        finalPrompt = `${template}\n\n${history}`;
    }

    const promptStage = await runNonChatPromptBuildHooks({
        requestType: 'summary',
        debugKey,
        history,
        prompt,
        apiConfigOverride,
        effectiveConfig,
        template,
        finalPrompt
    });

    const effectiveTemplate = promptStage?.template === undefined ? template : promptStage.template;
    finalPrompt = promptStage?.finalPrompt === undefined ? finalPrompt : promptStage.finalPrompt;

    let result = '';

    const requestEnvelope = await runNonChatRequestHooks({
        requestType: 'summary',
        debugKey,
        providerId,
        apiUrl,
        apiKey,
        model,
        buildPayload: buildSummaryRequestPayload,
        payloadInput: {
            prompt: finalPrompt,
            temperature: temp
        },
        controller,
        extra: {
            history,
            prompt,
            template: effectiveTemplate,
            finalPrompt,
            effectiveConfig
        }
    });

    const { previewBody, requestBody } = requestEnvelope;

    setLastPrompt?.(JSON.parse(JSON.stringify(previewBody || requestBody)));

    publishAppEvent(APP_EVENTS.domain.generation.requestDispatched, {
        debugKey,
        requestType: 'summary',
        messageCount: requestBody?.messages?.length || 0
    });

    await executeRequest({
        providerId: requestEnvelope.providerId,
        apiUrl: requestEnvelope.apiUrl,
        apiKey: requestEnvelope.apiKey,
        requestBody,
        debugKey,
        requestType: 'summary',
        controller: requestEnvelope.controller,
        stream: requestEnvelope.stream,
        callbacks: {
            onComplete: (text) => { result = text; }
        }
    });

    await runNonChatCommitHook({
        requestType: 'summary',
        debugKey,
        result,
        extra: {
            history,
            prompt,
            template: effectiveTemplate,
            finalPrompt
        }
    });

    return result;
}
