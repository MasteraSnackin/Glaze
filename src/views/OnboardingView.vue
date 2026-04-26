<script setup>
import { ref, computed, reactive, onMounted, onUnmounted } from 'vue';
import { addPersona, allPersonas, deletePersona } from '@/core/states/personaState.js';
import { normalizeEndpoint, fetchRemoteModels, getApiPresets, saveApiPresets, getApiProviderId, applyApiRuntimeConfig } from '@/core/config/APISettings.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import BackupSheet from '@/components/sheets/BackupSheet.vue';
import { translations } from '@/utils/i18n.js';
import { currentLang, forceMobileLayout } from '@/core/config/APPSettings.js';
import { convertSTPreset, convertLatexPreset, detectPresetFormat, finalizeImportedPreset } from '@/core/services/presetImportService.js';
import { requestNotificationPermission } from '@/core/services/notificationService.js';
import { presetState, initPresetState, savePresets, setPresetConnection } from '@/core/states/presetState.js';
import { isKeyboardOpen as globalKeyboardOpen } from '@/core/services/keyboardHandler.js';
import { userDefaultPresets } from '@/core/states/defaultPresets.js';

const t = (key) => translations[currentLang.value]?.[key] || key;

const emit = defineEmits(['finish']);

// Desktop detection
const isDesktop = ref(typeof window !== 'undefined' && window.innerWidth >= 768 && !forceMobileLayout.value);

const checkDesktop = () => {
    isDesktop.value = typeof window !== 'undefined' && window.innerWidth >= 768 && !forceMobileLayout.value;
};

onMounted(() => {
    window.addEventListener('resize', checkDesktop);
});

onUnmounted(() => {
    window.removeEventListener('resize', checkDesktop);
});



const currentSlide = ref(0);

const backupSheet = ref(null);

const triggerRestore = () => {
    if (backupSheet.value) backupSheet.value.open();
};

// Form Data
const apiSettings = reactive({
    endpoint: '',
    key: '',
    model: ''
});

const apiStatus = ref('idle');
let debounceTimer = null;

const apiStatusText = computed(() => {
    const map = {
        'idle': t('onboarding_status_idle'),
        'connecting': t('onboarding_status_connecting'),
        'connected': t('onboarding_status_connected'),
        'failed': t('onboarding_status_failed')
    };
    return map[apiStatus.value] || apiStatus.value;
});

const personaConfig = reactive({
    name: '',
    desc: '',
    avatar: null
});

const avatarInput = ref(null);

function triggerAvatarUpload() {
    if (avatarInput.value) avatarInput.value.click();
}

function handleAvatarChange(e) {
    const file = e.target.files[0];
    if (file) {
        const reader = new FileReader();
        reader.onload = (ev) => {
            personaConfig.avatar = ev.target.result;
        };
        reader.readAsDataURL(file);
    }
}

const introContent = computed(() => [
    {
        title: t('onboarding_slide1_subtitle'),
        desc: t('onboarding_slide1_desc'),
        icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5"/></svg>'
    },
    {
        title: t('onboarding_slide2_title'),
        desc: t('onboarding_slide2_desc'),
        icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></svg>'
    },
    {
        title: t('onboarding_slide5_title'),
        desc: t('onboarding_slide5_desc'),
        icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg>'
    }
]);

const featuresContent = computed(() => [
    {
        title: t('onboarding_feature_imggen_title'),
        desc: t('onboarding_feature_imggen_desc'),
        icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/></svg>'
    },
    {
        title: t('onboarding_feature_glossary_title'),
        desc: t('onboarding_feature_glossary_desc'),
        icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20"/><path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z"/></svg>'
    },
    {
        title: t('onboarding_feature_custom_title'),
        desc: t('onboarding_feature_custom_desc'),
        icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2L2 7l10 5 10-5-10-5z"/><path d="M2 17l10 5 10-5"/><path d="M2 12l10 5 10-5"/></svg>'
    },
    {
        title: t('onboarding_feature_st_title'),
        desc: t('onboarding_feature_st_desc'),
        icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><path d="M9 15l2 2 4-4"/></svg>'
    }
]);

const slides = computed(() => [
    {
        type: 'welcome',
        title: t('onboarding_slide1_title'),
    },
    {
        type: 'features',
        title: t('onboarding_features_title'),
    },
    {
        type: 'data_import',
        title: t('onboarding_slide_import_title'),
        desc: t('onboarding_slide_import_desc'),
        icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>'
    },
    {
        type: 'api',
        title: t('onboarding_slide3_title'),
        desc: t('onboarding_slide3_desc'),
        icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="2" width="20" height="8" rx="2" ry="2"></rect><rect x="2" y="14" width="20" height="8" rx="2" ry="2"></rect><line x1="6" y1="6" x2="6.01" y2="6"></line><line x1="6" y1="18" x2="6.01" y2="18"></line></svg>'
    },
    {
        type: 'persona',
        title: t('onboarding_slide4_title'),
        desc: t('onboarding_slide4_desc'),
        icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>'
    },
    {
        type: 'preset_import',
        title: t('onboarding_slide_preset_title'),
        desc: t('onboarding_slide_preset_desc'),
        icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path><polyline points="14 2 14 8 20 8"></polyline><line x1="12" y1="18" x2="12" y2="12"></line><line x1="9" y1="15" x2="15" y2="15"></line></svg>'
    },
    {
        type: 'notifications',
        title: t('notification_permission_title'),
        desc: t('notification_permission_desc'),
        icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;"><path d="M12 22c1.1 0 2-.9 2-2h-4c0 1.1.9 2 2 2zm6-6v-5c0-3.07-1.63-5.64-4.5-6.32V4c0-.83-.67-1.5-1.5-1.5s-1.5.67-1.5 1.5v.68C7.64 5.36 6 7.92 6 11v5l-2 2v1h16v-1l-2-2zm-2 1H8v-6c0-2.48 1.51-4.5 4-4.5s4 2.02 4 4.5v6z"/></svg>'
    },
    {
        type: 'all-set',
        title: t('onboarding_slide_all_set_title'),
        desc: t('onboarding_slide_all_set_desc'),
        icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg>'
    }
]);

