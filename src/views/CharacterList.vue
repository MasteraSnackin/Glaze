<script setup>
import { ref, computed, onMounted, onUnmounted, defineAsyncComponent } from 'vue';

const CatalogView = defineAsyncComponent(() => import('@/views/CatalogView.vue'));
import { db } from '@/utils/db.js';
import { translations, t, pluralize } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { attachLongPress } from '@/core/services/ui.js';
import { estimateTokens } from '@/utils/tokenizer.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { subscribeAppEvent, publishAppEvent } from '@/core/events/eventHub.js';
import { useCharacterActions } from '@/composables/character/useCharacterActions.js';
import { useSessionSheet } from '@/composables/character/useSessionSheet.js';
import CharacterCardSheet from '@/components/sheets/CharacterCardSheet.vue';

const props = defineProps({
  activeCategory: {
    type: String,
    default: 'all'
  }
});

const activeTab = ref('characters');
const activeMenuCharId = ref(null);
const activeSheetCharId = ref(null);
const charCardSheet = ref(null);

const emit = defineEmits(['open-chat']);

const characters = ref([]);
const searchQuery = ref('');
const isLoading = ref(true);
let unsubscribeSyncDataRefreshed = null;

const getCharTokens = (char) => {
  let text = char.name || "";
  text += "\n" + (char.description || "");
  text += "\n" + (char.personality || "");
  text += "\n" + (char.scenario || "");
  text += "\n" + (char.first_mes || "");
  text += "\n" + (char.mes_example || "");
  return estimateTokens(text);
};

const getAvatarUrl = (avatar) => {
  if (!avatar) return ''; 
  if (avatar.startsWith('http') || avatar.startsWith('blob') || avatar.startsWith('data:')) return avatar;
  return `/characters/${avatar}`;
};

const loadCharacters = async () => {
  isLoading.value = true;
  try {
    const chars = await db.getAll('characters');
    if (chars) {
        for (const char of chars) {
            if (!char.id) await db.saveCharacter(char);
        }
    }
    characters.value = chars || [];
  } catch (error) {
    console.error('Error loading characters:', error);
    characters.value = [];
  } finally {
    isLoading.value = false;
  }
};

const { onAddCharacter, onEditCharacter, openActions, setActiveMenuCharId } = useCharacterActions({ characters, loadCharacters });
const { openSessionsSheet } = useSessionSheet({ emit });

const wrappedOpenActions = (char) => {
  activeMenuCharId.value = char.id;
  setActiveMenuCharId(char.id);
  openActions(char);
};

const sortType = ref('date');
const sortDirection = ref('desc');

const toggleSortDirection = () => {
  sortDirection.value = sortDirection.value === 'asc' ? 'desc' : 'asc';
};

const openSortTypeSelector = () => {
  showBottomSheet({
    title: t('sort_by'),
    items: [
      {
        label: t('sort_name'),
        isActive: sortType.value === 'name',
        onClick: () => {
          sortType.value = 'name';
          closeBottomSheet();
        }
      },
      {
        label: t('sort_date'),
        isActive: sortType.value === 'date',
        onClick: () => {
          sortType.value = 'date';
          closeBottomSheet();
        }
      }
    ]
  });
};

const sortedCharacters = computed(() => {
  let chars = characters.value;

  if (props.activeCategory !== 'all') {
    chars = chars.filter(char => {
      return char.tags && char.tags.includes(props.activeCategory);
    });
  }

  chars = [...chars].sort((a, b) => {
    // Favorites always on top
    if (a.fav && !b.fav) return -1;
    if (!a.fav && b.fav) return 1;

    if (sortType.value === 'name') {
      const nameA = (a.name || '').toLowerCase();
      const nameB = (b.name || '').toLowerCase();
      if (nameA < nameB) return sortDirection.value === 'asc' ? -1 : 1;
      if (nameA > nameB) return sortDirection.value === 'asc' ? 1 : -1;
      return 0;
    } else {
      const timeA = parseInt(a.id || 0);
      const timeB = parseInt(b.id || 0);
      if (timeA < timeB) return sortDirection.value === 'asc' ? -1 : 1;
      if (timeA > timeB) return sortDirection.value === 'asc' ? 1 : -1;
      return 0;
    }
  });

  return chars;
});

