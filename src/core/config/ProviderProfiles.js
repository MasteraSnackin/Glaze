/**
 * Unified Provider Profiles
 * 
 * Centralizes all API provider configuration (LLM, Embeddings, Image Gen, Memory Books)
 * into a single profile-based system with inheritance.
 * 
 * Profiles are stored in localStorage as JSON under 'gz_provider_profiles'.
 * Each profile contains: endpoint, apiKey, model, providerType.
 * 
 * Services can either use the main LLM profile or define their own override profile.
 * When a service uses "same as LLM", it inherits the active LLM profile's credentials.
 */

const PROFILES_KEY = 'gz_provider_profiles';
const ACTIVE_LLM_PROFILE_KEY = 'gz_active_llm_profile_id';
const SERVICE_PROFILE_MAP_KEY = 'gz_service_profile_map';

const DEFAULT_PROFILE_ID = 'default';

function loadProfiles() {
    try {
        const raw = localStorage.getItem(PROFILES_KEY);
        if (raw) {
            const parsed = JSON.parse(raw);
            if (parsed && typeof parsed === 'object') return parsed;
        }
    } catch { /* ignore */ }
    return createDefaultProfiles();
}

function saveProfiles(profiles) {
    localStorage.setItem(PROFILES_KEY, JSON.stringify(profiles));
}

function createDefaultProfiles() {
    return {
        [DEFAULT_PROFILE_ID]: {
            id: DEFAULT_PROFILE_ID,
            name: 'Default',
            endpoint: localStorage.getItem('api-endpoint') || '',
            apiKey: localStorage.getItem('api-key') || '',
            model: localStorage.getItem('api-model') || '',
            providerType: 'openai',
            createdAt: Date.now()
        }
    };
}

function migrateFromLegacy() {
    // One-time migration from legacy localStorage keys to profile system
    const migrated = localStorage.getItem('gz_provider_profiles_migrated');
    if (migrated === '1') return;

    const profiles = loadProfiles();
    profiles[DEFAULT_PROFILE_ID].endpoint = localStorage.getItem('api-endpoint') || profiles[DEFAULT_PROFILE_ID].endpoint;
    profiles[DEFAULT_PROFILE_ID].apiKey = localStorage.getItem('api-key') || profiles[DEFAULT_PROFILE_ID].apiKey;
    profiles[DEFAULT_PROFILE_ID].model = localStorage.getItem('api-model') || profiles[DEFAULT_PROFILE_ID].model;
    saveProfiles(profiles);
    localStorage.setItem('gz_provider_profiles_migrated', '1');
}

// ---- Profile CRUD ----

export function getProviderProfiles() {
    migrateFromLegacy();
    return loadProfiles();
}

export function getProviderProfile(id) {
    const profiles = getProviderProfiles();
    return profiles[id] || null;
}

export function getActiveLLMProfile() {
    const profiles = getProviderProfiles();
    const activeId = localStorage.getItem(ACTIVE_LLM_PROFILE_KEY) || DEFAULT_PROFILE_ID;
    return profiles[activeId] || profiles[DEFAULT_PROFILE_ID] || createDefaultProfiles()[DEFAULT_PROFILE_ID];
}

export function setActiveLLMProfile(id) {
    localStorage.setItem(ACTIVE_LLM_PROFILE_KEY, id);
}

export function saveProviderProfile(profile) {
    const profiles = getProviderProfiles();
    profiles[profile.id] = {
        ...profiles[profile.id],
        ...profile,
        updatedAt: Date.now()
    };
    saveProfiles(profiles);
}

export function deleteProviderProfile(id) {
    if (id === DEFAULT_PROFILE_ID) return false; // Cannot delete default
    const profiles = getProviderProfiles();
    delete profiles[id];
    saveProfiles(profiles);
    // If active LLM profile was deleted, reset to default
    if (localStorage.getItem(ACTIVE_LLM_PROFILE_KEY) === id) {
        localStorage.setItem(ACTIVE_LLM_PROFILE_KEY, DEFAULT_PROFILE_ID);
    }
    return true;
}