const isLastSlide = computed(() => currentSlide.value === slides.value.length - 1);
const mainButtonLabel = computed(() => {
    if (isLastSlide.value) return t('onboarding_btn_start');
    
    const slide = slides.value[currentSlide.value];
    if (slide.type === 'preset_import' || slide.type === 'data_import') {
        return t('onboarding_btn_skip');
    }
    if (slide.type === 'api') {
        return apiSettings.endpoint ? t('onboarding_btn_save') : t('onboarding_btn_skip');
    }
    if (slide.type === 'persona') {
        return personaConfig.name ? t('onboarding_btn_create') : t('onboarding_btn_skip');
    }
    if (slide.type === 'notifications') {
        return t('btn_allow') || "Allow";
    }
    return t('onboarding_btn_next');
});

async function next() {
    if (slides.value[currentSlide.value].type === 'api' && apiSettings.endpoint) {
        await savePreset();
    }

    if (slides.value[currentSlide.value].type === 'notifications') {
        localStorage.setItem('gz_notification_requested', 'true');
        await requestNotificationPermission();
    }

    if (isLastSlide.value) {
        finish();
    } else {
        currentSlide.value++;
    }
}

function prev() {
    if (currentSlide.value > 0) {
        currentSlide.value--;
    }
}

function skipNotifications() {
    localStorage.setItem('gz_notification_requested', 'true');
    currentSlide.value++;
}

async function openModelSelector() {
    if (!apiSettings.endpoint) return;
    
    try {
        const normalized = normalizeEndpoint(apiSettings.endpoint);
        const models = await fetchRemoteModels(normalized, apiSettings.key);
        
        const items = models.map(m => ({
            label: m,
            onClick: () => {
                apiSettings.model = m;
                closeBottomSheet();
            }
        }));
        
        showBottomSheet({ title: t('onboarding_select_model'), items });
    } catch (e) {
        alert(t('onboarding_error_models') + ": " + e.message);
    }
}

async function checkConnection() {
    if (!apiSettings.endpoint) {
        apiStatus.value = 'idle';
        return;
    }
    
    apiStatus.value = 'connecting';
    try {
        const normalized = normalizeEndpoint(apiSettings.endpoint);
        await fetchRemoteModels(normalized, apiSettings.key);
        apiStatus.value = 'connected';
    } catch (e) {
        console.warn(e);
        apiStatus.value = 'failed';
    }
}

function onApiInput() {
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(checkConnection, 1000);
}

async function savePreset() {
    if (!apiSettings.endpoint) return;
    
    const normalized = normalizeEndpoint(apiSettings.endpoint);
    const presets = await getApiPresets();
    
    const newPreset = {
        id: Date.now().toString(36),
        name: 'Onboarding Setup',
        providerId: getApiProviderId(),
        endpoint: normalized,
        key: apiSettings.key,
        model: apiSettings.model,
        max_tokens: 8000,
        context: 32000,
        temp: 0.7,
        topp: 0.9,
        stream: true
    };
    
    presets.push(newPreset);
    await saveApiPresets(presets);
    localStorage.setItem('gz_active_api_preset_id', newPreset.id);
    applyApiRuntimeConfig({
        providerId: newPreset.providerId,
        endpoint: normalized,
        apiKey: apiSettings.key,
        model: apiSettings.model
    });
}

function triggerPresetImport() {
    const input = document.createElement('input');
    input.type = 'file';
    input.onchange = async (e) => {
        const file = e.target.files[0];
        if (!file) return;
        
        try {
            const text = await file.text();
            if (!text || !text.trim()) {
                alert(translations[currentLang.value]?.onboarding_import_error || 'File is empty or could not be read.');
                return;
            }
            const data = JSON.parse(text);
            
            initPresetState();

            const format = detectPresetFormat(data);
            let preset;

            if (format === 'latex') {
                preset = convertLatexPreset(data, file.name.replace(/\.json$/i, ''));
            } else if (format === 'sillytavern') {
                preset = convertSTPreset(data, file.name.replace(/\.json$/i, ''));
            } else if (format === 'glaze') {
                if (data.blocks) {
                    preset = data;
                } else {
                    Object.assign(presetState.presets, data);
                    savePresets();
                    next();
                    return;
                }
            } else {
                alert(translations[currentLang.value]?.onboarding_import_error || 'Unknown preset format. Expected SillyTavern, LaTeX, or Glaze JSON.');
                return;
            }

            preset = finalizeImportedPreset(preset);
            presetState.presets[preset.id] = preset;
            setPresetConnection('global', null, preset.id);
            savePresets();
            next();
        } catch (err) {
            const errorMsg = err instanceof SyntaxError
                ? 'Invalid JSON file: the file is not valid JSON.'
                : (err.message || 'Unknown error');
            alert((translations[currentLang.value]?.onboarding_import_error || 'Import error: ') + errorMsg);
        }
    };
    input.click();
}

async function finish() {
    // Create First Persona
    if (personaConfig.name) {
        const newPersona = await addPersona({
            name: personaConfig.name,
            prompt: personaConfig.desc || t('onboarding_default_persona_desc'),
            avatar: personaConfig.avatar || null
        });

        if (newPersona && newPersona.id) {
            localStorage.setItem('gz_active_persona_id', newPersona.id);
            
            // Remove default "user" persona ONLY if it exists and this is the first onboarding
            if (localStorage.getItem('glaze_onboarding_completed') !== 'true') {
                const defaultIndex = allPersonas.value.findIndex(p => p.name === 'user');
                if (defaultIndex !== -1) {
                    await deletePersona(defaultIndex);
                }
            }
        }
    }

    emit('finish');
}
</script>

