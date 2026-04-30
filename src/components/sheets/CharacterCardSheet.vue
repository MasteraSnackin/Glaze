<script setup>
import { ref, computed, watch, getCurrentInstance } from 'vue';
import SheetView from '@/components/ui/SheetView.vue';
import FabButton from '@/components/ui/FabButton.vue';
import { formatText } from '@/utils/textFormatter.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { db, markSyncDeletedEntry } from '@/utils/db.js';
import { exportCharacterAsV2Json, exportCharacterAsV2Png } from '@/utils/characterIO.js';
import { useSessionSheet } from '@/composables/character/useSessionSheet.js';
import { useCharacterGallery } from '@/composables/character/useCharacterGallery.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { publishAppEvent } from '@/core/events/eventHub.js';

const props = defineProps({
    visible: Boolean,
    item: Object,
    charData: Object,
    avatarUrl: String,
    importEnabled: {
        type: Boolean,
        default: false
    }
});

const emit = defineEmits(['update:visible', 'import']);

const sheetRef = ref(null);
const localVisible = ref(false);
const localItem = ref(null);
const localCharData = ref(null);
const localAvatarUrl = ref(null);
const localImportEnabled = ref(false);
const instance = getCurrentInstance();

const isControlled = computed(() => {
    const rawProps = instance?.vnode.props || {};
    return Object.prototype.hasOwnProperty.call(rawProps, 'visible');
});
const isOpen = computed(() => (isControlled.value ? props.visible : localVisible.value));

const collapsedSections = ref({});
function toggleSection(key) {
    const curr = isSectionCollapsed(key);
    collapsedSections.value[key] = !curr;
}
function isSectionCollapsed(key) {
    return collapsedSections.value[key] !== false; // collapsed by default
}
const currentItem = computed(() => (isControlled.value ? props.item : localItem.value));
const currentCharData = computed(() => (isControlled.value ? props.charData : localCharData.value));
const currentAvatarUrl = computed(() => {
    const directUrl = isControlled.value ? props.avatarUrl : localAvatarUrl.value;
    if (directUrl) return resolveAvatarUrl(directUrl);

    const char = currentCharData.value;
    return resolveAvatarUrl(char?.avatar || char?.thumbnail || currentItem.value?.avatarUrl);
});
const canImport = computed(() => (isControlled.value ? props.importEnabled : localImportEnabled.value));

watch(isOpen, (visible) => {
    if (visible) sheetRef.value?.open();
    else sheetRef.value?.close();
}, { immediate: true });

function resolveAvatarUrl(value) {
    if (!value || typeof value !== 'string') return '';
    if (value.startsWith('http') || value.startsWith('blob:') || value.startsWith('data:') || value.startsWith('/')) {
        return value;
    }
    return `/characters/${value}`;
}

function formatSectionText(value) {
    if (!value) return '';
    return formatText(value);
}

const infoDescriptionHtml = computed(() => {
    const char = currentCharData.value || {};
    return formatSectionText(char.creator_notes);
});

const promptSections = computed(() => {
    const char = currentCharData.value || {};
    return [
        { key: 'description', label: 'Description', html: formatSectionText(char.description || char.desc) },
        { key: 'personality', label: 'Personality', html: formatSectionText(char.personality) },
        { key: 'scenario', label: 'Scenario', html: formatSectionText(char.scenario) },
        { key: 'mesExample', label: 'Example dialogue', html: formatSectionText(char.mes_example) },
        { key: 'systemPrompt', label: 'System prompt', html: formatSectionText(char.system_prompt) },
        { key: 'postHistoryInstructions', label: 'Post-history instructions', html: formatSectionText(char.post_history_instructions) }
    ].filter(section => section.html);
});

const allFirstMessages = computed(() => {
    const char = currentCharData.value || {};
    const msgs = [];
    if (char.first_mes) msgs.push(char.first_mes);
    if (Array.isArray(char.alternate_greetings)) {
        char.alternate_greetings.forEach(g => {
            if (g) msgs.push(g);
        });
    }
    return msgs;
});

