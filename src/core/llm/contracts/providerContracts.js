export const DEFAULT_PROVIDER_ID = 'openai_compatible';

export const REQUEST_KINDS = Object.freeze({
    CHAT: 'chat',
    SUMMARY: 'summary',
    MEMORY_DRAFT: 'memory_draft',
    MODEL_DISCOVERY: 'model_discovery'
});

export const CAPABILITY_FLAGS = Object.freeze({
    CHAT_COMPLETIONS: 'chat_completions',
    MODEL_DISCOVERY: 'model_discovery',
    STREAMING: 'streaming',
    REASONING_FIELD: 'reasoning_field',
    INLINE_REASONING: 'inline_reasoning',
    SYSTEM_ROLE: 'system_role',
    IMAGES: 'images'
});

export function createProviderCapabilities(overrides = {}) {
    return Object.freeze({
        [CAPABILITY_FLAGS.CHAT_COMPLETIONS]: false,
        [CAPABILITY_FLAGS.MODEL_DISCOVERY]: false,
        [CAPABILITY_FLAGS.STREAMING]: false,
        [CAPABILITY_FLAGS.REASONING_FIELD]: false,
        [CAPABILITY_FLAGS.INLINE_REASONING]: false,
        [CAPABILITY_FLAGS.SYSTEM_ROLE]: false,
        [CAPABILITY_FLAGS.IMAGES]: false,
        ...overrides
    });
}