const isMatchingSearch = (char) => {
  if (!searchQuery.value) return true;
  if (char.fav) return true;
  const query = searchQuery.value.toLowerCase();
  return (char.name || "").toLowerCase().includes(query);
};

const filteredCharacters = computed(() => {
  return sortedCharacters.value.filter(char => isMatchingSearch(char));
});

const hasVisibleCards = computed(() => {
  return filteredCharacters.value.length > 0;
});



const unsubs = [];

onMounted(() => {
  loadCharacters();
  unsubs.push(subscribeAppEvent(APP_EVENTS.ui.headerSearch, ({ detail }) => searchQuery.value = detail));
  unsubs.push(subscribeAppEvent(APP_EVENTS.domain.character.updated, loadCharacters));
  unsubscribeSyncDataRefreshed = subscribeAppEvent(APP_EVENTS.domain.sync.dataRefreshed, loadCharacters);
});

onUnmounted(() => {
  unsubs.forEach(unsub => unsub());
  unsubscribeSyncDataRefreshed?.();
  unsubscribeSyncDataRefreshed = null;
});

const vLongPress = {
  mounted: (el, binding) => {
    const check = attachLongPress(el, binding.value);
    el._checkLongPress = check;
  }
};

const handleCharClick = (char) => {
  activeSheetCharId.value = char.id;
  charCardSheet.value?.open(char, { importEnabled: false });
};

const handleSheetVisibleUpdate = (visible) => {
  if (!visible) activeSheetCharId.value = null;
};

defineExpose({ onAddCharacter, loadCharacters });
</script>