const activeTab = ref('info');

const {
    galleryImages,
    isLocalCharacter,
    openGalleryImage,
    triggerGalleryImageUpload,
    confirmDeleteGalleryImage
} = useCharacterGallery({ currentCharData, isControlled, localCharData });

const sheetTabs = computed(() => {
    const tabs = [
        { id: 'info', label: getTranslated('tab_info', 'Information') || 'Information' },
        { id: 'prompts', label: getTranslated('tab_prompts', 'Prompts') || 'Prompts' }
    ];
    if (galleryImages.value.length > 0 || isLocalCharacter.value) {
        tabs.push({ id: 'gallery', label: getTranslated('tab_gallery', 'Gallery') || 'Gallery' });
    }
    return tabs;
});

const tabSliderOffset = computed(() => {
    const idx = sheetTabs.value.findIndex(t => t.id === activeTab.value);
    return idx >= 0 ? idx * 100 : 0;
});

const allTags = computed(() => {
    const tags = currentCharData.value?.tags;
    return Array.isArray(tags) ? tags.filter(Boolean) : [];
});

const creatorProfileUrl = computed(() => {
    const char = currentCharData.value || {};
    return char.creator_id ? `https://janitorai.com/profiles/${char.creator_id}` : '';
});
const canOpenChat = computed(() => isLocalCharacter.value);

const menuIcon = '<svg viewBox="0 0 24 24"><path d="M12 8a2 2 0 1 0 0-4 2 2 0 0 0 0 4zm0 8a2 2 0 1 0 0-4 2 2 0 0 0 0 4zm0 8a2 2 0 1 0 0-4 2 2 0 0 0 0 4z"/></svg>';
const plusIcon = '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>';
const exportIcon = '<svg viewBox="0 0 24 24"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>';
const pngIcon = '<svg viewBox="0 0 24 24"><path d="M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z"/></svg>';
const editIcon = '<svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>';
const deleteIcon = '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>';

function getTranslated(key, fallback) {
    return translations[currentLang.value]?.[key] || fallback;
}

function formatNum(n) {
    if (!n) return '0';
    if (n >= 1000000) return (n / 1000000).toFixed(1) + 'kk';
    if (n >= 1000) return (n / 1000).toFixed(1) + 'k';
    return String(n);
}

function open(charOrOptions, maybeOptions = {}) {
    const options = maybeOptions && typeof maybeOptions === 'object' ? maybeOptions : {};
    const char = charOrOptions?.charData ? charOrOptions.charData : charOrOptions;
    const item = charOrOptions?.item || options.item || null;

    localCharData.value = char || null;
    localItem.value = item;
    localAvatarUrl.value = charOrOptions?.avatarUrl || options.avatarUrl || null;
    localImportEnabled.value = !!(charOrOptions?.importEnabled ?? options.importEnabled);
    activeTab.value = 'info';
    localVisible.value = true;
}

function close() {
    localVisible.value = false;
    emit('update:visible', false);
}

function handleImport() {
    emit('import');
}

async function openCharacterEditor() {
    const char = currentCharData.value;
    if (!char?.id) return;
    const characters = await db.getAll('characters');
    const index = characters.findIndex(item => String(item.id) === String(char.id));
    if (index !== -1) {
        closeBottomSheet();
        close();
        publishAppEvent(APP_EVENTS.nav.openCharacterEditor, { index });
    }
}

function openExportSheet(char) {
    showBottomSheet({
        title: `${getTranslated('action_export_st', 'Export')}: ${char.name || ''}`,
        items: [
            {
                label: getTranslated('label_export_png', 'PNG (Character Card)'),
                icon: pngIcon,
                onClick: () => {
                    exportCharacterAsV2Png(char);
                    closeBottomSheet();
                }
            },
            {
                label: getTranslated('label_export_json', 'JSON (SillyTavern V2)'),
                icon: exportIcon,
                onClick: () => {
                    exportCharacterAsV2Json(char);
                    closeBottomSheet();
                }
            }
        ]
    });
}