<template>
    <div class="onboarding-overlay">
        <div class="onboarding-card" :class="{ 'keyboard-open': globalKeyboardOpen, 'desktop-layout': isDesktop }">
            <!-- Desktop Wizard Layout -->
            <div v-if="isDesktop" class="onboarding-shell">
                <div class="onboarding-topbar">
                    <button
                        class="nav-back-btn"
                        :class="{ 'is-visible': currentSlide > 0 }"
                        :tabindex="currentSlide > 0 ? 0 : -1"
                        :aria-hidden="currentSlide > 0 ? 'false' : 'true'"
                        @click="currentSlide > 0 && prev()"
                    >
                        <svg viewBox="0 0 24 24"><path d="M20 11H7.83l5.59-5.59L12 4l-8 8 8 8 1.41-1.41L7.83 13H20v-2z"/></svg>
                    </button>

                    <div class="stories-nav">
                        <div
                            v-for="(_, index) in slides"
                            :key="index"
                            class="story-bar"
                            :class="{ active: index === currentSlide, passed: index < currentSlide }"
                        >
                            <div class="story-fill"></div>
                        </div>
                    </div>
                </div>

                <div class="slides-container">
                    <Transition name="slide-fade" mode="out-in">
                        <div :key="currentSlide" class="wizard-layout">
                            <aside class="wizard-visual">
                                <div class="visual-stage" :class="`visual-${slides[currentSlide].type}`">
                                    <div v-if="slides[currentSlide].type === 'persona'" class="persona-hero" @click="triggerAvatarUpload">
                                        <img v-if="personaConfig.avatar" :src="personaConfig.avatar" class="persona-hero-image">
                                        <div v-else class="persona-hero-placeholder">
                                            {{ personaConfig.name ? personaConfig.name[0].toUpperCase() : '?' }}
                                        </div>
                                        <div class="persona-hero-hint">
                                            <span class="hint-desktop">{{ t('hint_change_avatar_desktop') || 'Click to change' }}</span>
                                            <span class="hint-mobile">{{ t('hint_change_avatar_mobile') || t('hint_change_avatar') || 'Tap to change' }}</span>
                                        </div>
                                        <input type="file" ref="avatarInput" accept="image/*" style="display: none;" @change="handleAvatarChange">
                                    </div>
                                    <div v-else class="icon-wrapper" v-html="slides[currentSlide].icon || introContent[0].icon"></div>
                                </div>
                            </aside>

                            <section class="wizard-content">
                                <div class="content-header">
                                    <h1 class="title">{{ slides[currentSlide].title }}</h1>
                                    <p v-if="slides[currentSlide].desc" class="description">{{ slides[currentSlide].desc }}</p>
                                </div>

                                <div class="content-body">
                                    <div v-if="slides[currentSlide].type === 'welcome' || slides[currentSlide].type === 'features'" class="intro-blocks-container">
                                        <div v-for="(item, index) in (slides[currentSlide].type === 'welcome' ? introContent : featuresContent)" :key="index" class="intro-block">
                                            <div class="intro-icon" v-html="item.icon"></div>
                                            <div class="intro-text">
                                                <h3>{{ item.title }}</h3>
                                                <p>{{ item.desc }}</p>
                                            </div>
                                        </div>
                                    </div>

                                    <div v-if="slides[currentSlide].type === 'api'" class="setup-form-container">
                                        <div class="menu-group setup-panel">
                                            <div class="section-header section-header-flex">
                                                <span>{{ t('onboarding_connection') }}</span>
                                                <div class="api-status-badge" @click="checkConnection">
                                                    <div class="status-dot" :class="apiStatus"></div>
                                                    <Transition name="status-fade" mode="out-in">
                                                        <span class="status-text" :key="apiStatus">{{ apiStatusText }}</span>
                                                    </Transition>
                                                </div>
                                            </div>
                                            <div class="settings-item">
                                                <label>{{ t('onboarding_label_endpoint') }}</label>
                                                <input type="text" v-model="apiSettings.endpoint" @input="onApiInput" placeholder="http://127.0.0.1:5000/v1" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false">
                                            </div>
                                            <div class="settings-item">
                                                <label>{{ t('onboarding_label_model') }}</label>
                                                <div class="model-input-wrap">
                                                    <input type="text" v-model="apiSettings.model" placeholder="gemini-3-pro-preview" class="model-input" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false">
                                                    <div @click="openModelSelector" class="model-selector-btn">
                                                        <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
                                                    </div>
                                                </div>
                                            </div>
                                            <div class="settings-item">
                                                <label>{{ t('onboarding_label_key') }}</label>
                                                <input type="password" v-model="apiSettings.key" @input="onApiInput" placeholder="sk-..." autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false">
                                            </div>
                                        </div>
                                    </div>

                                    <div v-if="slides[currentSlide].type === 'persona'" class="setup-form-container">
                                        <div class="menu-group setup-panel">
                                            <div class="section-header">{{ t('avatar') || 'Avatar' }}</div>
                                            <div class="settings-item">
                                                <label>{{ t('onboarding_label_name') }}</label>
                                                <input type="text" v-model="personaConfig.name" :placeholder="t('onboarding_placeholder_name')">
                                            </div>
                                            <div class="settings-item" style="border-bottom: none;">
                                                <label>{{ t('onboarding_label_desc') }}</label>
                                                <textarea v-model="personaConfig.desc" :placeholder="t('onboarding_placeholder_desc')" rows="3"></textarea>
                                            </div>
                                        </div>
                                    </div>

                                    <div v-if="slides[currentSlide].type === 'preset_import'" class="preset-selector-list">
                                        <div class="ps-list">
                                            <div v-for="preset in userDefaultPresets" :key="preset.id"
                                                 class="ps-card"
                                                 :class="{ 'ps-has-bg': !!preset.image }"
                                                 :style="preset.image ? { backgroundImage: 'url(' + preset.image + ')' } : {}">
                                                <div class="ps-card-overlay" v-if="preset.image"></div>

                                                <div class="ps-card-icon" v-if="!preset.image">
                                                    <svg viewBox="0 0 24 24"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-5 14H7v-2h7v2zm3-4H7v-2h10v2zm0-4H7V7h10v2z"/></svg>
                                                </div>

                                                <div class="ps-card-info">
                                                    <div class="ps-card-name" :class="{ 'ps-with-bg': !!preset.image }">{{ preset.name || 'Default' }}</div>
                                                    <div class="ps-card-meta" :class="{ 'ps-with-bg': !!preset.image }">
                                                        <div v-if="preset.author" class="ps-author-line">by {{ preset.author }}</div>
                                                        <div v-if="preset.descriptionKey" class="ps-desc-line">{{ t(preset.descriptionKey) }}</div>
                                                    </div>
                                                </div>
                                            </div>

                                            <p class="hint-line">{{ t('onboarding_preset_import_st_hint') }}</p>

                                            <div class="intro-block clickable" @click="triggerPresetImport">
                                                <div class="intro-icon">
                                                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
                                                </div>
                                                <div class="intro-text">
                                                    <h3>{{ t('onboarding_btn_import_preset') }}</h3>
                                                    <p>JSON</p>
                                                </div>
                                            </div>
                                        </div>
                                    </div>

                                    <div v-if="slides[currentSlide].type === 'data_import'" class="intro-blocks-container">
                                        <div class="intro-block clickable" @click="triggerRestore">
                                            <div class="intro-icon">
                                                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
                                            </div>
                                            <div class="intro-text">
                                                <h3>{{ t('onboarding_btn_import_backup') }}</h3>
                                                <p>{{ t('menu_backups') }}</p>
                                            </div>
                                        </div>
                                    </div>
                                </div>

                                <div class="onboarding-footer">
                                    <div class="controls">
                                        <button class="btn-primary full-width" @click="next">
                                            {{ mainButtonLabel }}
                                        </button>
                                        <button
                                            v-if="slides[currentSlide].type === 'notifications'"
                                            class="btn-secondary full-width"
                                            @click="skipNotifications"
                                        >
                                            {{ t('btn_later') || "Later" }}
                                        </button>
                                    </div>
                                </div>
                            </section>
                        </div>
                    </Transition>
                </div>
            </div>

            <!-- Mobile Layout -->
            <div v-else class="mobile-shell">
                <!-- Header with skip/progress -->
                <div class="onboarding-header">
                    <div class="onboarding-header-gradient"></div>
                    <!-- Stories Progress Bar -->
                    <div class="stories-nav">
                        <div 
                            v-for="(_, index) in slides" 
                            :key="index" 
                            class="story-bar"
                            :class="{ active: index === currentSlide, passed: index < currentSlide }"
                        >
                            <div class="story-fill"></div>
                        </div>
                    </div>

                    <button v-if="currentSlide > 0" class="nav-back-btn" @click="prev">
                        <svg viewBox="0 0 24 24"><path d="M20 11H7.83l5.59-5.59L12 4l-8 8 8 8 1.41-1.41L7.83 13H20v-2z"/></svg>
                    </button>
                </div>
                <div class="slides-container">
                    <Transition name="slide-fade" mode="out-in">
                        <div :key="currentSlide" class="slide" :class="{ 'welcome-align': ['welcome', 'features'].includes(slides[currentSlide].type) }">
                            
                            <!-- Welcome / Features Slide -->
                            <div v-if="slides[currentSlide].type === 'welcome' || slides[currentSlide].type === 'features'" class="welcome-slide">
                                <div class="welcome-header">
                                    <h1 class="welcome-title">{{ slides[currentSlide].title }}</h1>
                                </div>
                                
                                <div class="intro-blocks-container">
                                    <div v-for="(item, index) in (slides[currentSlide].type === 'welcome' ? introContent : featuresContent)" :key="index" class="intro-block">
                                        <div class="intro-icon" v-html="item.icon"></div>
                                        <div class="intro-text">
                                            <h3>{{ item.title }}</h3>
                                            <p>{{ item.desc }}</p>
                                        </div>
                                    </div>
                                </div>
                            </div>

                            <!-- Standard Slides -->
                            <div v-else class="standard-slide">
                                <div class="icon-wrapper" v-if="slides[currentSlide].icon && slides[currentSlide].type !== 'persona'" v-html="slides[currentSlide].icon"></div>
                                <h1 class="title">{{ slides[currentSlide].title }}</h1>
                                <p class="description">{{ slides[currentSlide].desc }}</p>
                            </div>

                            <!-- API Setup Slide -->
                            <div v-if="slides[currentSlide].type === 'api'" class="setup-form-container">
                                <div class="menu-group" style="margin: 0; width: 100%; text-align: left;">
                                    <div class="section-header section-header-flex">
                                        <span>{{ t('onboarding_connection') }}</span>
                                        <div class="api-status-badge" @click="checkConnection">
                                            <div class="status-dot" :class="apiStatus"></div>
                                            <Transition name="status-fade" mode="out-in">
                                                <span class="status-text" :key="apiStatus">{{ apiStatusText }}</span>
                                            </Transition>
                                        </div>
                                    </div>
                                    <div class="settings-item">
                                        <label>{{ t('onboarding_label_endpoint') }}</label>
                                        <input type="text" v-model="apiSettings.endpoint" @input="onApiInput" placeholder="http://127.0.0.1:5000/v1" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false">
                                    </div>
                                    <div class="settings-item">
                                        <label>{{ t('onboarding_label_model') }}</label>
                                        <div style="position: relative;">
                                            <input type="text" v-model="apiSettings.model" placeholder="gemini-3-pro-preview" style="width: 100%; padding-right: 44px;" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false">
                                            <div @click="openModelSelector" style="position: absolute; right: 0; top: 0; bottom: 0; width: 44px; cursor: pointer; display: flex; align-items: center; justify-content: center;">
                                                <svg viewBox="0 0 24 24" style="width: 24px; height: 24px; fill: #818C99;"><path d="M7 10l5 5 5-5z"/></svg>
                                            </div>
                                        </div>
                                    </div>
                                    <div class="settings-item">
                                        <label>{{ t('onboarding_label_key') }}</label>
                                        <input type="password" v-model="apiSettings.key" @input="onApiInput" placeholder="sk-..." autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false">
                                    </div>
                                </div>
                            </div>

                            <!-- Persona Setup Slide -->
                            <div v-if="slides[currentSlide].type === 'persona'" class="setup-form-container">
                                <div class="menu-group" style="margin: 0; width: 100%; text-align: left;">
                                    <!-- Avatar Card inside menu-group -->
                                    <div class="avatar-card" @click="triggerAvatarUpload">
                                        <div class="avatar-wrapper">
                                            <div class="avatar-header-overlay">{{ t('avatar') || 'Avatar' }}</div>
                                            <img v-if="personaConfig.avatar" :src="personaConfig.avatar" class="avatar-img">
                                            <div v-else class="avatar-placeholder">
                                                {{ personaConfig.name ? personaConfig.name[0].toUpperCase() : '?' }}
                                            </div>
                                            <div class="avatar-overlay-hint">{{ t('hint_change_avatar') || 'Tap to change' }}</div>
                                        </div>
                                        <input type="file" ref="avatarInput" accept="image/*" style="display: none;" @change="handleAvatarChange">
                                    </div>
                                    <div class="settings-item">
                                        <label>{{ t('onboarding_label_name') }}</label>
                                        <input type="text" v-model="personaConfig.name" :placeholder="t('onboarding_placeholder_name')">
                                    </div>
                                    <div class="settings-item" style="border-bottom: none;">
                                        <label>{{ t('onboarding_label_desc') }}</label>
                                        <textarea v-model="personaConfig.desc" :placeholder="t('onboarding_placeholder_desc')" rows="3"></textarea>
                                    </div>
                                </div>
                            </div>

                            <div v-if="slides[currentSlide].type === 'preset_import'" style="width: 100%;" class="preset-selector-list">
                                <!-- Defaults List (PresetView style) -->
                                <div class="ps-list">
                                    <div v-for="preset in userDefaultPresets" :key="preset.id"
                                         class="ps-card"
                                         :class="{ 'ps-has-bg': !!preset.image }"
                                         :style="preset.image ? { backgroundImage: 'url(' + preset.image + ')' } : {}">
                                        
                                        <!-- Overlay for image cards -->
                                        <div class="ps-card-overlay" v-if="preset.image"></div>
                                        
                                        <!-- Icon only for non-image cards -->
                                        <div class="ps-card-icon" v-if="!preset.image">
                                            <svg viewBox="0 0 24 24"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-5 14H7v-2h7v2zm3-4H7v-2h10v2zm0-4H7V7h10v2z"/></svg>
                                        </div>

                                        <!-- Info -->
                                        <div class="ps-card-info">
                                            <div class="ps-card-name" :class="{ 'ps-with-bg': !!preset.image }">{{ preset.name || 'Default' }}</div>
                                            <div class="ps-card-meta" :class="{ 'ps-with-bg': !!preset.image }">
                                                <div v-if="preset.author" class="ps-author-line">by {{ preset.author }}</div>
                                                <div v-if="preset.descriptionKey" class="ps-desc-line">{{ t(preset.descriptionKey) }}</div>
                                            </div>
                                        </div>
                                    </div>

                                    <p class="description" style="margin-top: 16px; margin-bottom: 8px; font-size: 14px; opacity: 0.8; width: 100%; text-align: center;">
                                        {{ t('onboarding_preset_import_st_hint') }}
                                    </p>

                                    <div class="intro-block clickable" @click="triggerPresetImport">
                                        <div class="intro-icon">
                                            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
                                        </div>
                                        <div class="intro-text">
                                            <h3>{{ t('onboarding_btn_import_preset') }}</h3>
                                            <p>JSON</p>
                                        </div>
                                    </div>
                                </div>
                            </div>

                            <!-- Data Import Slide -->
                            <div v-if="slides[currentSlide].type === 'data_import'" class="intro-blocks-container" style="margin-top: 24px;">
                                <div class="intro-block clickable" @click="triggerRestore">
                                    <div class="intro-icon">
                                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
                                    </div>
                                    <div class="intro-text">
                                        <h3>{{ t('onboarding_btn_import_backup') }}</h3>
                                        <p>{{ t('menu_backups') }}</p>
                                    </div>
                                </div>
                            </div>

                        </div>
                    </Transition>
                </div>

                <div class="onboarding-footer">
                    <div class="onboarding-footer-gradient"></div>
                    <div class="controls">
                        <button class="btn-primary full-width" @click="next">
                            {{ mainButtonLabel }}
                        </button>
                        <button 
                            v-if="slides[currentSlide].type === 'notifications'" 
                            class="btn-secondary full-width" 
                            style="margin-top: 12px; width: 100%;" 
                            @click="skipNotifications"
                        >
                            {{ t('btn_later') || "Later" }}
                        </button>
                    </div>
                </div>
            </div>
        </div>
        <BackupSheet ref="backupSheet" :z-index="10000" />
    </div>
