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

export function getApiConfig() {
    const mt = parseInt(localStorage.getItem('api-max-tokens'));
    const ctx = parseInt(localStorage.getItem('api-context'));
    return {
        providerId: getApiProviderId(),
        apiKey: localStorage.getItem('api-key') || '',
        apiUrl: localStorage.getItem('gz_api_endpoint_normalized') || localStorage.getItem('api-endpoint') || '',
        model: localStorage.getItem('api-model') || '',
        stream: localStorage.getItem('gz_api_stream') === 'true',
        requestReasoning: localStorage.getItem('gz_api_request_reasoning') === 'true',
        temp: parseFloat(localStorage.getItem('gz_api_temp')) || 0.7,
        topP: parseFloat(localStorage.getItem('gz_api_topp')) || 0.9,
        maxTokens: isNaN(mt) ? 8000 : mt,
        contextSize: isNaN(ctx) ? 32000 : ctx,
        autoHideImages: localStorage.getItem('gz_api_auto_hide_images') === 'true',
        autoHideImagesN: parseInt(localStorage.getItem('gz_api_auto_hide_images_n') || '1', 10),
        reasoningEffort: localStorage.getItem('gz_api_reasoning_effort') || 'medium'
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