async function toggleFavorite() {
    const char = currentCharData.value;
    if (!char?.id) return;
    const updated = { ...char, fav: !char.fav };
    await db.saveCharacter(updated, -1);
    publishAppEvent(APP_EVENTS.domain.character.updated, { character: updated });
    if (isControlled.value) {
        emit('update:visible', true);
    } else {
        localCharData.value = updated;
    }
    closeBottomSheet();
}

async function deleteCharacter() {
    const char = currentCharData.value;
    if (!char?.id) return;
    await db.deleteCharacter(char.id);
    await markSyncDeletedEntry('character', char.id);
    closeBottomSheet();
    close();
}

function openDeleteConfirm() {
    showBottomSheet({
        title: getTranslated('confirm_delete_character', 'Delete character?'),
        items: [
            {
                label: getTranslated('btn_yes', 'Yes'),
                icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                iconColor: '#ff4444',
                isDestructive: true,
                onClick: deleteCharacter
            },
            {
                label: getTranslated('btn_no', 'No'),
                icon: '<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>',
                onClick: () => closeBottomSheet()
            }
        ]
    });
}

function openActionsMenu() {
    const char = currentCharData.value;
    if (!char?.id) return;

    const isFav = char.fav === true;
    const favLabel = isFav ? getTranslated('action_remove_fav', 'Remove from Favorites') : getTranslated('action_add_fav', 'Add to Favorites');
    const favIcon = isFav
        ? '<svg viewBox="0 0 24 24"><path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/><line x1="4" y1="4" x2="20" y2="20" stroke="#ff4444" stroke-width="2" /></svg>'
        : '<svg viewBox="0 0 24 24"><path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/></svg>';

    showBottomSheet({
        title: char.name,
        items: [
            {
                label: getTranslated('action_edit', 'Edit'),
                icon: editIcon,
                onClick: openCharacterEditor
            },
            {
                label: getTranslated('action_export_st', 'Export'),
                icon: exportIcon,
                onClick: () => {
                    closeBottomSheet();
                    setTimeout(() => openExportSheet(char), 300);
                }
            },
            {
                label: favLabel,
                icon: favIcon,
                iconColor: isFav ? '#ff4444' : 'var(--text-gray)',
                onClick: toggleFavorite
            },
            {
                label: getTranslated('action_delete', 'Delete'),
                icon: deleteIcon,
                iconColor: '#ff4444',
                isDestructive: true,
                onClick: () => {
                    closeBottomSheet();
                    setTimeout(() => openDeleteConfirm(), 300);
                }
            }
        ]
    });
}

const { openSessionsSheet } = useSessionSheet({
    openChat: ({ charId, sessionId }) => {
        closeBottomSheet();
        close();
        publishAppEvent(APP_EVENTS.nav.openChat, { charId, sessionId });
    }
});

defineExpose({ open, close });

function openHeroImage() {
    const url = currentAvatarUrl.value;
    if (!url) return;
    publishAppEvent(APP_EVENTS.nav.openImageViewer, { src: url });
}
</script>

