import { buildProviderPayload } from '@/core/llm/assemblers/payloadBuilderRegistry.js';
import { createChatRequestIntent, createSummaryRequestIntent, createMemoryDraftRequestIntent } from '@/core/llm/assemblers/requestIntents.js';

export function buildChatRequestPayload({ providerId, model, messages, temperature, topP, stream, reasoningEffort, maxTokens, stopString }) {
    const intent = createChatRequestIntent({
        model,
        messages,
        temperature,
        topP,
        stream,
        reasoningEffort,
        maxTokens,
        stopString
    });

    return buildProviderPayload(providerId, intent);
}

export function buildSummaryRequestPayload({ providerId, model, prompt, temperature }) {
    const intent = createSummaryRequestIntent({ model, prompt, temperature });
    return buildProviderPayload(providerId, intent);
}

export function buildMemoryDraftRequestPayload({ providerId, model, prompt, temperature, maxTokens }) {
    const intent = createMemoryDraftRequestIntent({ model, prompt, temperature, maxTokens });
    return buildProviderPayload(providerId, intent);
}