<template>
  <div class="view-content-wrapper">
    <!-- Tab Bar -->
    <div class="tabs-row">
      <div class="top-tabs-container">
        <div class="tab-slider" :style="{ transform: `translateX(${activeTab === 'catalog' ? '100%' : '0'})` }"></div>
        <div class="top-tab" :class="{ active: activeTab === 'characters' }" @click="activeTab = 'characters'">
          <svg viewBox="0 0 24 24" class="tab-icon"><path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"/></svg>
          <span>{{ t('tab_my_characters') }}</span>
        </div>
        <div class="top-tab" :class="{ active: activeTab === 'catalog' }" @click="activeTab = 'catalog'">
          <svg viewBox="0 0 24 24" class="tab-icon"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/></svg>
          <span>{{ t('tab_catalog') }}</span>
        </div>
      </div>
      <Transition name="tabs-add-btn">
        <button v-if="activeTab === 'characters'" class="tabs-add-btn" @click="onAddCharacter">
          <svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>
          <span>{{ t('btn_add') }}</span>
        </button>
      </Transition>
    </div>

    <!-- Catalog Tab -->
    <CatalogView v-if="activeTab === 'catalog'" class="char-catalog-embed" />

    <!-- Characters Tab -->
    <template v-else>
    <!-- Sort controls -->
    <div class="sort-controls" v-if="characters.length > 0">
      <div class="sort-dir-btn" @click="toggleSortDirection" :class="{ 'is-asc': sortDirection === 'asc' }">
        <svg viewBox="0 0 24 24"><path d="M20 12l-1.41-1.41L13 16.17V4h-2v12.17l-5.58-5.59L4 12l8 8 8-8z"/></svg>
      </div>
      <div class="preset-selector" @click="openSortTypeSelector">
        <span>{{ sortType === 'name' ? t('sort_name') : t('sort_date') }}</span>
        <svg viewBox="0 0 24 24" style="width: 20px; height: 20px; fill: currentColor;" class="selector-chevron"><path d="M7 10l5 5 5-5z"/></svg>
      </div>
    </div>

    <!-- Character Count -->
    <div class="character-count" v-if="characters.length > 0">
      {{ t('catalog_total', { count: filteredCharacters.length }) }}
    </div>

    <!-- Main Character List -->
    <TransitionGroup 
      tag="div" 
      class="character-grid" 
      id="characters-list" 
      name="list"
    >
      <div 
        v-for="char in filteredCharacters" 
        :key="char.id || char.name"
        class="character-card"
        :class="{
          favorite: char.fav,
          'menu-open': activeMenuCharId === char.id || activeSheetCharId === char.id
        }"
        @click="handleCharClick(char)"
        @contextmenu.prevent="wrappedOpenActions(char)"
      >
        <div class="card-token-badge">
          <svg viewBox="0 0 24 24"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>
          <span>{{ getCharTokens(char) }}</span>
        </div>
        <div class="card-edit-btn" @click.stop="wrappedOpenActions(char)">
          <svg viewBox="0 0 24 24"><path d="M12 8c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm0 2c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2zm0 6c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2z"/></svg>
        </div>
        <div class="card-image-wrapper">
          <img v-if="char.thumbnail || char.avatar" :src="getAvatarUrl(char.thumbnail || char.avatar)" :alt="char.name" loading="lazy" class="card-image">
          <div v-else class="card-placeholder" :style="{ backgroundColor: char.color || '#66ccff' }">
            {{ (char.name && char.name[0]) ? char.name[0].toUpperCase() : '?' }}
          </div>
          <div class="card-gradient"></div>
        </div>
        
        <div class="card-info">
          <div class="card-header-row" :class="{ 'is-favorite': char.fav }">
            <div class="card-fav-icon" v-if="char.fav">
              <svg viewBox="0 0 24 24"><path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/></svg>
            </div>
            <div class="card-name">{{ char.name }}</div>
          </div>
          <div class="card-desc" v-if="char.scenario || char.description" v-html="char.scenario || char.description"></div>
          
          <div class="card-actions">
            <div class="card-tag" v-if="char.version">
v{{ char.version }}
</div>
          </div>
        </div>
      </div>
    </TransitionGroup>

    <div v-if="!isLoading && !hasVisibleCards" class="empty-state">
      <svg class="empty-state-icon" viewBox="0 0 24 24"><path d="M16 11c1.66 0 2.99-1.34 2.99-3S17.66 5 16 5c-1.66 0-3 1.34-3 3s1.34 3 3 3zm-8 0c1.66 0 2.99-1.34 2.99-3S9.66 5 8 5C6.34 5 5 6.34 5 8s1.34 3 3 3zm0 2c-2.33 0-7 1.17-7 3.5V19h14v-2.5c0-2.33-4.67-3.5-7-3.5zm8 0c-.29 0-.62.02-.97.05 1.16.84 1.97 1.97 1.97 3.45V19h6v-2.5c0-2.33-4.67-3.5-7-3.5z"/></svg>
      <div class="empty-state-text">
{{ t('no_characters') }}
</div>
    </div>
    </template>
    <CharacterCardSheet ref="charCardSheet" @update:visible="handleSheetVisibleUpdate" />
  </div>
</template>

<style scoped>

.char-catalog-embed {
  /* Match the height CatalogView expects: viewport minus header area, char tabs, and footer area */
  height: calc(100dvh - var(--header-height, 60px) - 16px - 53px - var(--footer-height, 80px) - 20px);
}

.tabs-row {
  display: flex;
  align-items: center;
  gap: 12px;
  margin: 10px 16px 12px;
}