<template>
    <SheetView ref="sheetRef" :showBack="true" @back="close" @close="close">
        <template #header-right>
            <button v-if="isLocalCharacter" class="header-menu-btn" @click="openActionsMenu" v-html="menuIcon"></button>
        </template>
        <div v-if="currentCharData" class="char-sheet">
            <div class="char-hero">
                <Transition name="sheet-fade" mode="out-in">
                    <img
                        v-if="currentAvatarUrl"
                        :key="currentAvatarUrl"
                        :src="currentAvatarUrl"
                        class="hero-img"
                        :alt="currentCharData.name"
                        @click="openHeroImage"
                    />
                    <div v-else :key="'placeholder-'+(currentCharData.id || currentCharData.name)" class="hero-placeholder">
                        {{ currentCharData.name?.[0]?.toUpperCase() || '?' }}
                    </div>
                </Transition>
                <div class="hero-gradient"></div>
                <Transition name="sheet-fade" mode="out-in">
                    <div class="hero-overlay" :key="currentCharData.id || currentCharData.name">
                        <div class="hero-badges"></div>
                        <div class="hero-tokens" v-if="currentItem?.tokens">
                            {{ formatNum(currentItem.tokens) }} tokens
                        </div>
                        <div class="hero-name">{{ currentCharData.name }}</div>
                        <div v-if="currentCharData.creator" class="hero-creator">
                            <a
                                v-if="creatorProfileUrl"
                                :href="creatorProfileUrl"
                                target="_blank"
                                class="creator-link"
                            >@{{ currentCharData.creator }}</a>
                            <span v-else>@{{ currentCharData.creator }}</span>
                        </div>
                    </div>
                </Transition>

                <button v-if="canImport" class="import-fab" @click="handleImport" title="Import Character">
                    <svg viewBox="0 0 24 24"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"/></svg>
                </button>
            </div>

            <div class="char-sheet-details">
                <div class="char-stats" v-if="currentItem?.stats?.chat || currentItem?.stats?.message">
                    <div class="stat-pill">
                        <svg viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2z"/></svg>
                        <span>{{ formatNum(currentItem.stats.chat) }}</span>
                        <span class="stat-sep" v-if="currentItem.stats.chat && currentItem.stats.message">|</span>
                        <span v-if="currentItem.stats.message">{{ formatNum(currentItem.stats.message) }}</span>
                    </div>
                </div>

                <div class="tabs-row">
                    <div class="top-tabs-container" :class="'tabs-' + sheetTabs.length">
                        <div class="tab-slider" :style="{ transform: `translateX(${tabSliderOffset}%)` }"></div>
                        <div v-for="tab in sheetTabs" :key="tab.id" class="top-tab" :class="{ active: activeTab === tab.id }" @click="activeTab = tab.id">
                            <svg v-if="tab.id === 'info'" class="tab-icon" viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-6h2v6zm0-8h-2V7h2v2z"/></svg>
                            <svg v-else-if="tab.id === 'prompts'" class="tab-icon" viewBox="0 0 24 24"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>
                            <svg v-else-if="tab.id === 'gallery'" class="tab-icon" viewBox="0 0 24 24"><path d="M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z"/></svg>
                            <span>{{ tab.label }}</span>
                        </div>
                    </div>
                </div>

                <Transition name="sheet-fade-static" mode="out-in">
                    <div v-if="activeTab === 'info'" :key="'info-' + (currentCharData.id || currentCharData.name)" class="tab-content">
                        <div class="char-tags" v-if="allTags.length">
                            <span
                                v-for="tag in allTags"
                                :key="tag"
                                class="char-tag"
                                :class="{
                                    'char-tag-custom': tag.startsWith('#'),
                                    'nsfw-indicator': tag === 'NSFW',
                                    'sfw-indicator': tag === 'SFW'
                                }"
                            >{{ tag }}</span>
                        </div>

                        <div class="char-desc-section" v-if="infoDescriptionHtml">
                            <div class="section-label">Creator Notes</div>
                            <div class="char-desc" v-html="infoDescriptionHtml"></div>
                        </div>
                    </div><!-- /info tab -->
                    <div v-else-if="activeTab === 'prompts'" :key="'prompts-' + (currentCharData.id || currentCharData.name)" class="tab-content prompts-tab-content">
                        <div class="menu-group char-desc-group" v-for="section in promptSections" :key="section.key">
                            <div class="settings-item">
                                <div class="label-row desc-header" @click="toggleSection(section.key)">
                                    <label>{{ section.label }}</label>
                                    <div class="expand-btn">
                                        <svg viewBox="0 0 24 24" class="chevron" :class="{ 'rotated': isSectionCollapsed(section.key) }">
                                            <path d="M12 15.5l-6-6 1.41-1.41L12 12.67l4.59-4.58L18 9.5z"/>
                                        </svg>
                                    </div>
                                </div>
                                <div class="char-desc-body" :class="{ 'collapsed': isSectionCollapsed(section.key) }">
                                    <div class="char-desc" v-html="section.html"></div>
                                </div>
                            </div>
                        </div>

                        <div class="menu-group char-desc-group" v-if="allFirstMessages.length">
                            <div class="settings-item">
                                <div class="label-row desc-header" @click="toggleSection('first-messages')">
                                    <label>First Messages ({{ allFirstMessages.length }})</label>
                                    <div class="expand-btn">
                                        <svg viewBox="0 0 24 24" class="chevron" :class="{ 'rotated': isSectionCollapsed('first-messages') }">
                                            <path d="M12 15.5l-6-6 1.41-1.41L12 12.67l4.59-4.58L18 9.5z"/>
                                        </svg>
                                    </div>
                                </div>
                                <div class="char-desc-body" :class="{ 'collapsed': isSectionCollapsed('first-messages') }">
                                    <div class="alt-greetings">
                                        <div v-for="(greeting, index) in allFirstMessages" :key="index" class="alt-greeting">
                                            <div class="alt-greeting-index">#{{ index + 1 }}</div>
                                            <div class="char-desc" v-html="formatSectionText(greeting)"></div>
                                        </div>
                                    </div>
                                </div>
                            </div>
                        </div>
                    </div><!-- /prompts tab -->
                    <div v-else-if="activeTab === 'gallery'" :key="'gallery-' + (currentCharData.id || currentCharData.name)" class="tab-content gallery-tab-content">
                        <div class="gallery-grid" v-if="galleryImages.length > 0">
                            <div v-for="img in galleryImages" :key="img.id" class="gallery-item" @click="openGalleryImage(img)">
                                <img :src="img.thumbnail || img.src" class="gallery-thumb" loading="lazy" />
                                <button v-if="isLocalCharacter" class="gallery-delete-btn" @click.stop="confirmDeleteGalleryImage(img)" v-html="deleteIcon"></button>
                            </div>
                        </div>
                        <div v-if="galleryImages.length === 0" class="gallery-empty">
                            <svg viewBox="0 0 24 24" class="gallery-empty-icon"><path d="M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z"/></svg>
                            <span>{{ getTranslated('gallery_empty', 'No images in gallery') || 'No images in gallery' }}</span>
                        </div>
                        <button v-if="isLocalCharacter" class="gallery-add-btn" @click="triggerGalleryImageUpload">
                            <svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>
                            <span>{{ getTranslated('gallery_add', 'Add Images') || 'Add Images' }}</span>
                        </button>
                    </div><!-- /gallery tab -->
                </Transition>
            </div>
        </div> <!-- /char-sheet -->
        <template #floating>
            <div v-if="canOpenChat" class="chat-fab-wrap">
                <FabButton :text="getTranslated('btn_open_chat', 'Open Chat')" @click="openSessionsSheet(currentCharData)">
                    <template #icon>
                        <svg viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2z"/></svg>
                    </template>
                </FabButton>
            </div>
        </template>
    </SheetView>