</template>

<style scoped>
.onboarding-overlay {
    position: fixed;
    inset: 0;
    z-index: 9999;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 20px;
    background: rgb(var(--ui-bg-rgb));
    overflow: hidden;
    font-family: -apple-system, BlinkMacSystemFont, Roboto, sans-serif;
}

.onboarding-card {
    width: min(1180px, 100%);
    height: min(820px, calc(100dvh - 40px));
    border-radius: 18px;
    background: rgba(var(--ui-bg-rgb), 0.96);
    border: 1px solid rgba(255, 255, 255, 0.08);
    box-shadow: 0 16px 40px rgba(0, 0, 0, 0.2);
    overflow: hidden;
}

.onboarding-card.keyboard-open {
    height: calc(100dvh - 20px);
}

.onboarding-shell {
    display: flex;
    flex-direction: column;
    height: 100%;
}

.onboarding-topbar {
    display: flex;
    align-items: center;
    min-height: 62px;
    padding: 20px 24px 0;
    padding-top: calc(20px + var(--sat));
    box-sizing: border-box;
}

.stories-nav {
    display: flex;
    align-items: center;
    gap: 8px;
    flex: 1;
    min-width: 0;
    transition: transform 0.28s ease, opacity 0.28s ease;
}

.story-bar {
    flex: 1;
    height: 5px;
    border-radius: 999px;
    background: rgba(255, 255, 255, 0.08);
    overflow: hidden;
}

