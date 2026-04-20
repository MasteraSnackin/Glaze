import { Capacitor, CapacitorHttp } from '@capacitor/core';
import { CAPABILITY_FLAGS, DEFAULT_PROVIDER_ID, createProviderCapabilities } from '@/core/llm/contracts/providerContracts.js';

function trimTrailingSlash(value = '') {
    return value.endsWith('/') ? value.slice(0, -1) : value;
}

function normalizeBaseEndpoint(endpoint = '') {
    let normalized = String(endpoint || '').trim();
    if (!normalized) return '';

    if (!/^https?:\/\//i.test(normalized)) {
        normalized = `https://${normalized}`;
    }

    normalized = trimTrailingSlash(normalized);

    const chatSuffix = '/chat/completions';
    if (normalized.toLowerCase().endsWith(chatSuffix)) {
        normalized = normalized.slice(0, -chatSuffix.length);
    }

    return trimTrailingSlash(normalized);
}

function buildAuthHeaders(apiKey) {
    const headers = {};
    if (apiKey) headers.Authorization = `Bearer ${apiKey}`;
    return headers;
}

function parseModelList(data) {
    if (data?.data && Array.isArray(data.data)) {
        return data.data.map(model => model.id).filter(Boolean).sort();
    }

    if (Array.isArray(data)) {
        return data.map(model => model?.id).filter(Boolean).sort();
    }

    return [];
}

export const openaiCompatibleProvider = Object.freeze({
    id: DEFAULT_PROVIDER_ID,
    label: 'OpenAI Compatible',
    capabilities: createProviderCapabilities({
        [CAPABILITY_FLAGS.CHAT_COMPLETIONS]: true,
        [CAPABILITY_FLAGS.MODEL_DISCOVERY]: true,
        [CAPABILITY_FLAGS.STREAMING]: true,
        [CAPABILITY_FLAGS.REASONING_FIELD]: true,
        [CAPABILITY_FLAGS.INLINE_REASONING]: true,
        [CAPABILITY_FLAGS.SYSTEM_ROLE]: true,
        [CAPABILITY_FLAGS.IMAGES]: true
    }),

    normalizeEndpoint(endpoint) {
        return normalizeBaseEndpoint(endpoint);
    },

    buildChatCompletionsUrl(endpoint) {
        const base = normalizeBaseEndpoint(endpoint);
        return base ? `${base}/chat/completions` : '';
    },

    buildModelsUrl(endpoint) {
        const base = normalizeBaseEndpoint(endpoint);
        return base ? `${base}/models` : '';
    },

    buildAuthHeaders(apiKey) {
        return buildAuthHeaders(apiKey);
    },

    parseModelList(data) {
        return parseModelList(data);
    },

    async listModels({ endpoint, apiKey }) {
        const url = this.buildModelsUrl(endpoint);
        if (!url) throw new Error('No endpoint');

        const headers = this.buildAuthHeaders(apiKey);

        let data;
        if (Capacitor.isNativePlatform()) {
            const response = await CapacitorHttp.get({
                url,
                headers
            });
            if (response.status >= 400) throw new Error(`HTTP ${response.status}`);
            data = response.data;
        } else {
            const response = await fetch(url, { headers });
            if (!response.ok) throw new Error(`HTTP ${response.status}`);
            data = await response.json();
        }

        return this.parseModelList(data);
    }
});