</template>

<style scoped>
.sheet-fade-enter-active,
.sheet-fade-leave-active {
    transition: opacity 0.2s cubic-bezier(0.2, 0.8, 0.2, 1), transform 0.2s cubic-bezier(0.2, 0.8, 0.2, 1), filter 0.2s ease;
}
.sheet-fade-enter-from {
    opacity: 0;
    transform: translateY(8px) scale(0.98);
    filter: blur(4px);
}
.sheet-fade-leave-to {
    opacity: 0;
    transform: translateY(-8px) scale(0.98);
    filter: blur(4px);
}

.sheet-fade-static-enter-active,
.sheet-fade-static-leave-active {
    transition: opacity 0.2s cubic-bezier(0.2, 0.8, 0.2, 1), filter 0.2s ease;
}
.sheet-fade-static-enter-from,
.sheet-fade-static-leave-to {
    opacity: 0;
    filter: blur(4px);
}

.char-sheet {
    position: relative;
    display: flex;
    flex-direction: column;
    min-height: 100%;
    box-sizing: border-box;
    padding-bottom: calc(104px + var(--sab, 0px));
}

.char-desc-body {
    overflow: visible;
    max-height: none;
    -webkit-mask-image: none;
    mask-image: none;
    transition: max-height 0.4s cubic-bezier(0.2, 0.8, 0.2, 1), opacity 0.3s ease;
}

