import { reactive, ref } from 'vue';
import { getEmbeddingConfig, saveEmbeddingSetting } from '@/core/config/embeddingSettings.js';
import { testEmbeddingConnection } from '@/core/services/embeddingService.js';
import { getImageGenSettings, saveImageGenSettings } from '@/core/services/imageGenService.js';
import { getActiveLLMProfile, getServiceEffectiveProfile, getServiceProfileId, setServiceProfile, isServiceUsingLLMProfile, saveProviderProfile, createProviderProfile, SERVICE_NAMES } from '@/core/config/ProviderProfiles.js';

export function useServiceProviders() {
    const embeddingSettings = reactive({
        useSame: true,
        endpoint: '',
        key: '',
        model: '',
        target: 'content',
        scanDepth: 5,
        threshold: 0.6,
        topK: 10,
        maxChunkTokens: 8192,
        enabled: false
    });

    const embeddingStatus = ref('idle');
    const embeddingDimension = ref(null);
    const embeddingError = ref('');

    const imageGenSettings = reactive({
        useSame: true,
        endpoint: '',
        key: '',
        model: '',
        enabled: false
    });

    const memoryProviderSettings = reactive({
        useSame: true,
        endpoint: '',
        key: '',
        model: '',
        temperature: null,
        maxTokens: null
    });

    function loadEmbeddingSettings() {
        const config = getEmbeddingConfig();
        embeddingSettings.useSame = config.useSame;
        embeddingSettings.endpoint = config.useSame ? '' : config.endpoint;
        embeddingSettings.key = config.useSame ? '' : config.apiKey;
        embeddingSettings.model = config.useSame ? '' : config.model;
        embeddingSettings.maxChunkTokens = config.maxChunkTokens;
        embeddingSettings.enabled = config.enabled;
    }

    function onEmbeddingInput(key, value) {
        saveEmbeddingSetting(key, value);
        if (key === 'gz_embedding_use_same') {
            loadEmbeddingSettings();
        }
    }

    async function testEmbedding() {
        embeddingStatus.value = 'connecting';
        try {
            const result = await testEmbeddingConnection();
            embeddingDimension.value = result.dimension;
            embeddingStatus.value = 'connected';
        } catch (e) {
            console.warn('Embedding test failed:', e);
            embeddingError.value = e?.message || String(e);
            embeddingStatus.value = 'failed';
        }
    }

    function loadImageGenSettings() {
        const config = getImageGenSettings();
        const isSame = isServiceUsingLLMProfile(SERVICE_NAMES.IMAGE_GEN);
        const profile = isSame ? null : getServiceEffectiveProfile(SERVICE_NAMES.IMAGE_GEN);
        imageGenSettings.useSame = isSame;
        imageGenSettings.endpoint = isSame ? '' : (profile?.endpoint || config.endpoint || '');
        imageGenSettings.key = isSame ? '' : (profile?.apiKey || config.apiKey || '');
        imageGenSettings.model = isSame ? '' : (profile?.model || config.model || '');
        imageGenSettings.enabled = config.enabled;
    }

    function onImageGenInput(key, value) {
        if (key === 'useSame') {
            setServiceProfile(SERVICE_NAMES.IMAGE_GEN, { useSameAsLLM: value, profileId: null });
            loadImageGenSettings();
            return;
        }
        saveImageGenSettings({ [key]: value });
    }

    function loadMemoryProviderSettings() {
        const isSame = isServiceUsingLLMProfile(SERVICE_NAMES.MEMORY_BOOKS);
        const profile = isSame ? null : getServiceEffectiveProfile(SERVICE_NAMES.MEMORY_BOOKS);
        memoryProviderSettings.useSame = isSame;
        memoryProviderSettings.endpoint = isSame ? '' : (profile?.endpoint || '');
        memoryProviderSettings.key = isSame ? '' : (profile?.apiKey || '');
        memoryProviderSettings.model = isSame ? '' : (profile?.model || '');
        memoryProviderSettings.temperature = null;
        memoryProviderSettings.maxTokens = null;
    }

    function onMemoryProviderInput(key, value) {
        if (key === 'useSame') {
            setServiceProfile(SERVICE_NAMES.MEMORY_BOOKS, { useSameAsLLM: value, profileId: null });
            loadMemoryProviderSettings();
            return;
        }
        if (!memoryProviderSettings.useSame) {
            const profileId = getServiceProfileId(SERVICE_NAMES.MEMORY_BOOKS);
            if (profileId && profileId !== 'llm') {
                saveProviderProfile({
                    id: profileId,
                    [key === 'key' ? 'apiKey' : key]: value
                });
            } else {
                const newProfile = createProviderProfile('Memory Books Provider', {
                    endpoint: memoryProviderSettings.endpoint,
                    apiKey: memoryProviderSettings.key,
                    model: memoryProviderSettings.model
                });
                setServiceProfile(SERVICE_NAMES.MEMORY_BOOKS, { useSameAsLLM: false, profileId: newProfile.id });
            }
        }
    }

    function loadAllServiceSettings() {
        loadEmbeddingSettings();
        loadImageGenSettings();
        loadMemoryProviderSettings();
    }

    return {
        embeddingSettings,
        embeddingStatus,
        embeddingDimension,
        embeddingError,
        imageGenSettings,
        memoryProviderSettings,
        loadEmbeddingSettings,
        onEmbeddingInput,
        testEmbedding,
        loadImageGenSettings,
        onImageGenInput,
        loadMemoryProviderSettings,
        onMemoryProviderInput,
        loadAllServiceSettings
    };
}