.story-fill {
    width: 0;
    height: 100%;
    border-radius: inherit;
    background: linear-gradient(90deg, rgba(var(--vk-blue-rgb), 0.55), rgba(var(--vk-blue-rgb), 1));
    transition: width 0.3s ease;
}

.story-bar.active .story-fill,
.story-bar.passed .story-fill {
    width: 100%;
}

.nav-back-btn {
    width: 0;
    height: 42px;
    margin-right: 0;
    padding: 0;
    opacity: 0;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 14px;
    background: rgba(255, 255, 255, 0.04);
    color: var(--text-primary, #fff);
    cursor: pointer;
    overflow: hidden;
    pointer-events: none;
    transition: width 0.28s ease, opacity 0.22s ease, transform 0.2s ease, background-color 0.2s ease, margin-right 0.28s ease;
}

.nav-back-btn :deep(svg) {
    width: 22px !important;
    height: 22px !important;
    fill: currentColor !important;
}

.nav-back-btn:active {
    transform: scale(0.96);
}

.nav-back-btn.is-visible {
    width: 42px;
    margin-right: 16px;
    opacity: 1;
    pointer-events: auto;
}

.slides-container {
    flex: 1;
    min-height: 0;
    overflow: auto;
    overflow-x: hidden;
    padding: 18px 24px 24px;
    padding-bottom: calc(24px + var(--sab));
}

.wizard-layout {
    display: grid;
    grid-template-columns: minmax(280px, 0.95fr) minmax(0, 1.15fr);
    gap: 28px;
    min-height: 100%;
    overflow-x: hidden;
}

.wizard-visual {
    position: relative;
    display: flex;
    align-items: center;
    justify-content: center;
    min-height: 520px;
    border-radius: 16px;
    overflow: hidden;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.06);
}