.top-tabs-container {
  display: flex;
  position: relative;
  align-items: stretch;
  padding: 0;
  flex: 1;
  background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.1);
  backdrop-filter: blur(var(--element-blur, 12px));
  -webkit-backdrop-filter: blur(var(--element-blur, 12px));
  border: 1px solid rgba(var(--vk-blue-rgb, 82, 139, 204), 0.2);
  border-radius: 100px;
  overflow: hidden;
}

@media (min-width: 600px) {
  .top-tabs-container {
    flex: 0 0 clamp(320px, 33.333%, 500px);
  }
}

.tabs-add-btn {
  display: none;
}

@media (min-width: 600px) {
  .tabs-add-btn {
    display: flex;
    align-items: center;
    gap: 6px;
    height: 40px;
    padding: 0 16px;
    border-radius: 100px;
    background-color: var(--vk-blue, #4080ff);
    color: #fff;
    font-size: 14px;
    font-weight: 600;
    border: none;
    cursor: pointer;
    flex-shrink: 0;
    margin-left: auto;
    transition: transform 0.1s ease, opacity 0.2s;
    user-select: none;
  }

  .tabs-add-btn:hover {
    transform: translateY(-1px);
  }

  .tabs-add-btn:active {
    transform: scale(0.95);
    opacity: 0.85;
  }

  .tabs-add-btn svg {
    width: 18px;
    height: 18px;
    fill: currentColor;
  }
}

.tabs-add-btn-enter-active,
.tabs-add-btn-leave-active {
  transition: opacity 0.15s ease, transform 0.15s ease;
}

.tabs-add-btn-enter-from,
.tabs-add-btn-leave-to {
  opacity: 0;
  transform: scale(0.85);
}

.tab-slider {
  position: absolute;
  top: 0;
  left: 0;
  width: 50%;
  height: 100%;
  background-color: var(--vk-blue, #4080ff);
  border-radius: 100px;
  transition: transform 0.3s cubic-bezier(0.4, 0, 0.2, 1);
  z-index: 0;
}

.top-tab {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
  padding: 10px 14px;
  font-size: 14px;
  font-weight: 600;
  color: var(--vk-blue, #4080ff);
  cursor: pointer;
  z-index: 1;
  transition: color 0.3s ease;
  user-select: none;
}

.top-tab.active {
  color: #fff;
}

.tab-icon {
  width: 18px;
  height: 18px;
  fill: currentColor;
}

.sort-controls {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 12px;
  padding: 12px 16px;
}

.sort-dir-btn {
  width: 32px;
  height: 32px;
  display: flex;
  align-items: center;
  justify-content: center;
  border-radius: 50%;
  background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.15);
  backdrop-filter: blur(var(--element-blur, 12px));
  -webkit-backdrop-filter: blur(var(--element-blur, 12px));
  border: 1px solid rgba(var(--vk-blue-rgb, 82, 139, 204), 0.2);
  cursor: pointer;
  color: var(--vk-blue);
  transition: transform 0.1s ease, background-color 0.2s, opacity 0.2s;
  flex-shrink: 0;
}

@media (hover: hover) {
  .sort-dir-btn:hover {
    background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.25);
    border-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.4);
    transform: translateY(-1px);
  }
}

.sort-dir-btn:active {
  transform: scale(0.95);
  opacity: 0.8;
}

.sort-dir-btn svg {
  width: 20px;
  height: 20px;
  fill: currentColor;
  transition: transform 0.3s cubic-bezier(0.34, 1.56, 0.64, 1);
}

.sort-dir-btn.is-asc svg {
  transform: rotate(180deg);
}

.preset-selector {
  height: 32px;
  display: flex;
  align-items: center;
  gap: 6px;
  cursor: pointer;
  font-weight: 600;
  font-size: 13px;
  color: var(--vk-blue);
  padding: 0 14px;
  border-radius: 16px;
  background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.15);
  backdrop-filter: blur(var(--element-blur, 12px));
  -webkit-backdrop-filter: blur(var(--element-blur, 12px));
  border: 1px solid rgba(var(--vk-blue-rgb, 82, 139, 204), 0.2);
  transition: transform 0.1s ease, background-color 0.2s, border-color 0.2s, opacity 0.2s;
  overflow: hidden;
  user-select: none;
}

