import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import {
    runNonChatCommitHook,
    runNonChatPromptBuildHooks,
    runNonChatRequestHooks
} from '@/core/llm/usecases/sharedRequestHooks.js';

export async function executeMemoryDraftRequest({
    history,
    prompt,
    debugKey,
    controller,
    apiConfigOverride = null,
    deps
}) {
    const {
        getEffectiveApiConfig,
        buildMemoryDraftRequestPayload,
        executeRequest,
        setLastPrompt
    } = deps;

    const effectiveConfig = {
        ...getEffectiveApiConfig(),
        ...(apiConfigOverride || {})
    };
    const { providerId, apiKey, apiUrl, model, temp } = effectiveConfig;

    const explicitOverrideMaxTokens = Number(apiConfigOverride?.maxTokens);
    const hasExplicitOverride = Number.isFinite(explicitOverrideMaxTokens) && explicitOverrideMaxTokens > 0;
    const configuredMaxTokens = Number(effectiveConfig.maxTokens);
    const memoryDraftMaxTokens = hasExplicitOverride
        ? Math.max(200, Math.round(explicitOverrideMaxTokens))
        : (Number.isFinite(configuredMaxTokens) && configuredMaxTokens > 0
            ? Math.max(1200, Math.round(configuredMaxTokens))
            : 2000);

    if (!apiUrl || !model) {
        throw new Error('API Not Configured');
    }

    const defaultPrompt = [
        'Create exactly one concise long-term memory entry from the following roleplay segment.',
        'Preserve the original language of the source segment. Do not translate it.',
        'Use only facts that are explicitly supported by the segment.',
        'Do not infer completed outcomes, registrations, approvals, or decisions unless the text clearly states them.',
        'Focus on durable facts, developments, or relationship changes that should persist beyond immediate context.',
        'Do not copy the dialogue verbatim.',
        'Return only the memory entry text with no preface, label, or explanation.',
        '',
        '{{history}}'
    ].join('\n');
    const template = prompt || defaultPrompt;

    let finalPrompt = template.replace('{{history}}', history);
    if (!template.includes('{{history}}')) {
        finalPrompt = `${template}\n\n${history}`;
    }

    const promptStage = await runNonChatPromptBuildHooks({
        requestType: 'memory_draft',
        debugKey,
        history,
        prompt,
        apiConfigOverride,
        effectiveConfig,
        template,
        finalPrompt,
        extra: {
            maxTokens: memoryDraftMaxTokens
        }
    });

    const effectiveTemplate = promptStage?.template === undefined ? template : promptStage.template;
    finalPrompt = promptStage?.finalPrompt === undefined ? finalPrompt : promptStage.finalPrompt;

    let result = '';
    let requestError = null;

    const requestEnvelope = await runNonChatRequestHooks({
        requestType: 'memory_draft',
        debugKey,
        providerId,
        apiUrl,
        apiKey,
        model,
        buildPayload: buildMemoryDraftRequestPayload,
        payloadInput: {
            prompt: finalPrompt,
            temperature: temp,
            maxTokens: memoryDraftMaxTokens
        },
        controller,
        stream: false,
        extra: {
            history,
            prompt,
            template: effectiveTemplate,
            finalPrompt,
            effectiveConfig,
            maxTokens: memoryDraftMaxTokens
        }
    });

    const { previewBody, requestBody } = requestEnvelope;

    setLastPrompt(JSON.parse(JSON.stringify(previewBody)));

    publishAppEvent(APP_EVENTS.domain.generation.requestDispatched, {
        debugKey,
        requestType: 'memory_draft',
        messageCount: requestBody?.messages?.length || 0
    });

    await executeRequest({
        providerId: requestEnvelope.providerId,
        apiUrl: requestEnvelope.apiUrl,
        apiKey: requestEnvelope.apiKey,
        requestBody,
        stream: requestEnvelope.stream,
        debugKey,
        controller: requestEnvelope.controller,
        requestType: 'memory_draft',
        callbacks: {
            onUpdate: (chunk, reasoningChunk, effectiveText) => {
                if (effectiveText) result = effectiveText;
                else if (chunk) result += chunk;
            },
            onComplete: (text) => { if (text) result = text; },
            onError: (err) => { requestError = err; }
        }
    });

    if (requestError) throw requestError;

    await runNonChatCommitHook({
        requestType: 'memory_draft',
        debugKey,
        result,
        extra: {
            history,
            prompt,
            template: effectiveTemplate,
            finalPrompt,
            maxTokens: memoryDraftMaxTokens
        }
    });

    return result;
}
