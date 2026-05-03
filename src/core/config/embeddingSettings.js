import { isServiceUsingLLMProfile, getEmbeddingProfile, SERVICE_NAMES } from './ProviderProfiles.js';

export function getEmbeddingConfig() {
    const isSame = isServiceUsingLLMProfile(SERVICE_NAMES.EMBEDDING);
    const profile = getEmbeddingProfile() || {};

    const base = {
        target: localStorage.getItem('gz_embedding_target') || 'content',
        scanDepth: parseInt(localStorage.getItem('gz_embedding_scan_depth')) || 5,
        threshold: parseFloat(localStorage.getItem('gz_embedding_threshold')) || 0.45,
        topK: parseInt(localStorage.getItem('gz_embedding_top_k')) || 10,
        maxChunkTokens: parseInt(localStorage.getItem('gz_embedding_max_chunk_tokens')) || 512,
        enabled: localStorage.getItem('gz_embedding_enabled') === 'true'
    };

    return {
        ...base,
        endpoint: profile.endpoint || '',
        apiKey: profile.apiKey || '',
        model: profile.model || '',
        useSame: isSame
    };
}

export function saveEmbeddingSetting(key, value) {
    localStorage.setItem(key, value);
}

export function isEmbeddingConfigured() {
    const config = getEmbeddingConfig();
    return !!config.endpoint && !!config.model;
}