.visual-stage {
    position: relative;
    width: 100%;
    height: 100%;
    min-height: inherit;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 40px;
}

.visual-stage.visual-persona {
    padding: 0;
}

.icon-wrapper {
    position: relative;
    width: 136px;
    height: 136px;
    padding: 32px;
    border-radius: 24px;
    color: var(--vk-blue, #7996ce);
    background: rgba(var(--vk-blue-rgb), 0.1);
}

.persona-hero {
    position: relative;
    width: 100%;
    height: 100%;
    min-height: inherit;
    border-radius: 0;
    overflow: hidden;
    cursor: pointer;
    background: rgba(255, 255, 255, 0.06);
}

.persona-hero-image {
    width: 100%;
    height: 100%;
    object-fit: cover;
}

.persona-hero-placeholder {
    width: 100%;
    height: 100%;
    display: flex;
    align-items: center;
    justify-content: center;
    background: linear-gradient(135deg, #66ccff 0%, #7996ce 100%);
    color: #fff;
    font-size: 7rem;
    font-weight: 800;
}

.persona-hero-hint {
    position: absolute;
    inset: auto 0 0 0;
    padding: 18px;
    font-size: 14px;
    text-align: center;
    color: rgba(255, 255, 255, 0.92);
    background: linear-gradient(to top, rgba(0, 0, 0, 0.5), transparent);
}

.hint-mobile {
    display: none;
}

.wizard-content {
    min-width: 0;
    display: flex;
    flex-direction: column;
    padding: 20px 8px 8px 0;
}

.content-header {
    margin-bottom: 22px;
}

.title {
    margin: 0;
    color: #fff;
    font-size: clamp(28px, 4vw, 42px);
    line-height: 1.12;
    font-weight: 800;
    white-space: pre-line;
}

.description {
    margin: 12px 0 0;
    max-width: 640px;
    color: var(--text-gray);
    font-size: 16px;
    line-height: 1.6;
    white-space: pre-line;
}

.content-body {
    flex: 1;
    min-height: 0;
    display: flex;
    flex-direction: column;
    gap: 18px;
}

.intro-blocks-container,
.setup-form-container,
.preset-selector-list {
    width: 100%;
}

.intro-blocks-container,
.ps-list {
    display: flex;
    flex-direction: column;
    gap: 12px;
}

.intro-block {
    display: flex;
    align-items: flex-start;
    gap: 14px;
    padding: 16px 18px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: 14px;
    text-align: left;
}

.intro-block.clickable {
    cursor: pointer;
    transition: transform 0.14s ease, background-color 0.2s ease;
}

.intro-block.clickable:active {
    transform: scale(0.985);
    background: rgba(255, 255, 255, 0.07);
}

.intro-icon {
    width: 44px;
    height: 44px;
    flex-shrink: 0;
    color: var(--vk-blue);
}

.intro-text h3 {
    margin: 0 0 4px;
    color: #fff;
    font-size: 18px;
    font-weight: 700;
}

.intro-text p {
    margin: 0;
    color: var(--text-gray);
    font-size: 14px;
    line-height: 1.55;
}

.setup-panel {
    width: 100%;
    margin: 0;
    overflow: hidden;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: 14px;
}

.model-input-wrap {
    position: relative;
}

.model-input {
    width: 100%;
    padding-right: 44px;
}

.model-selector-btn {
    position: absolute;
    top: 0;
    right: 0;
    bottom: 0;
    width: 44px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    color: #818c99;
}

.model-selector-btn svg {
    width: 24px;
    height: 24px;
    fill: currentColor;
}

.api-status-badge {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    cursor: pointer;
    color: var(--text-gray);
}

.status-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.25);
}

.status-dot.connecting {
    background: #e3b341;
}

.status-dot.connected {
    background: #3fb950;
}

.status-dot.failed {
    background: #f85149;
}

.status-text {
    font-size: 13px;
}

.hint-line {
    margin: 4px 2px 2px;
    color: var(--text-gray);
    opacity: 0.9;
    font-size: 13px;
    line-height: 1.5;
}

.onboarding-footer {
    margin-top: auto;
    padding-top: 24px;
}

.controls {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 12px;
}

.btn-primary {
    min-width: 180px;
    padding: 15px 28px;
    border: none;
    border-radius: 12px;
    background: rgba(var(--vk-blue-rgb), 0.92);
    color: #fff;
    font-size: 16px;
    font-weight: 700;
    cursor: pointer;
    transition: transform 0.2s ease, filter 0.2s ease;
}

.btn-primary:active {
    transform: scale(0.98);
}

.btn-secondary {
    min-width: 180px;
    padding: 13px 24px;
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 12px;
    background: rgba(255, 255, 255, 0.04);
    color: #fff;
    font-size: 15px;
    font-weight: 600;
    cursor: pointer;
}

.slide-fade-enter-active,
.slide-fade-leave-active {
    transition: all 0.32s cubic-bezier(0.16, 1, 0.3, 1);
}

.slide-fade-enter-from {
    opacity: 0;
    transform: translateX(28px);
}

.slide-fade-leave-to {
    opacity: 0;
    transform: translateX(-28px);
}

.status-fade-enter-active,
.status-fade-leave-active {
    transition: opacity 0.2s ease, transform 0.2s ease;
}