export function createProviderProfile(name, { endpoint = '', apiKey = '', model = '', providerType = 'openai' } = {}) {
    const id = `profile_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 6)}`;
    const profile = {
        id,
        name: name || 'New Profile',
        endpoint,
        apiKey,
        model,
        providerType,
        createdAt: Date.now()
    };
    saveProviderProfile(profile);
    return profile;
}

// ---- Service-to-Profile Mapping ----

const SERVICE_NAMES = {
    LLM: 'llm',
    EMBEDDING: 'embedding',
    IMAGE_GEN: 'image_gen',
    MEMORY_BOOKS: 'memory_books'
};

function getServiceProfileMap() {
    try {
        const raw = localStorage.getItem(SERVICE_PROFILE_MAP_KEY);
        if (raw) return JSON.parse(raw);
    } catch { /* ignore */ }
    return {
        [SERVICE_NAMES.LLM]: { useSameAsLLM: false, profileId: DEFAULT_PROFILE_ID },
        [SERVICE_NAMES.EMBEDDING]: { useSameAsLLM: true, profileId: null },
        [SERVICE_NAMES.IMAGE_GEN]: { useSameAsLLM: true, profileId: null },
        [SERVICE_NAMES.MEMORY_BOOKS]: { useSameAsLLM: true, profileId: null }
    };
}

function saveServiceProfileMap(map) {
    localStorage.setItem(SERVICE_PROFILE_MAP_KEY, JSON.stringify(map));
}

export function setServiceProfile(serviceName, { useSameAsLLM, profileId }) {
    const map = getServiceProfileMap();
    map[serviceName] = { useSameAsLLM, profileId };
    saveServiceProfileMap(map);
}

export function getServiceEffectiveProfile(serviceName) {
    const map = getServiceProfileMap();
    const config = map[serviceName];
    if (!config) return getActiveLLMProfile();
    
    if (config.useSameAsLLM || !config.profileId) {
        return getActiveLLMProfile();
    }
    
    const profile = getProviderProfile(config.profileId);
    return profile || getActiveLLMProfile();
}

export function isServiceUsingLLMProfile(serviceName) {
    const map = getServiceProfileMap();
    return map[serviceName]?.useSameAsLLM ?? true;
}

export function getServiceProfileId(serviceName) {
    const map = getServiceProfileMap();
    return map[serviceName]?.profileId || null;
}

// ---- Convenience exports ----

export { SERVICE_NAMES };

export function getLLMProfile() {
    return getServiceEffectiveProfile(SERVICE_NAMES.LLM);
}

export function getEmbeddingProfile() {
    return getServiceEffectiveProfile(SERVICE_NAMES.EMBEDDING);
}

export function getImageGenProfile() {
    return getServiceEffectiveProfile(SERVICE_NAMES.IMAGE_GEN);
}

export function getMemoryBooksProfile() {
    return getServiceEffectiveProfile(SERVICE_NAMES.MEMORY_BOOKS);
}

// ---- Legacy compatibility helpers ----

/**
 * Returns legacy-shaped config for services that expect old format.
 * This is a bridge during migration.
 */
export function getLegacyApiConfig() {
    const profile = getLLMProfile();
    return {
        providerId: 'openai_compatible',
        endpoint: profile.endpoint,
        apiUrl: profile.endpoint,
        key: profile.apiKey,
        apiKey: profile.apiKey,
        model: profile.model
    };
}

export function getLegacyEmbeddingConfig() {
    const profile = getEmbeddingProfile();
    return {
        endpoint: profile.endpoint,
        apiKey: profile.apiKey,
        model: profile.model
    };
}

// ---- Sync key sharing toggle ----

const SYNC_KEYS_ENABLED_KEY = 'gz_sync_include_api_keys';

export function isSyncIncludingApiKeys() {
    return localStorage.getItem(SYNC_KEYS_ENABLED_KEY) === 'true';
}

export function setSyncIncludeApiKeys(value) {
    localStorage.setItem(SYNC_KEYS_ENABLED_KEY, value ? 'true' : 'false');
}

// Initialize
migrateFromLegacy();