@media (hover: hover) {
  .preset-selector:hover {
    background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.25);
    border-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.4);
    transform: translateY(-1px);
  }
}

.preset-selector:active {
  transform: scale(0.95);
  opacity: 0.8;
}

.preset-selector.active {
  background-color: var(--vk-blue, #4080ff);
  color: #fff;
  border-color: var(--vk-blue, #4080ff);
  box-shadow: 0 4px 12px rgba(var(--vk-blue-rgb, 82, 139, 204), 0.4);
}

.preset-selector.dropdown-open {
  background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.25);
  border-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.5);
}

.preset-selector.dropdown-open .selector-chevron {
  transform: rotate(180deg);
}

.selector-chevron {
  width: 20px;
  height: 20px;
  fill: currentColor;
  transition: transform 0.2s cubic-bezier(0.34, 1.56, 0.64, 1);
}

.character-count {
  font-size: 11px;
  color: var(--text-secondary, rgba(255,255,255,0.45));
  padding: 2px 16px 6px;
  flex-shrink: 0;
}

/* Styles */

/* TransitionGroup Animations */
.list-enter-active,
.list-leave-active {
  transition: all 0.3s ease;
}

.list-enter-from,
.list-leave-to {
  opacity: 0;
  transform: scale(0.9);
}

/* Move animation (FLIP) */
.list-move {
  transition: transform 0.3s ease;
}

.character-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(140px, 1fr));
  gap: 12px;
  padding: 0 16px;
  padding-bottom: calc(90px + var(--sab)); /* Space for bottom nav */
}

@media (min-width: 600px) {
  .character-grid {
    grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
    gap: 16px;
  }
}

.character-card {
  position: relative;
  border-radius: 16px;
  overflow: hidden;
  aspect-ratio: 2 / 3;
  background-color: var(--bg-color-light, #2a2a2a);
  box-shadow: 0 4px 6px rgba(0,0,0,0.1);
  transition: transform 0.3s cubic-bezier(0.34, 1.56, 0.64, 1), box-shadow 0.3s ease, border-color 0.3s ease;
  cursor: pointer;
  border: 2px solid rgba(255,255,255,0.05);
}

.character-card:active {
  transform: scale(0.96);
}

@media (hover: hover) {
  .character-card:hover, .character-card.menu-open {
    transform: translateY(-4px) scale(1.01);
    box-shadow: 0 12px 24px rgba(0,0,0,0.3);
  }

  .character-card.favorite:hover, .character-card.favorite.menu-open {
    box-shadow: 0 12px 24px rgba(255, 107, 107, 0.25);
    border-color: #ff6b6b;
  }

  .character-card:hover .card-edit-btn, .character-card.menu-open .card-edit-btn {
    box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.4);
    opacity: 1;
    transform: scale(1.1);
  }

  .character-card:hover .card-image, .character-card.menu-open .card-image {
    transform: scale(1.05);
  }
  
  .character-card:hover .card-token-badge, .character-card.menu-open .card-token-badge {
    box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.4);
  }
}

.character-card.menu-open {
  transform: translateY(-4px) scale(1.01);
  box-shadow: 0 12px 24px rgba(0,0,0,0.3);
}

.character-card.favorite.menu-open {
  box-shadow: 0 12px 24px rgba(var(--vk-blue-rgb, 81, 129, 184), 0.25);
  border-color: rgba(var(--vk-blue-rgb, 81, 129, 184), 0.8);
}

.character-card.menu-open .card-edit-btn {
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.4);
  opacity: 1;
  transform: scale(1.1);
}

.character-card.menu-open .card-image {
  transform: scale(1.05);
}

.character-card.menu-open .card-token-badge {
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.4);
}