.status-fade-enter-from,
.status-fade-leave-to {
    opacity: 0;
    transform: translateY(4px);
}

.ps-card {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 10px 14px;
    border-radius: 14px;
    position: relative;
    overflow: hidden;
    text-align: left;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.07);
    background-size: cover;
    background-position: center top;
}

.ps-card.ps-has-bg {
    min-height: 120px;
    align-items: flex-end;
}

.ps-card-overlay {
    position: absolute;
    inset: 0;
    background: linear-gradient(to top, rgba(0, 0, 0, 0.82), rgba(0, 0, 0, 0.18));
    z-index: 1;
}

.ps-card > *:not(.ps-card-overlay) {
    position: relative;
    z-index: 2;
}

.ps-card-icon {
    width: 44px;
    height: 44px;
    border-radius: 14px;
    background: rgba(var(--vk-blue-rgb), 0.14);
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--vk-blue);
    flex-shrink: 0;
}

.ps-card-icon svg {
    width: 24px;
    height: 24px;
    fill: currentColor;
}

.ps-card-info {
    min-width: 0;
}

.ps-card-name {
    margin-bottom: 2px;
    color: #fff;
    font-size: 16px;
    font-weight: 700;
}

.ps-card-name.ps-with-bg {
    text-shadow: 0 1px 4px rgba(0, 0, 0, 0.9);
}

.ps-card-meta {
    display: flex;
    flex-direction: column;
    gap: 2px;
}

.ps-author-line {
    font-size: 13px;
    font-weight: 600;
    color: rgba(255, 255, 255, 0.9);
}

.ps-desc-line {
    font-size: 12px;
    line-height: 1.3;
    color: rgba(255, 255, 255, 0.72);
}

.ps-card-meta.ps-with-bg .ps-author-line,
.ps-card-meta.ps-with-bg .ps-desc-line {
    text-shadow: 0 1px 2px rgba(0, 0, 0, 0.9);
}

@media (max-width: 900px) {
    .onboarding-overlay {
        padding: 0;
    }

    .onboarding-card {
        width: 100%;
        height: 100%;
        border-radius: 0;
    }

    .wizard-layout {
        grid-template-columns: 1fr;
        gap: 18px;
    }

    .wizard-visual {
        min-height: 260px;
    }

    .visual-stage {
        min-height: 260px;
        padding: 24px;
    }

    .visual-stage.visual-persona {
        padding: 0;
    }

    .wizard-content {
        padding: 0 0 8px;
    }

    .hint-desktop {
        display: none;
    }

    .hint-mobile {
        display: inline;
    }

    .controls {
        align-items: stretch;
    }

    .btn-primary,
    .btn-secondary {
        width: 100%;
        min-width: 0;
    }
}

/* Mobile Layout Styles */
.onboarding-card:not(.desktop-layout) {
    width: 100%;
    height: 100%;
    background: rgba(0, 0, 0, 0.2);
    backdrop-filter: blur(50px);
    -webkit-backdrop-filter: blur(50px);
    padding: 0;
    display: flex;
    flex-direction: column;
    border-radius: 0;
    border: none;
}

.mobile-shell {
    display: flex;
    flex-direction: column;
    height: 100%;
}

.onboarding-card:not(.desktop-layout) .onboarding-header {
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    z-index: 10;
    pointer-events: none;
}

.onboarding-card:not(.desktop-layout) .onboarding-header > * {
    pointer-events: auto;
}

.onboarding-card:not(.desktop-layout) .onboarding-header-gradient {
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    height: calc(84px + var(--sat));
    background: linear-gradient(to bottom, rgba(0,0,0,0.4), transparent);
    z-index: -1;
    pointer-events: none;
}

.onboarding-card:not(.desktop-layout) .onboarding-footer {
    position: absolute;
    bottom: 0;
    left: 0;
    right: 0;
    z-index: 10;
    pointer-events: none;
}

.onboarding-card:not(.desktop-layout) .onboarding-footer > * {
    pointer-events: auto;
}

.onboarding-card:not(.desktop-layout) .onboarding-footer-gradient {
    position: absolute;
    bottom: 0;
    left: 0;
    right: 0;
    height: calc(120px + var(--sab));
    background: linear-gradient(to top, rgba(0,0,0,0.5), transparent);
    z-index: -1;
    pointer-events: none;
}

.onboarding-card:not(.desktop-layout) .stories-nav {
    position: relative;
    top: 0;
    left: 0;
    width: 100%;
    padding: 16px 20px;
    padding-top: calc(16px + var(--sat));
    display: flex;
    gap: 6px;
    z-index: 10;
    box-sizing: border-box;
}

.onboarding-card:not(.desktop-layout) .story-bar {
    flex: 1;
    height: 4px;
    background: rgba(128, 128, 128, 0.2);
    border-radius: 2px;
    overflow: hidden;
}

.onboarding-card:not(.desktop-layout) .story-fill {
    height: 100%;
    background: var(--vk-blue, #7996ce);
    width: 0%;
    transition: width 0.3s ease;
}

.onboarding-card:not(.desktop-layout) .story-bar.active .story-fill,
.onboarding-card:not(.desktop-layout) .story-bar.passed .story-fill {
    width: 100%;
}

.onboarding-card:not(.desktop-layout) .nav-back-btn {
    position: absolute;
    top: calc(36px + var(--sat));
    left: 12px;
    z-index: 20;
    width: 40px;
    height: 40px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    color: var(--accent-color, var(--vk-blue));
    border-radius: 50%;
    background-color: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 20px));
    -webkit-backdrop-filter: blur(var(--element-blur, 20px));
    border: 1px solid rgba(255, 255, 255, 0.1);
    box-shadow: 0 4px 15px rgba(0, 0, 0, 0.3);
    transition: all 0.2s ease;
}

.onboarding-card:not(.desktop-layout) .nav-back-btn :deep(svg) {
    width: 20px !important;
    height: 20px !important;
    fill: currentColor !important;
}

.onboarding-card:not(.desktop-layout) .nav-back-btn:active {
    transform: scale(0.9);
    opacity: 0.8;
}