.char-desc-body.collapsed {
    overflow: hidden;
    max-height: 65px;
    -webkit-mask-image: linear-gradient(to bottom, black 35px, transparent 65px);
    mask-image: linear-gradient(to bottom, black 35px, transparent 65px);
    pointer-events: none;
}

.char-sheet-details {
    display: flex;
    flex-direction: column;
    padding-bottom: 80px;
}

.tab-content {
    display: flex;
    flex-direction: column;
    flex: 1;
}

.prompts-tab-content {
    padding-top: 0;
}

.tabs-row {
  display: flex;
  align-items: center;
  margin: 16px 16px 8px;
}


.char-desc-section {
    padding: 16px 16px 0;
    display: flex;
    flex-direction: column;
    gap: 6px;
}

.section-label {
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.07em;
    color: rgba(255, 255, 255, 0.35);
}

.menu-group {
    background: var(--bg-item, rgba(255, 255, 255, 0.05));
    border-radius: 16px;
    margin: 16px 16px 0;
    overflow: hidden;
    border: 1px solid var(--border-color, rgba(255, 255, 255, 0.05));
}

.settings-item {
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
}

.label-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    cursor: pointer;
    user-select: none;
}

.label-row label {
    margin-bottom: 0;
    font-weight: 600;
    font-size: 14px;
    letter-spacing: 0.05em;
    text-transform: uppercase;
    color: var(--vk-blue, #4080ff);
    cursor: pointer;
}

.expand-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--text-gray, rgba(255,255,255,0.5));
}

.expand-btn svg {
    width: 24px;
    height: 24px;
    fill: currentColor;
    transition: transform 0.3s cubic-bezier(0.2, 0.8, 0.2, 1);
}

.expand-btn svg.rotated {
    transform: rotate(180deg);
}

.header-menu-btn {
    width: 40px;
    height: 40px;
    border-radius: 50%;
    border: 1px solid rgba(255, 255, 255, 0.1);
    background-color: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 20px));
    -webkit-backdrop-filter: blur(var(--element-blur, 20px));
    box-shadow: 0 4px 15px rgba(0, 0, 0, 0.3);
    color: var(--accent-color, var(--vk-blue));
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    flex-shrink: 0;
    transition: all 0.2s ease;
}

.header-menu-btn :deep(svg) {
    width: 20px !important;
    height: 20px !important;
    fill: currentColor !important;
}

.header-menu-btn:active {
    transform: scale(0.94);
    opacity: 0.85;
}

.char-hero {
    position: relative;
    width: 100%;
    height: 310px;
    margin-top: -80px;
    overflow: hidden;
    flex-shrink: 0;
    background: rgba(255, 255, 255, 0.04);
}

.hero-img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    object-position: center top;
    display: block;
    cursor: zoom-in;
}

.hero-placeholder {
    width: 100%;
    height: 100%;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 64px;
    font-weight: 700;
    color: rgba(255, 255, 255, 0.4);
    background: rgba(var(--vk-blue-rgb, 64, 128, 255), 0.08);
}

