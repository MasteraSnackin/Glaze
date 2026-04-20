import { DEFAULT_PROVIDER_ID } from '@/core/llm/contracts/providerContracts.js';
import { openaiCompatibleProvider } from '@/core/llm/providers/openaiCompatibleProvider.js';

const providers = new Map([
    [openaiCompatibleProvider.id, openaiCompatibleProvider]
]);

export function getProviderById(providerId = DEFAULT_PROVIDER_ID) {
    return providers.get(providerId) || providers.get(DEFAULT_PROVIDER_ID);
}

export function listProviders() {
    return [...providers.values()];
}

export function getDefaultProvider() {
    return getProviderById(DEFAULT_PROVIDER_ID);
}
