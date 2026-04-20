import { db } from '@/utils/db.js';
import { DEFAULT_PROVIDER_ID } from '@/core/llm/contracts/providerContracts.js';
import { getProviderById } from '@/core/llm/providers/providerRegistry.js';

export const PROVIDER_BLACKLIST = [
    { name: 'EllyAI', match: 'ellyai' },
    { name: 'MegaLLM', match: 'megallm' }
];

export function getBlacklistedProvider(url) {
    if (!url) return null;
    const lower = url.toLowerCase();
    return PROVIDER_BLACKLIST.find(entry => lower.includes(entry.match)) || null;
}

export async function initSettings() {
    // Ensure defaults exist
    if (localStorage.getItem('gz_api_provider') === null) localStorage.setItem('gz_api_provider', DEFAULT_PROVIDER_ID);
    if (localStorage.getItem('gz_api_temp') === null) localStorage.setItem('gz_api_temp', '0.7');
    if (localStorage.getItem('gz_api_topp') === null) localStorage.setItem('gz_api_topp', '0.9');
    if (localStorage.getItem('gz_api_stream') === null) localStorage.setItem('gz_api_stream', 'true');
    if (localStorage.getItem('gz_api_reasoning_start') === null) localStorage.setItem('gz_api_reasoning_start', '<think>');
    if (localStorage.getItem('gz_api_reasoning_end') === null) localStorage.setItem('gz_api_reasoning_end', '</think>');
    if (localStorage.getItem('gz_api_auto_hide_images') === null) localStorage.setItem('gz_api_auto_hide_images', 'false');
    if (localStorage.getItem('gz_api_auto_hide_images_n') === null) localStorage.setItem('gz_api_auto_hide_images_n', '1');
    if (localStorage.getItem('gz_api_reasoning_effort') === null) localStorage.setItem('gz_api_reasoning_effort', 'medium');
}

export function normalizeEndpoint(url) {
    return getProviderById(getApiProviderId()).normalizeEndpoint(url);
}

export function getApiProviderId() {
    return localStorage.getItem('gz_api_provider') || DEFAULT_PROVIDER_ID;
}

export function getApiReasoningTags() {
    return {
        start: localStorage.getItem('gz_api_reasoning_start') || '<think>',
        end: localStorage.getItem('gz_api_reasoning_end') || '</think>'
    };
}

export function getApiRuntimeStorage() {
    const maxTokens = parseInt(localStorage.getItem('api-max-tokens'));
    const contextSize = parseInt(localStorage.getItem('api-context'));
    return {
        providerId: getApiProviderId(),
        endpoint: localStorage.getItem('api-endpoint') || '',
        normalizedEndpoint: localStorage.getItem('gz_api_endpoint_normalized') || localStorage.getItem('api-endpoint') || '',
        key: localStorage.getItem('api-key') || '',
        model: localStorage.getItem('api-model') || '',
        maxTokens: isNaN(maxTokens) ? 8000 : maxTokens,
        contextSize: isNaN(contextSize) ? 32000 : contextSize,
        temp: parseFloat(localStorage.getItem('gz_api_temp')) || 0.7,
        topP: parseFloat(localStorage.getItem('gz_api_topp')) || 0.9,
        stream: localStorage.getItem('gz_api_stream') === 'true',
        requestReasoning: localStorage.getItem('gz_api_request_reasoning') === 'true',
        autoHideImages: localStorage.getItem('gz_api_auto_hide_images') === 'true',
        autoHideImagesN: parseInt(localStorage.getItem('gz_api_auto_hide_images_n') || '1', 10),
        reasoningEffort: localStorage.getItem('gz_api_reasoning_effort') || 'medium',
        reasoningTags: getApiReasoningTags()
    };
}

export function saveApiRuntimeSetting(key, value) {
    if (key === 'api-endpoint') {
        localStorage.setItem('gz_api_endpoint_normalized', normalizeEndpoint(value));
    }

    localStorage.setItem(key, value);

    if (key === 'api-context' || key === 'api-max-tokens') {
        window.dispatchEvent(new CustomEvent('api-context-settings-changed'));
    }
}

export function applyApiRuntimeConfig({
    providerId,
    endpoint,
    apiKey,
    model,
    maxTokens,
    contextSize,
    temp,
    topP,
    stream,
    autoHideImages,
    autoHideImagesN,
    requestReasoning,
    reasoningEffort
} = {}) {
    if (providerId !== undefined) localStorage.setItem('gz_api_provider', providerId);
    if (endpoint !== undefined) saveApiRuntimeSetting('api-endpoint', endpoint);
    if (apiKey !== undefined) saveApiRuntimeSetting('api-key', apiKey);
    if (model !== undefined) saveApiRuntimeSetting('api-model', model);
    if (maxTokens !== undefined) saveApiRuntimeSetting('api-max-tokens', String(maxTokens));
    if (contextSize !== undefined) saveApiRuntimeSetting('api-context', String(contextSize));
    if (temp !== undefined) saveApiRuntimeSetting('gz_api_temp', String(temp));
    if (topP !== undefined) saveApiRuntimeSetting('gz_api_topp', String(topP));
    if (stream !== undefined) saveApiRuntimeSetting('gz_api_stream', String(stream));
    if (autoHideImages !== undefined) saveApiRuntimeSetting('gz_api_auto_hide_images', String(autoHideImages));
    if (autoHideImagesN !== undefined) saveApiRuntimeSetting('gz_api_auto_hide_images_n', String(autoHideImagesN));
    if (requestReasoning !== undefined) saveApiRuntimeSetting('gz_api_request_reasoning', String(requestReasoning));
    if (reasoningEffort !== undefined) saveApiRuntimeSetting('gz_api_reasoning_effort', String(reasoningEffort));
}

export function getApiConfig() {
    const runtime = getApiRuntimeStorage();
    return {
        providerId: runtime.providerId,
        apiKey: runtime.key,
        apiUrl: runtime.normalizedEndpoint,
        model: runtime.model,
        stream: runtime.stream,
        requestReasoning: runtime.requestReasoning,
        temp: runtime.temp,
        topP: runtime.topP,
        maxTokens: runtime.maxTokens,
        contextSize: runtime.contextSize,
        autoHideImages: runtime.autoHideImages,
        autoHideImagesN: runtime.autoHideImagesN,
        reasoningEffort: runtime.reasoningEffort
    };
}

export async function fetchRemoteModels(endpoint, key, providerId = getApiProviderId()) {
    const provider = getProviderById(providerId);
    return provider.listModels({ endpoint, apiKey: key });
}

export async function getApiPresets() {
    const saved = await db.get('gz_api_connection_presets');
    if (saved && Array.isArray(saved) && saved.length > 0) {
        return saved;
    }
    // Default
    return [{
        id: 'default',
        name: 'Default',
        providerId: getApiProviderId(),
        endpoint: localStorage.getItem('api-endpoint') || '',
        key: localStorage.getItem('api-key') || '',
        model: localStorage.getItem('api-model') || '',
        max_tokens: localStorage.getItem('api-max-tokens') || '8000',
        context: localStorage.getItem('api-context') || '32000',
        temp: localStorage.getItem('gz_api_temp') || '0.7',
        topp: localStorage.getItem('gz_api_topp') || '0.9',
        stream: localStorage.getItem('gz_api_stream') === 'true'
    }];
}

export async function saveApiPresets(presets) {
    await db.set('gz_api_connection_presets', presets);
}