.hero-gradient {
    position: absolute;
    inset: 0;
    background: linear-gradient(
        to top,
        rgba(0, 0, 0, 0.75) 0%,
        rgba(0, 0, 0, 0.2) 40%,
        transparent 65%
    );
    pointer-events: none;
}

.hero-overlay {
    position: absolute;
    bottom: 0;
    left: 0;
    right: 0;
    padding: 12px 16px 16px;
    display: flex;
    flex-direction: column;
    gap: 2px;
}

.hero-badges {
    display: flex;
    gap: 6px;
    margin-bottom: 4px;
}

.nsfw-badge,
.sfw-badge {
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 0.05em;
    padding: 2px 7px;
    border-radius: 6px;
    backdrop-filter: blur(4px);
    -webkit-backdrop-filter: blur(4px);
}

.nsfw-badge {
    background: rgba(255, 80, 80, 0.25);
    color: #ff6b6b;
    border: 1px solid rgba(255, 80, 80, 0.35);
}

.sfw-badge {
    background: rgba(76, 175, 80, 0.2);
    color: #7bd881;
    border: 1px solid rgba(76, 175, 80, 0.32);
}

.hero-tokens {
    font-size: 11px;
    font-weight: 700;
    color: rgba(255, 255, 255, 0.5);
    text-shadow: 0 1px 2px rgba(0, 0, 0, 0.8);
    text-transform: uppercase;
    letter-spacing: 0.02em;
}

.hero-name {
    font-size: 20px;
    font-weight: 700;
    color: #fff;
    text-shadow: 0 2px 6px rgba(0, 0, 0, 0.8);
    line-height: 1.2;
}

.hero-creator {
    font-size: 13px;
    color: rgba(255, 255, 255, 0.6);
    text-shadow: 0 1px 3px rgba(0, 0, 0, 0.8);
}

.creator-link {
    color: inherit;
    text-decoration: none;
    transition: color 0.15s;
}

@media (hover: hover) {
    .creator-link:hover {
        color: #fff;
        text-decoration: underline;
    }
}

.char-stats {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 14px 16px 0;
    flex-wrap: wrap;
}

.stat-pill {
    display: flex;
    align-items: center;
    gap: 5px;
    padding: 5px 10px;
    border-radius: 20px;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.09);
    font-size: 12px;
    font-weight: 600;
    color: rgba(255, 255, 255, 0.7);
}

.stat-pill svg {
    width: 13px;
    height: 13px;
    fill: currentColor;
    opacity: 0.75;
    flex-shrink: 0;
}

.stat-sep {
    margin: 0 2px;
    opacity: 0.3;
    font-weight: 400;
}

.char-tags {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    padding: 10px 16px 0;
}

