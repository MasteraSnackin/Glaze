import { ref, reactive, computed } from 'vue';
import { normalizeEndpoint, fetchRemoteModels, getApiPresets, saveApiPresets, getApiRuntimeStorage, saveApiRuntimeSetting, applyApiRuntimeConfig, getApiProviderId, getBlacklistedProvider } from '@/core/config/APISettings.js';
import { showBottomSheet, closeBottomSheet, bottomSheetState } from '@/core/states/bottomSheetState.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';

const t = (key) => translations[currentLang.value]?.[key] || key;

export function useApiSettings() {
    const apiSettings = reactive({
        endpoint: '',
        key: '',
        model: '',
        maxTokens: 8000,
        contextSize: 32000,
        temp: 0.7,
        topP: 0.9,
        stream: true,
        autoHideImages: false,
        autoHideImagesN: 1,
        reasoningEnabled: false,
        reasoningEffort: 'medium'
    });

    const showApiKey = ref(false);
    const errorMessage = ref('');
    const apiStatus = ref('idle');
    const availableModels = ref([]);
    const apiPresets = ref([]);
    const activeApiPresetId = ref('default');

    const activeApiPreset = computed(() => {
        return apiPresets.value.find(p => p.id === activeApiPresetId.value) || apiPresets.value[0];
    });

    let blacklistCountdownTimer = null;

    function showBlacklistWarning(providerName) {
        if (blacklistCountdownTimer) clearInterval(blacklistCountdownTimer);
        let countdown = 10;
        showBottomSheet({
            title: providerName,
            locked: true,
            bigInfo: {
                icon: '<svg viewBox="0 0 24 24" style="fill:#ff9800"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z"/></svg>',
                description: t('blacklist_warning_desc').replace('{providerName}', providerName),
                glossaryChip: { term: 'api', hint: t('blacklist_glossary_hint') || 'Recommended providers are here:', label: t('blacklist_glossary_chip') || 'Providers' },
                buttonText: `OK (${countdown})`,
                buttonDisabled: true,
                onButtonClick: closeBottomSheet
            }
        });
        blacklistCountdownTimer = setInterval(() => {
            countdown--;
            if (bottomSheetState.value.bigInfo) {
                bottomSheetState.value.bigInfo.buttonText = countdown > 0 ? `OK (${countdown})` : 'OK';
                bottomSheetState.value.bigInfo.buttonDisabled = countdown > 0;
            }
            if (countdown <= 0) {
                bottomSheetState.value.locked = false;
                clearInterval(blacklistCountdownTimer);
                blacklistCountdownTimer = null;
            }
        }, 1000);
    }

    function loadApiSettings() {
        const runtime = getApiRuntimeStorage();
        apiSettings.endpoint = runtime.endpoint;
        apiSettings.key = runtime.key;
        apiSettings.model = runtime.model;
        apiSettings.maxTokens = runtime.maxTokens;
        apiSettings.contextSize = runtime.contextSize;
        apiSettings.temp = runtime.temp;
        apiSettings.topP = runtime.topP;
        apiSettings.stream = runtime.stream;
        apiSettings.autoHideImages = runtime.autoHideImages;
        apiSettings.autoHideImagesN = runtime.autoHideImagesN;
        apiSettings.reasoningEnabled = runtime.requestReasoning;
        apiSettings.reasoningEffort = runtime.reasoningEffort;
    }

    function saveApiSetting(key, value) {
        saveApiRuntimeSetting(key, value);
        
        if (activeApiPreset.value) {
            const map = {
                'api-endpoint': 'endpoint',
                'api-key': 'key',
                'api-model': 'model',
                'api-max-tokens': 'max_tokens',
                'api-context': 'context',
                'gz_api_temp': 'temp',
                'gz_api_topp': 'topp',
                'gz_api_stream': 'stream',
                'gz_api_auto_hide_images': 'auto_hide_images',
                'gz_api_auto_hide_images_n': 'auto_hide_images_n',
                'gz_api_request_reasoning': 'reasoning_enabled',
                'gz_api_reasoning_effort': 'reasoning_effort'
            };
            if (map[key]) {
                activeApiPreset.value[map[key]] = value;
                saveApiPresets(apiPresets.value);
            }
        }
    }

    let debounceTimer = null;

    function onApiInput(key, value) {
        saveApiSetting(key, value);
        if (key === 'api-endpoint' || key === 'api-key') {
            if (debounceTimer) clearTimeout(debounceTimer);
            debounceTimer = setTimeout(() => {
                if (key === 'api-endpoint') {
                    const endpoint = getApiRuntimeStorage().normalizedEndpoint || value;
                    const blacklisted = getBlacklistedProvider(endpoint);
                    if (blacklisted) showBlacklistWarning(blacklisted.name);
                }
                checkConnection();
            }, 1000);
        }
    }

    function flushApiDebounce() {
        if (debounceTimer) {
            clearTimeout(debounceTimer);
            debounceTimer = null;
            checkConnection();
        }
    }

    async function checkConnection() {
        const endpoint = getApiRuntimeStorage().normalizedEndpoint || apiSettings.endpoint;

        if (!endpoint) {
            apiStatus.value = 'failed';
            return;
        }
        
        apiStatus.value = 'connecting';
        try {
            const models = await fetchRemoteModels(endpoint, apiSettings.key);
            availableModels.value = models;
            apiStatus.value = 'connected';
        } catch (e) {
            console.warn(e);
            apiStatus.value = 'failed';
            errorMessage.value = e.message || 'Connection failed';
        }
    }

    function openModelSelector() {
        const items = availableModels.value.length > 0 ? availableModels.value.map(m => ({
            label: m,
            onClick: () => {
                apiSettings.model = m;
                saveApiSetting('api-model', m);
                closeBottomSheet();
            }
        })) : [{ label: t('no_models_found') || "No models found", onClick: closeBottomSheet }];

        showBottomSheet({ title: "Select Model", items });
    }

    function openReasoningEffortSelector() {
        const options = [
            { value: 'auto', label: t('reasoning_effort_auto') || 'Auto' },
            { value: 'low', label: t('reasoning_effort_low') || 'Low' },
            { value: 'medium', label: t('reasoning_effort_medium') || 'Medium' },
            { value: 'high', label: t('reasoning_effort_high') || 'High' }
        ];

        const items = options.map(opt => ({
            label: opt.label,
            icon: apiSettings.reasoningEffort === opt.value ? '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>' : null,
            onClick: () => {
                apiSettings.reasoningEffort = opt.value;
                saveApiSetting('gz_api_reasoning_effort', opt.value);
                closeBottomSheet();
            }
        }));

        showBottomSheet({
            title: t('label_reasoning_effort') || 'Reasoning Effort',
            items
        });
    }

    function createNewApiPreset() {
        showBottomSheet({
            title: t('new_preset') || 'New Preset',
            input: {
                placeholder: t('placeholder_preset_name') || 'Enter preset name',
                value: '',
                confirmLabel: t('btn_create') || 'Create',
                onConfirm: (name) => {
                    const newPreset = {
                        id: Date.now().toString(36),
                        name: name,
                        providerId: getApiProviderId(),
                        endpoint: apiSettings.endpoint,
                        key: apiSettings.key,
                        model: apiSettings.model,
                        max_tokens: apiSettings.maxTokens,
                        context: apiSettings.contextSize,
                        temp: apiSettings.temp,
                        topp: apiSettings.topP,
                        stream: apiSettings.stream,
                        auto_hide_images: apiSettings.autoHideImages,
                        auto_hide_images_n: apiSettings.autoHideImagesN,
                        reasoning_enabled: apiSettings.reasoningEnabled,
                        reasoning_effort: apiSettings.reasoningEffort
                    };

                    apiPresets.value.push(newPreset);
                    saveApiPresets(apiPresets.value);
                    
                    activeApiPresetId.value = newPreset.id;
                    localStorage.setItem('gz_active_api_preset_id', newPreset.id);
                    closeBottomSheet();
                }
            }
        });
    }

    function applyApiPreset(p) {
        activeApiPresetId.value = p.id;
        localStorage.setItem('gz_active_api_preset_id', p.id);
        applyApiRuntimeConfig({
            providerId: p.providerId || getApiProviderId(),
            endpoint: p.endpoint,
            apiKey: p.key,
            model: p.model,
            maxTokens: p.max_tokens,
            contextSize: p.context,
            temp: p.temp,
            topP: p.topp,
            stream: p.stream,
            autoHideImages: (p.auto_hide_images === true || p.auto_hide_images === 'true'),
            autoHideImagesN: parseInt(p.auto_hide_images_n || '1', 10),
            requestReasoning: (p.reasoning_enabled === true || p.reasoning_enabled === 'true'),
            reasoningEffort: p.reasoning_effort || 'medium'
        });
        
        apiSettings.endpoint = p.endpoint;
        apiSettings.key = p.key;
        apiSettings.model = p.model;
        apiSettings.maxTokens = p.max_tokens;
        apiSettings.contextSize = p.context;
        apiSettings.temp = p.temp;
        apiSettings.topP = p.topp;
        apiSettings.stream = p.stream;
        
        apiSettings.autoHideImages = (p.auto_hide_images === true || p.auto_hide_images === 'true');
        apiSettings.autoHideImagesN = parseInt(p.auto_hide_images_n || '1', 10);
        apiSettings.reasoningEnabled = (p.reasoning_enabled === true || p.reasoning_enabled === 'true');
        apiSettings.reasoningEffort = p.reasoning_effort || 'medium';
        
        checkConnection();
    }

    function confirmDeleteApiPreset(id) {
        const preset = apiPresets.value.find(p => p.id === id);
        if (!preset) return;

        showBottomSheet({
            title: `${t('confirm_delete_preset')} "${preset.name}"?`,
            items: [
                {
                    label: t('btn_delete') || 'Delete',
                    icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                    iconColor: '#ff4444',
                    isDestructive: true,
                    onClick: () => {
                        const index = apiPresets.value.findIndex(p => p.id === id);
                        if (index !== -1) {
                            apiPresets.value.splice(index, 1);
                            saveApiPresets(apiPresets.value);

                            if (activeApiPresetId.value === id) {
                                const defaultPreset = apiPresets.value.find(p => p.id === 'default') || apiPresets.value[0];
                                if (defaultPreset) {
                                    applyApiPreset(defaultPreset);
                                }
                            }
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

    function openApiPresetOptions(preset) {
        const items = [];

        items.push({
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
                                saveApiPresets(apiPresets.value);
                                closeBottomSheet();
                            }
                        }
                    }
                });
            }
        });

        items.push({
            label: t('btn_delete') || 'Delete',
            icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
            iconColor: '#ff4444',
            isDestructive: true,
            onClick: () => {
                closeBottomSheet();
                confirmDeleteApiPreset(preset.id);
            }
        });

        showBottomSheet({
            title: preset.name,
            items
        });
    }

    function openApiPresetSelector() {
        const cardItems = apiPresets.value.map(p => {
            const isActive = activeApiPresetId.value === p.id;
            const item = {
                label: p.name,
                sublabel: isActive ? (t('preset_active') || 'Active') : '',
                icon: getPresetIcon(p.endpoint, isActive),
                onClick: () => {
                    applyApiPreset(p);
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
                        openApiPresetOptions(p);
                    }
                }];
            }

            return item;
        });

        cardItems.push({
            label: t('action_create_new') || 'Create New',
            sublabel: t('api_create_preset_desc') || 'Add new preset',
            icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
            onClick: () => {
                closeBottomSheet();
                createNewApiPreset();
            }
        });

        showBottomSheet({
            title: t('api_presets') || 'API Presets',
            cardItems
        });
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

    async function initPresets() {
        apiPresets.value = await getApiPresets();
        activeApiPresetId.value = localStorage.getItem('gz_active_api_preset_id') || 'default';
    }

    function cleanup() {
        flushApiDebounce();
        if (blacklistCountdownTimer) clearInterval(blacklistCountdownTimer);
    }

    return {
        apiSettings,
        showApiKey,
        errorMessage,
        apiStatus,
        availableModels,
        apiPresets,
        activeApiPresetId,
        activeApiPreset,
        loadApiSettings,
        saveApiSetting,
        onApiInput,
        flushApiDebounce,
        checkConnection,
        openModelSelector,
        openReasoningEffortSelector,
        createNewApiPreset,
        applyApiPreset,
        confirmDeleteApiPreset,
        openApiPresetOptions,
        openApiPresetSelector,
        getPresetIcon,
        initPresets,
        cleanup
    };
}