.character-card.favorite {
  border: 2px solid #ff6b6b;
}

.card-image-wrapper {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  height: 100%;
  z-index: 0;
}

.card-image {
  width: 100%;
  height: 100%;
  object-fit: cover;
  transition: transform 0.5s ease;
}

.card-placeholder {
  width: 100%;
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 3em;
  color: rgba(255,255,255,0.8);
  font-weight: bold;
}

.card-gradient {
  position: absolute;
  bottom: 0;
  left: 0;
  width: 100%;
  height: 70%;
  background: linear-gradient(to top, rgba(0,0,0,0.95) 0%, rgba(0,0,0,0.6) 50%, transparent 100%);
  pointer-events: none;
}

.card-info {
  position: absolute;
  bottom: 0;
  left: 0;
  width: 100%;
  padding: 12px;
  box-sizing: border-box;
  z-index: 1;
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.card-header-row {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
}

.card-header-row.is-favorite {
  justify-content: flex-start;
  gap: 6px;
}

.card-name {
  font-weight: 700;
  font-size: 1.1em;
  color: #fff;
  text-shadow: 0 2px 4px rgba(0,0,0,0.8);
  line-height: 1.2;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
  transition: color 0.3s ease;
}

.character-card.favorite .card-name {
  color: #ff6b6b;
}

.card-fav-icon {
  flex-shrink: 0;
  width: 14px;
  height: 14px;
  fill: #ff6b6b;
  filter: drop-shadow(0 1px 2px rgba(0,0,0,0.5));
}

.character-card.favorite .card-fav-icon {
  margin-top: 3px;
}

.card-desc {
  font-size: 0.8em;
  color: rgba(255,255,255,0.8);
  display: -webkit-box;
  -webkit-line-clamp: 3;
  line-clamp: 3;
  -webkit-box-orient: vertical;
  overflow: hidden;
  text-shadow: 0 1px 2px rgba(0,0,0,0.8);
  line-height: 1.3;
}

.card-actions {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-top: 4px;
}

.card-tag {
  font-size: 0.7em;
  color: rgba(255,255,255,0.5);
  background: rgba(0,0,0,0.3);
  padding: 2px 6px;
  border-radius: 4px;
}

.card-edit-btn {
  position: absolute;
  top: 8px;
  right: 8px;
  z-index: 10;
  width: 32px;
  height: 32px;
  display: flex;
  align-items: center;
  justify-content: center;
  border-radius: 50%;
  background: rgba(0,0,0,0.5);
  backdrop-filter: blur(4px);
  transition: background 0.2s, opacity 0.2s, transform 0.2s, box-shadow 0.2s;
  opacity: 0.8;
}

.card-edit-btn:active {
  background: rgba(0,0,0,0.7);
}

.card-edit-btn svg {
  width: 18px;
  height: 18px;
  fill: #fff;
}

.card-token-badge {
  position: absolute;
  top: 8px;
  left: 8px;
  z-index: 10;
  display: flex;
  align-items: center;
  font-size: 11px;
  font-weight: 600;
  color: #fff;
  background-color: rgba(0,0,0,0.6);
  backdrop-filter: blur(4px);
  padding: 4px 8px;
  border-radius: 12px;
  pointer-events: none;
  transition: background-color 0.3s ease, box-shadow 0.3s ease;
}

.card-token-badge svg {
  width: 12px;
  height: 12px;
  margin-right: 4px;
  fill: currentColor;
  opacity: 0.9;
}

.empty-state {
  grid-column: 1 / -1;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  padding: 40px 0;
  text-align: center;
  color: var(--text-gray);
}

.empty-state-icon {
  width: 64px;
  height: 64px;
  margin-bottom: 16px;
  fill: var(--text-gray);
  opacity: 0.5;
}

.empty-state-text {
  font-size: 1.1em;
  font-weight: 500;
}
</style>
