import { REQUEST_KINDS } from '@/core/llm/contracts/providerContracts.js';

export function createChatRequestIntent({ model, messages, temperature, topP, stream, reasoningEffort, maxTokens, stopString, requestReasoning, omitTemperature, omitTopP, omitReasoning, omitReasoningEffort }) {
    return {
        kind: REQUEST_KINDS.CHAT,
        model,
        messages,
        temperature,
        topP,
        stream,
        reasoningEffort,
        requestReasoning: !!requestReasoning,
        maxTokens,
        stopString,
        omitTemperature: !!omitTemperature,
        omitTopP: !!omitTopP,
        omitReasoning: !!omitReasoning,
        omitReasoningEffort: !!omitReasoningEffort
    };
}

export function createSummaryRequestIntent({ model, prompt, temperature }) {
    return {
        kind: REQUEST_KINDS.SUMMARY,
        model,
        prompt,
        temperature,
        stream: false
    };
}

export function createMemoryDraftRequestIntent({ model, prompt, temperature, maxTokens }) {
    return {
        kind: REQUEST_KINDS.MEMORY_DRAFT,
        model,
        prompt,
        temperature,
        maxTokens,
        stream: false
    };
}
