import { reactive, ref } from 'vue';
import { getEmbeddingConfig, saveEmbeddingSetting } from '@/core/config/embeddingSettings.js';
import { testEmbeddingConnection } from '@/core/services/embeddingService.js';
import { getImageGenSettings, saveImageGenSettings } from '@/core/services/imageGenService.js';
import { getActiveLLMProfile, getServiceEffectiveProfile, getServiceProfileId, setServiceProfile, isServiceUsingLLMProfile, saveProviderProfile, createProviderProfile, getProviderProfiles, deleteProviderProfile, SERVICE_NAMES } from '@/core/config/ProviderProfiles.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';

const t = (key) => translations[currentLang.value]?.[key] || key;

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

    function saveProfileField(serviceName, providerName, key, value) {
        const profileId = getServiceProfileId(serviceName);
        if (profileId && profileId !== 'llm' && profileId !== 'default') {
            saveProviderProfile({ id: profileId, [key]: value });
        } else {
            const newProfile = createProviderProfile(providerName, {});
            newProfile[key] = value;
            saveProviderProfile(newProfile);
            setServiceProfile(serviceName, { useSameAsLLM: false, profileId: newProfile.id });
        }
    }

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
        if (key === 'useSame') {
            setServiceProfile(SERVICE_NAMES.EMBEDDING, { useSameAsLLM: value, profileId: null });
            loadAllServiceSettings();
            return;
        }

        if (['endpoint', 'apiKey', 'model'].includes(key)) {
            if (!embeddingSettings.useSame) {
                saveProfileField(SERVICE_NAMES.EMBEDDING, 'Embeddings Provider', key, value);
            }
        } else {
            saveEmbeddingSetting(key, value);
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
            loadAllServiceSettings();
            return;
        }

        if (['endpoint', 'apiKey', 'model'].includes(key)) {
            if (!imageGenSettings.useSame) {
                saveProfileField(SERVICE_NAMES.IMAGE_GEN, 'Image Gen Provider', key, value);
            }
        } else {
            saveImageGenSettings({ [key]: value });
        }
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
            loadAllServiceSettings();
            return;
        }

        if (!memoryProviderSettings.useSame) {
            saveProfileField(SERVICE_NAMES.MEMORY_BOOKS, 'Memory Books Provider', key, value);
        }
    }

    function loadAllServiceSettings() {
        loadEmbeddingSettings();
        loadImageGenSettings();
        loadMemoryProviderSettings();
    }

    function getPresetIcon(endpoint, isActive) {
        const dotColor = isActive ? 'var(--vk-blue)' : 'var(--text-gray)';
        const dotSvg = `<svg viewBox="0 0 24 24" style="fill:currentColor;"><circle cx="12" cy="12" r="10" fill="${dotColor}"/></svg>`;

        if (!endpoint) return dotSvg;

        let origin;
        try {
            const href = /^https?:\/\//i.test(endpoint) ? endpoint : 'http://' + endpoint;
            origin = new URL(href).origin;
        } catch {
            return dotSvg;
        }

        const faviconUrl = origin + '/favicon.ico';
        return `<span style="display:inline-flex;align-items:center;justify-content:center;width:100%;height:100%;"><img src="${faviconUrl}" style="width:100%;height:100%;border-radius:6px;object-fit:contain;" onerror="this.style.display='none';this.nextElementSibling.style.display='block'"><svg style="display:none;fill:currentColor;width:100%;height:100%;" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10" fill="${dotColor}"/></svg></span>`;
    }

    function getActiveProfileMeta(serviceName) {
        const isSame = isServiceUsingLLMProfile(serviceName);
        if (isSame) return { name: 'LLM API', icon: getPresetIcon('', true) };
        const profile = getServiceEffectiveProfile(serviceName);
        return { name: profile?.name || 'Local', icon: getPresetIcon(profile?.endpoint, true) };
    }

    function openProviderSelector(serviceName) {
        const profiles = getProviderProfiles();
        const activeProfileId = getServiceProfileId(serviceName);

        const cardItems = Object.values(profiles).map(p => {
            const isActive = activeProfileId === p.id;
            const item = {
                label: p.name,
                sublabel: isActive ? (t('preset_active') || 'Active') : p.endpoint || t('label_local') || 'Local/Default',
                icon: getPresetIcon(p.endpoint, isActive),
                onClick: () => {
                    setServiceProfile(serviceName, { useSameAsLLM: false, profileId: p.id });
                    loadAllServiceSettings();
                    closeBottomSheet();
                }
            };

            if (p.id !== 'default') {
                item.actions = [{
                    icon: '<svg viewBox="0 0 24 24"><path d="M12 8c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm0 2c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2zm0 6c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2z"/></svg>',
                    color: 'var(--text-gray)',
                    onClick: (e) => {
                        e.stopPropagation();
                        closeBottomSheet();
                        openProviderOptions(p, serviceName);
                    }
                }];
            }
            return item;
        });

        cardItems.push({
            label: t('action_create_new') || 'Create New',
            sublabel: t('api_create_preset_desc') || 'Add new profile',
            icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
            onClick: () => {
                closeBottomSheet();
                createNewProviderProfile(serviceName);
            }
        });

        showBottomSheet({
            title: t('label_select_profile') || 'Select Profile',
            cardItems
        });
    }

    function openProviderOptions(preset, serviceName) {
        const items = [
            {
                label: t('action_edit_name') || 'Change Name',
                icon: '<svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    showBottomSheet({
                        title: t('action_edit_name') || 'Change Name',
                        input: {
                            placeholder: t('placeholder_preset_name') || 'Enter name',
                            value: preset.name,
                            confirmLabel: t('btn_save') || 'Save',
                            onConfirm: (val) => {
                                if (val) {
                                    preset.name = val;
                                    saveProviderProfile(preset);
                                    openProviderSelector(serviceName);
                                }
                            }
                        }
                    });
                }
            },
            {
                label: t('btn_delete') || 'Delete',
                icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                iconColor: '#ff4444',
                isDestructive: true,
                onClick: () => {
                    closeBottomSheet();
                    showBottomSheet({
                        title: `${t('confirm_delete_preset')} "${preset.name}"?`,
                        items: [
                            {
                                label: t('btn_delete') || 'Delete',
                                icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                                iconColor: '#ff4444',
                                isDestructive: true,
                                onClick: () => {
                                    deleteProviderProfile(preset.id);
                                    if (getServiceProfileId(serviceName) === preset.id) {
                                        setServiceProfile(serviceName, { useSameAsLLM: false, profileId: 'default' });
                                        loadAllServiceSettings();
                                    }
                                    closeBottomSheet();
                                }
                            },
                            {
                                label: t('btn_cancel') || 'Cancel',
                                icon: '<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>',
                                onClick: closeBottomSheet
                            }
                        ]
                    });
                }
            }
        ];
        showBottomSheet({ title: preset.name, items });
    }

    function createNewProviderProfile(serviceName) {
        showBottomSheet({
            title: t('new_preset') || 'New Preset',
            input: {
                placeholder: t('placeholder_preset_name') || 'Enter preset name',
                value: '',
                confirmLabel: t('btn_create') || 'Create',
                onConfirm: (name) => {
                    if (name) {
                        const profile = createProviderProfile(name, { endpoint: '', apiKey: '', model: '' });
                        setServiceProfile(serviceName, { useSameAsLLM: false, profileId: profile.id });
                        loadAllServiceSettings();
                        closeBottomSheet();
                    }
                }
            }
        });
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
        loadAllServiceSettings,
        openProviderSelector,
        getActiveProfileMeta
    };
}