.char-tag {
    font-size: 11px;
    padding: 3px 9px;
    border-radius: 10px;
    background: rgba(var(--vk-blue-rgb, 64, 128, 255), 0.12);
    color: var(--vk-blue, #4080ff);
    border: 1px solid rgba(var(--vk-blue-rgb, 64, 128, 255), 0.2);
    white-space: nowrap;
    font-weight: 600;
}

.nsfw-indicator {
    background: rgba(255, 68, 68, 0.2) !important;
    color: #ff4444 !important;
    border-color: rgba(255, 68, 68, 0.3) !important;
}

.sfw-indicator {
    background: rgba(76, 175, 80, 0.2) !important;
    color: #4caf50 !important;
    border-color: rgba(76, 175, 80, 0.3) !important;
}

.char-tag-custom {
    background: rgba(0, 255, 255, 0.1) !important;
    color: #00cccc !important;
    border-color: rgba(0, 255, 255, 0.2) !important;
}

.char-tag-custom:nth-child(3n) {
    background: rgba(255, 0, 255, 0.1) !important;
    color: #cc00cc !important;
    border-color: rgba(255, 0, 255, 0.2) !important;
}

.char-desc {
    font-size: 13.5px;
    line-height: 1.55;
    color: rgba(255, 255, 255, 0.75);
    word-break: break-word;
}

.char-desc :deep(p) { margin: 0 0 8px; }
.char-desc :deep(p:last-child) { margin-bottom: 0; }
.char-desc :deep(hr) { border: none; border-top: 1px solid rgba(255,255,255,0.1); margin: 12px 0; }
.char-desc :deep(strong) { color: rgba(255,255,255,0.95); }
.char-desc :deep(em) { color: rgba(255,255,255,0.85); }
.char-desc :deep(img) { max-width: 100%; border-radius: 8px; margin: 4px 0; }
.char-desc :deep(a) { color: var(--vk-blue, #4080ff); text-decoration: none; }

.alt-greetings {
    display: flex;
    flex-direction: column;
    gap: 10px;
}

.alt-greeting {
    padding: 10px 12px;
    border-radius: 14px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.06);
}

.alt-greeting-index {
    font-size: 11px;
    font-weight: 700;
    color: rgba(255, 255, 255, 0.4);
    margin-bottom: 6px;
}

.import-fab {
    position: absolute;
    bottom: 14px;
    right: 14px;
    width: 48px;
    height: 48px;
    border-radius: 50%;
    background: var(--vk-blue, #4080ff);
    color: #fff;
    border: none;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    box-shadow: 0 4px 16px rgba(0, 0, 0, 0.5);
    transition: transform 0.15s, opacity 0.15s;
    z-index: 2;
}

.import-fab svg {
    width: 22px;
    height: 22px;
    fill: currentColor;
}

.import-fab:active {
    transform: scale(0.92);
    opacity: 0.85;
}

.chat-fab-wrap {
    position: fixed;
    right: 16px;
    bottom: calc(16px + var(--sab, 0px));
    display: flex;
    justify-content: flex-end;
    padding: 0;
    z-index: 1;
    pointer-events: none;
}

.chat-fab-wrap :deep(.fab-add) {
    pointer-events: auto;
    position: static;
    right: auto;
    bottom: auto;
}

.gallery-tab-content {
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 16px;
}

.gallery-grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 8px;
}

.gallery-item {
    position: relative;
    aspect-ratio: 1;
    border-radius: 12px;
    overflow: hidden;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.06);
    cursor: pointer;
    transition: transform 0.15s ease, box-shadow 0.15s ease;
}

.gallery-item:active {
    transform: scale(0.95);
}

.gallery-thumb {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
}

.gallery-delete-btn {
    position: absolute;
    top: 4px;
    right: 4px;
    width: 26px;
    height: 26px;
    border-radius: 50%;
    background: rgba(0, 0, 0, 0.6);
    backdrop-filter: blur(4px);
    -webkit-backdrop-filter: blur(4px);
    border: none;
    color: #ff4444;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    opacity: 0;
    transition: opacity 0.15s ease;
    padding: 0;
}

.gallery-item:hover .gallery-delete-btn,
.gallery-item:active .gallery-delete-btn {
    opacity: 1;
}

.gallery-delete-btn :deep(svg) {
    width: 14px !important;
    height: 14px !important;
    fill: currentColor !important;
}

.gallery-empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 8px;
    padding: 40px 16px;
    color: rgba(255, 255, 255, 0.35);
}

.gallery-empty-icon {
    width: 48px;
    height: 48px;
    fill: currentColor;
    opacity: 0.4;
}

.gallery-empty span {
    font-size: 14px;
}

.gallery-add-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    padding: 12px 20px;
    border-radius: 14px;
    background: rgba(var(--vk-blue-rgb, 64, 128, 255), 0.12);
    color: var(--vk-blue, #4080ff);
    border: 1px solid rgba(var(--vk-blue-rgb, 64, 128, 255), 0.2);
    font-size: 14px;
    font-weight: 600;
    cursor: pointer;
    transition: all 0.15s ease;
    width: 100%;
}

.gallery-add-btn:active {
    transform: scale(0.97);
    opacity: 0.85;
}

.gallery-add-btn svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
}
</style>