.onboarding-card:not(.desktop-layout) .slides-container {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    width: 100%;
    max-width: 500px;
    margin: 0 auto;
    overflow-y: auto;
    overflow-x: hidden;
    min-height: 0;
    padding: 24px;
    padding-top: calc(84px + var(--sat));
    padding-bottom: calc(100px + var(--sab));
    box-sizing: border-box;
}

.onboarding-card:not(.desktop-layout) .slide {
    text-align: center;
    width: 100%;
    display: flex;
    flex-direction: column;
    align-items: center;
    margin: auto 0;
    flex-shrink: 0;
}

.onboarding-card:not(.desktop-layout) .slide.welcome-align {
    margin: 0;
}

.onboarding-card:not(.desktop-layout) .welcome-slide {
    width: 100%;
    display: flex;
    flex-direction: column;
    align-items: stretch;
}

.onboarding-card:not(.desktop-layout) .welcome-title {
    font-size: 32px;
    font-weight: 800;
    color: #fff;
    line-height: 1.2;
    white-space: pre-line;
    text-align: left;
    margin-top: 0;
    margin-bottom: 16px;
}

.onboarding-card:not(.desktop-layout) .icon-wrapper {
    width: 100px;
    height: 100px;
    margin: 0 auto 24px;
    color: var(--vk-blue, #7996ce);
    background: rgba(var(--vk-blue-rgb), 0.1);
    border-radius: 50%;
    padding: 24px;
    box-sizing: border-box;
}

.onboarding-card:not(.desktop-layout) .title {
    font-size: 28px;
    font-weight: 800;
    margin-bottom: 12px;
    color: #fff;
    line-height: 1.3;
    padding: 4px 0;
    white-space: pre-line;
}

.onboarding-card:not(.desktop-layout) .description {
    font-size: 16px;
    line-height: 1.5;
    color: var(--text-gray);
    white-space: pre-line;
    max-width: 100%;
    padding: 0 20px;
    margin: 0 auto;
    box-sizing: border-box;
}

.onboarding-card:not(.desktop-layout) .intro-blocks-container {
    width: 100%;
    display: flex;
    flex-direction: column;
    gap: 12px;
}

.onboarding-card:not(.desktop-layout) .intro-block {
    background: rgba(128, 128, 128, 0.08);
    border-radius: 20px;
    padding: 16px;
    width: 100%;
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    text-align: left;
    gap: 8px;
}

.onboarding-card:not(.desktop-layout) .intro-block.clickable {
    cursor: pointer;
    transition: background-color 0.2s, transform 0.1s;
}

.onboarding-card:not(.desktop-layout) .intro-block.clickable:active {
    background: rgba(128, 128, 128, 0.15);
    transform: scale(0.98);
}

.onboarding-card:not(.desktop-layout) .intro-icon {
    width: 48px;
    height: 48px;
    color: var(--vk-blue);
}

.onboarding-card:not(.desktop-layout) .intro-text h3 {
    font-size: 20px;
    font-weight: 700;
    margin-bottom: 4px;
    color: #fff;
}

.onboarding-card:not(.desktop-layout) .intro-text p {
    font-size: 15px;
    line-height: 1.5;
    color: var(--text-gray);
}

.onboarding-card:not(.desktop-layout) .setup-form-container {
    width: 100%;
    margin-top: 24px;
    display: flex;
    flex-direction: column;
    gap: 16px;
}

.onboarding-card:not(.desktop-layout) .controls {
    width: 100%;
    max-width: 500px;
    margin: 0 auto;
    padding: 24px;
    padding-bottom: calc(24px + var(--sab));
    flex-shrink: 0;
    box-sizing: border-box;
}

.onboarding-card:not(.desktop-layout) .btn-primary {
    background-color: var(--vk-blue, #7996ce);
    color: white;
    border: none;
    border-radius: 20px;
    padding: 16px 32px;
    font-size: 17px;
    font-weight: 600;
    cursor: pointer;
    transition: transform 0.2s;
    width: 100%;
    box-shadow: none;
}

.onboarding-card:not(.desktop-layout) .btn-primary:active {
    transform: scale(0.96);
}

.onboarding-card:not(.desktop-layout) .btn-secondary {
    background-color: rgba(128, 128, 128, 0.1);
    color: var(--text-black);
    border: none;
    border-radius: 12px;
    padding: 12px 24px;
    font-size: 15px;
    font-weight: 500;
    cursor: pointer;
    width: 100%;
}

.onboarding-card:not(.desktop-layout) .avatar-card {
    display: flex;
    flex-direction: column;
    cursor: pointer;
}

.onboarding-card:not(.desktop-layout) .avatar-wrapper {
    width: 100%;
    aspect-ratio: 1 / 1;
    max-height: 300px;
    position: relative;
    background-color: var(--bg-gray, rgba(128,128,128,0.1));
    border-radius: 20px;
    overflow: hidden;
}

.onboarding-card:not(.desktop-layout) .avatar-img {
    width: 100%;
    height: 100%;
    object-fit: cover;
}

.onboarding-card:not(.desktop-layout) .avatar-placeholder {
    width: 100%;
    height: 100%;
    background: linear-gradient(135deg, #66ccff 0%, #7996ce 100%);
    display: flex;
    align-items: center;
    justify-content: center;
    color: white;
    font-weight: bold;
    font-size: 6em;
}

.onboarding-card:not(.desktop-layout) .avatar-overlay-hint {
    position: absolute;
    bottom: 0;
    left: 0;
    width: 100%;
    text-align: center;
    color: rgba(255, 255, 255, 0.9);
    font-size: 14px;
    text-shadow: 0 2px 4px rgba(0,0,0,0.5);
    pointer-events: none;
    z-index: 2;
    background: linear-gradient(to top, rgba(0,0,0,0.5), transparent);
    padding-bottom: 20px;
    padding-top: 20px;
}

.onboarding-card:not(.desktop-layout) .avatar-header-overlay {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    padding: 14px 16px 30px 16px;
    font-size: 14px;
    font-weight: 700;
    text-transform: uppercase;
    color: rgba(255, 255, 255, 0.9);
    letter-spacing: 0.5px;
    z-index: 2;
    background: linear-gradient(to bottom, rgba(0,0,0,0.5), transparent);
    text-shadow: 0 2px 4px rgba(0,0,0,0.5);
    pointer-events: none;
}
</style>
