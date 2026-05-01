<script setup>
import { ref, computed, watch, defineAsyncComponent } from 'vue';
import BottomSheet from '@/components/ui/BottomSheet.vue';
import MagicDrawer from '@/components/chat/MagicDrawer.vue';
import ToolStripTooltip from '@/components/ToolStripTooltip.vue';
import { sidebarState } from '@/core/states/sidebarState.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';

const t = (key) => translations[currentLang.value]?.[key] || key;

const PresetView = defineAsyncComponent(() => import('@/views/PresetView.vue'));
const ApiView = defineAsyncComponent(() => import('@/views/ApiView.vue'));
const PersonasView = defineAsyncComponent(() => import('@/views/PersonasView.vue'));
const LorebookSheet = defineAsyncComponent(() => import('@/components/sheets/LorebookSheet.vue'));
const RegexSheet = defineAsyncComponent(() => import('@/components/sheets/RegexSheet.vue'));
const ToolsView = defineAsyncComponent(() => import('@/views/ToolsView.vue'));

const props = defineProps({
    bottomSheetState: Object,
    rightSidebarState: Object,
    activeChatCharObj: Object,
    contextBreakdown: { type: Object, default: null },
    activePresetTokenCount: { type: Number, default: 0 },
    currentView: { type: String, default: '' }
});

const emit = defineEmits([
    'closeBottomSheet',
    'magic-notes',
    'magic-context',
    'magic-summary',
    'magic-sessions',
    'magic-stats',
    'magic-impersonate',
    'magic-char-card',
    'magic-api',
    'magic-presets',
    'magic-lorebooks',
    'magic-memory-books',
    'magic-regex',
    'magic-image-gen',
    'magic-glossary',
    'request-preview'
]);

// ── Two independent widths: expanded and collapsed never affect each other ──
const COLLAPSE_THRESHOLD = 120;
const EXPANDED_MIN = 200;
const EXPANDED_MAX = 800;
const COLLAPSED_MIN = 48;
const COLLAPSED_DEFAULT = 64;

const expandedWidth = ref(parseInt(localStorage.getItem('gz_right_sidebar_width')) || 300);
const collapsedWidth = ref(parseInt(localStorage.getItem('gz_right_sidebar_collapsed_width')) || COLLAPSED_DEFAULT);
const collapsed = ref(localStorage.getItem('gz_right_sidebar_width_collapsed') === '1');

const rightSidebarWidth = computed(() => collapsed.value ? collapsedWidth.value : expandedWidth.value);

const startRightResize = (e) => {
    e.preventDefault();
    const startX = e.clientX;
    const startingCollapsed = collapsed.value;
    const startWidth = rightSidebarWidth.value;
    const originalCursor = document.body.style.cursor;
    document.body.style.cursor = 'col-resize';

    const onMouseMove = (moveEvent) => {
        const newWidth = startWidth - (moveEvent.clientX - startX); // right handle: drag left = wider
        if (startingCollapsed) {
            // Dragging from collapsed: keep widths independent, switch mode at threshold
            if (newWidth >= COLLAPSE_THRESHOLD) {
                collapsed.value = false;
                expandedWidth.value = Math.min(EXPANDED_MAX, newWidth);
            } else {
                collapsed.value = true;
                collapsedWidth.value = Math.max(COLLAPSED_MIN, newWidth);
            }
        } else {
            // Dragging from expanded: only saves expanded width; crossing threshold collapses
            if (newWidth < COLLAPSE_THRESHOLD) {
                collapsed.value = true;
            } else {
                collapsed.value = false;
                expandedWidth.value = Math.min(EXPANDED_MAX, newWidth);
            }
        }
    };

    const onMouseUp = () => {
        document.body.style.cursor = originalCursor;
        document.removeEventListener('mousemove', onMouseMove);
        document.removeEventListener('mouseup', onMouseUp);
        if (collapsed.value) {
            collapsedWidth.value = Math.max(COLLAPSED_MIN, Math.min(COLLAPSE_THRESHOLD - 1, collapsedWidth.value));
            localStorage.setItem('gz_right_sidebar_collapsed_width', collapsedWidth.value);
            localStorage.setItem('gz_right_sidebar_width_collapsed', '1');
        } else {
            expandedWidth.value = Math.max(EXPANDED_MIN, expandedWidth.value);
            localStorage.setItem('gz_right_sidebar_width', expandedWidth.value);
            localStorage.setItem('gz_right_sidebar_width_collapsed', '0');
        }
    };

    document.addEventListener('mousemove', onMouseMove);
    document.addEventListener('mouseup', onMouseUp);
};

const isChat = computed(() => props.currentView === 'view-chat');
const hasSheet = computed(() => props.bottomSheetState.visible || props.rightSidebarState.isOccupied);

// ── Auto-expand on subview ──
const wasAutoExpanded = ref(false);

watch(hasSheet, (newHasSheet, oldHasSheet) => {
    if (newHasSheet && !oldHasSheet) {
        if (collapsed.value) {
            wasAutoExpanded.value = true;
            collapsed.value = false;
        }
    } else if (!newHasSheet && oldHasSheet) {
        if (wasAutoExpanded.value) {
            collapsed.value = true;
            wasAutoExpanded.value = false;
        }
    }
});

// Active tool tracking
const activeTool = ref(null);
const activeToolRef = ref(null);

const toolComponentMap = {
    'view-presets': PresetView,
    'view-api': ApiView,
    'view-personas': PersonasView,
    'view-lorebook': LorebookSheet,
    'view-regex': RegexSheet,
};

// Tool strip icon definitions (mirrors ToolsView.vue tools list)
const toolStripItems = computed(() => [
    { id: 'view-personas', label: t('tab_personas') || 'Personas', icon: 'M19 3H5c-1.11 0-2 .9-2 2v14c0 1.1.89 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-7 3c1.66 0 3 1.34 3 3s-1.34 3-3 3-3-1.34-3-3 1.34-3 3-3zm6 12H6v-1c0-2 4-3.1 6-3.1s6 1.1 6 3.1v1z' },
    { id: 'view-presets', label: t('subtab_preset') || 'Presets', icon: 'M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6h-6V2zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z' },
    { id: 'view-api', label: t('tab_api') || 'API', icon: 'M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96z' },
    { id: 'view-lorebook', label: t('menu_lorebooks') || 'Lorebook', icon: 'M4 6H2v14c0 1.1.9 2 2 2h14v-2H4V6zm16-4H8c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-1 9H9V9h10v2zm-4 4H9v-2h6v2zm4-8H9V5h10v2z' },
    { id: 'view-regex', label: t('menu_regex') || 'Regex', icon: 'M9.4 16.6L4.8 12l4.6-4.6L8 6l-6 6 6 6 1.4-1.4zm5.2 0l4.6-4.6-4.6-4.6L16 6l6 6-6 6-1.4-1.4z' },
]);

const activeToolComponent = computed(() =>
    activeTool.value ? toolComponentMap[activeTool.value] : null
);

// Chat strip items (mirrors MagicDrawer allAvailableItems)
const magicDrawerRef = ref(null);

const chatStripItems = computed(() => {
    // Default items if MagicDrawer not yet mounted
    const defaultItems = [
        { id: 'notes', label: t('magic_authors_notes') || 'Author\'s Notes', icon: 'M3 10h11v2H3v-2zm0-2h11V6H3v2zm0 8h7v-2H3v2zm15.01-3.13l.71-.71c.39-.39 1.02-.39 1.41 0l.71.71c.39.39.39 1.02 0 1.41l-.71.71-2.12-2.12zm-.71.71l-5.3 5.3V21h2.12l5.3-5.3-2.12-2.12z' },
        { id: 'context', label: t('label_tokenizer') || 'Tokenizer', icon: 'M4 11h16v2H4zm0-6h16v2H4zm0 12h10v2H4z' },
        { id: 'summary', label: t('magic_summary') || 'Summary', icon: 'M14 17H4v2h10v-2zm6-8H4v2h16V9zM4 15h16v-2H4v2zM4 5v2h16V5H4z' },
        { id: 'sessions', label: t('history_title') || 'Sessions', icon: 'M13 3a9 9 0 0 0-9 9H1l3.89 3.89.07.14L9 12H6c0-3.87 3.13-7 7-7s7 3.13 7 7-3.13 7-7 7c-1.93 0-3.68-.79-4.94-2.06l-1.42 1.42C8.27 19.99 10.51 21 13 21c4.97 0 9-4.03 9-9s-4.03-9-9-9zm-1 5v5l4.28 2.54.72-1.21-3.5-2.08V8H12z' },
        { id: 'stats', label: t('action_chat_stats') || 'Stats', icon: 'M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zM9 17H7v-7h2v7zm4 0h-2V7h2v10zm4 0h-2v-4h2v4z' },
        { id: 'char-card', label: t('block_char_card') || 'Character Card', icon: 'M3 5v14c0 1.1.89 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2H5c-1.11 0-2 .9-2 2zm12 4c0 1.66-1.34 3-3 3s-3-1.34-3-3 1.34-3 3-3 3 1.34 3 3zm-9 8c0-2 4-3.1 6-3.1s6 1.1 6 3.1v1H6v-1z' },
        { id: 'lorebooks', label: t('menu_lorebooks') || 'Lorebooks', icon: 'M4 6H2v14c0 1.1.9 2 2 2h14v-2H4V6zm16-4H8c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-1 9H9V9h10v2zm-4 4H9v-2h6v2zm4-8H9V5h10v2z' },
        { id: 'memory-books', label: t('magic_memory_books') || 'Memory Books', icon: 'M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-2 10h-4v4h-2v-4H7v-2h4V7h2v4h4v2z' },
        { id: 'regex', label: t('menu_regex') || 'Regex', icon: 'M9.4 16.6L4.8 12l4.6-4.6L8 6l-6 6 6 6 1.4-1.4zm5.2 0l4.6-4.6-4.6-4.6L16 6l6 6-6 6-1.4-1.4z' },
        { id: 'api', label: t('tab_api') || 'API', icon: 'M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96z' },
        { id: 'presets', label: t('subtab_preset') || 'Presets', icon: 'M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6h-6V2zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z' },
        { id: 'preview', label: t('magic_request_preview') || 'Request Preview', icon: 'M12 4.5C7 4.5 2.73 7.61 1 12c1.73 4.39 6 7.5 11 7.5s9.27-3.11 11-7.5c-1.73-4.39-6-7.5-11-7.5zM12 17c-2.76 0-5-2.24-5-5s2.24-5 5-5 5 2.24 5 5-2.24 5-5 5zm0-8c-1.66 0-3 1.34-3 3s1.34 3 3 3 3-1.34 3-3-1.34-3-3-3z' },
        { id: 'personas', label: t('tab_personas') || 'Personas', icon: 'M19 3H5c-1.11 0-2 .9-2 2v14c0 1.1.89 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-7 3c1.66 0 3 1.34 3 3s-1.34 3-3 3-3-1.34-3-3 1.34-3 3-3zm6 12H6v-1c0-2 4-3.1 6-3.1s6 1.1 6 3.1v1z' },
        { id: 'image-gen', label: t('imggen_title') || 'Image Gen', icon: 'M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z' },
    ];
    
    // Try to get items from MagicDrawer if available
    if (magicDrawerRef.value && magicDrawerRef.value.getDisplayItems) {
        const displayItems = magicDrawerRef.value.getDisplayItems();
        return displayItems
            .filter(item => !item.isAddBtn)
            .map(item => ({
                ...item,
                label: (item.i18n ? t(item.i18n) : null) || item.fallback || item.label || item.id,
            }));
    }
    
    return defaultItems;
});

const handleChatAction = (item) => {
    // Delegate to MagicDrawer if available
    if (magicDrawerRef.value && magicDrawerRef.value.handleAction) {
        magicDrawerRef.value.handleAction(item);
    } else {
        // Fallback: emit event directly
        const eventMap = {
            'notes': 'magic-notes',
            'context': 'magic-context',
            'summary': 'magic-summary',
            'sessions': 'magic-sessions',
            'stats': 'magic-stats',
            'char-card': 'magic-char-card',
            'lorebooks': 'magic-lorebooks',
            'memory-books': 'magic-memory-books',
            'regex': 'magic-regex',
            'api': 'magic-api',
            'presets': 'magic-presets',
            'preview': 'request-preview',
            'personas': 'magic-personas',
            'image-gen': 'magic-image-gen',
        };
        const eventName = eventMap[item.id];
        if (eventName) emit(eventName);
    }
};

// When the tool component mounts and ref becomes available, open it
watch(activeToolRef, (ref) => {
    if (ref && activeTool.value) {
        ref.open();
    }
});

let closeTimeout = null;

// When the sheet closes (back button inside tool), clear activeTool
watch(() => sidebarState.isOccupied, (occupied) => {
    if (closeTimeout) {
        clearTimeout(closeTimeout);
        closeTimeout = null;
    }
    if (!occupied) {
        closeTimeout = setTimeout(() => {
            activeTool.value = null;
        }, 300);
    }
});

// Clear activeTool when entering chat
watch(isChat, (val) => {
    if (val) activeTool.value = null;
});

function openTool(viewId) {
    if (!toolComponentMap[viewId]) return;
    if (activeTool.value === viewId) {
        // Toggle off
        if (activeToolRef.value && typeof activeToolRef.value.close === 'function') {
            activeToolRef.value.close();
        } else {
            activeTool.value = null;
        }
        return;
    }
    
    // Auto-expand before setting active tool so the component can mount
    if (collapsed.value) {
        wasAutoExpanded.value = true;
        collapsed.value = false;
    }
    
    activeTool.value = viewId;
    // ref.open() will be called by the watch above when component mounts
}

</script>

<template>
  <div
      class="desktop-sidebar-right"
      id="desktop-sidebar-container"
      :class="{
          'has-sheet': hasSheet,
          'has-left-strip': isChat ? (hasSheet && !collapsed) : (!!activeToolComponent && !collapsed),
          'tools-mode': !isChat,
          'is-chat': isChat,
          'sidebar-collapsed': collapsed
      }"
      :style="{ width: rightSidebarWidth + 'px', minWidth: rightSidebarWidth + 'px', maxWidth: rightSidebarWidth + 'px' }"
  >
      <div class="sidebar-drag-handle right-handle" @mousedown="startRightResize"></div>

      <!-- ── Chat mode: MagicDrawer icon strip + BottomSheet ── -->
      <template v-if="isChat">
          <!-- Collapsed or has sheet: icon strip with ToolStripTooltip -->
          <template v-if="collapsed || hasSheet">
              <div class="tools-strip magic-drawer-sidebar icon-only" :class="{ 'left-icon-strip': hasSheet && !collapsed }">
                  <div class="drawer-content">
                      <ToolStripTooltip :items="chatStripItems" placement="left">
                          <template #default="{ onItemEnter, onItemLeave }">
                              <div
                                  v-for="item in chatStripItems"
                                  :key="item.id"
                                  class="magic-item"
                                  :data-tooltip-id="item.id"
                                  @click="handleChatAction(item)"
                                  @mouseenter="(e) => onItemEnter(item.id, e)"
                                  @mouseleave="onItemLeave"
                              >
                                  <div class="magic-item-content">
                                      <div class="card-icon">
                                          <svg viewBox="0 0 24 24"><path :d="item.icon"/></svg>
                                      </div>
                                  </div>
                              </div>
                          </template>
                      </ToolStripTooltip>
                  </div>
              </div>
          </template>

          <!-- Expanded and no sheet: full MagicDrawer -->
          <MagicDrawer
              v-show="!collapsed && !hasSheet"
              ref="magicDrawerRef"
              :visible="!collapsed && !hasSheet"
              :sidebar-mode="true"
              :icon-only="false"
              :active-char="activeChatCharObj"
              :context-breakdown="contextBreakdown"
              :active-preset-token-count="activePresetTokenCount"
              @magic-notes="emit('magic-notes')"
              @magic-context="emit('magic-context')"
              @magic-summary="emit('magic-summary')"
              @magic-sessions="emit('magic-sessions')"
              @magic-stats="emit('magic-stats')"
              @magic-impersonate="emit('magic-impersonate')"
              @magic-char-card="emit('magic-char-card')"
              @magic-api="emit('magic-api')"
              @magic-presets="emit('magic-presets')"
              @magic-lorebooks="emit('magic-lorebooks')"
              @magic-memory-books="emit('magic-memory-books')"
              @magic-regex="emit('magic-regex')"
              @magic-image-gen="emit('magic-image-gen')"
              @magic-glossary="emit('magic-glossary')"
              @request-preview="emit('request-preview')"
              @close="() => {}"
          />

          <BottomSheet
               v-bind="bottomSheetState"
               :sidebar-mode="true"
               @close="emit('closeBottomSheet')"
          />
      </template>

      <!-- ── Non-chat mode: Tools icon strip + ToolsView + tool sheets ── -->
      <template v-else>
          <!-- Collapsed or has active tool: vertical tool icon strip mirroring MagicDrawer icon styling -->
          <template v-if="collapsed || activeToolComponent">
              <div class="tools-strip magic-drawer-sidebar icon-only" :class="{ 'left-icon-strip': activeToolComponent && !collapsed }">
                  <div class="drawer-content">
                      <ToolStripTooltip :items="toolStripItems" placement="left">
                          <template #default="{ onItemEnter, onItemLeave }">
                              <div
                                  v-for="item in toolStripItems"
                                  :key="item.id"
                                  class="magic-item"
                                  :class="{ active: activeTool === item.id }"
                                  :data-tooltip-id="item.id"
                                  @click="openTool(item.id)"
                                  @mouseenter="(e) => onItemEnter(item.id, e)"
                                  @mouseleave="onItemLeave"
                              >
                                  <div class="magic-item-content">
                                      <div class="card-icon">
                                          <svg viewBox="0 0 24 24"><path :d="item.icon"/></svg>
                                      </div>
                                  </div>
                              </div>
                          </template>
                      </ToolStripTooltip>
                  </div>
              </div>
          </template>

          <!-- Expanded: ToolsView background + active tool sheet -->
          <template v-if="!collapsed">
              <div class="tools-view-bg">
                  <ToolsView :sidebar-mode="true" @tool-select="openTool" />
              </div>

              <component
                  :is="activeToolComponent"
                  v-if="activeToolComponent"
                  ref="activeToolRef"
              />
          </template>
      </template>

      <!-- Unified Sidebar Content container (Teleport target) -->
      <div id="desktop-sidebar-content" :class="{ occupied: sidebarState.isOccupied }"></div>
  </div>
</template>

<style scoped>
.tools-view-bg {
    flex: 1;
    min-height: 0;
    overflow-y: auto;
    padding-left: 0;
    position: relative;
    z-index: 1;
    transition: transform 0.3s cubic-bezier(0.2, 0.8, 0.2, 1), opacity 0.3s cubic-bezier(0.2, 0.8, 0.2, 1);
    opacity: 1;
    transform: translateX(0);
}

.has-sheet .tools-view-bg {
    opacity: 0;
    transform: translateX(-30px);
    pointer-events: none;
}

.tools-view-bg :deep(.view) {
    padding-bottom: 8px !important;
}

/* ── Collapsed tools strip ── */
.tools-strip {
    display: flex;
    flex-direction: column;
    align-items: center;
    width: 64px;
    height: 100%;
    overflow-y: auto;
    overflow-x: hidden;
    scrollbar-width: none;
}

.tools-strip::-webkit-scrollbar {
    display: none;
}

/* Base Magic Drawer imitation classes for tools strip */
.tools-strip.magic-drawer-sidebar {
    position: relative !important;
    background-color: transparent !important;
    backdrop-filter: none !important;
    border: none !important;
    box-shadow: none !important;
}

.tools-strip .drawer-content {
    display: flex;
    flex-direction: column;
    padding: 0 !important;
    width: 100%;
}

.tools-strip .magic-item {
    background-color: transparent !important;
    backdrop-filter: none !important;
    border: none !important;
    border-radius: 0 !important;
    padding: 14px 16px !important;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05) !important;
    margin: 0 !important;
    cursor: pointer;
    transition: background-color 0.2s;
    justify-content: flex-start !important;
    min-height: 48px;
    display: flex;
}

.tools-strip .magic-item:hover {
    background-color: rgba(255, 255, 255, 0.04) !important;
}

.tools-strip .magic-item:active {
    background-color: rgba(255, 255, 255, 0.08) !important;
}

.tools-strip .magic-item.active {
    background-color: rgba(82, 139, 204, 0.08) !important;
}

.tools-strip .magic-item.active .card-icon {
    background-color: rgba(82, 139, 204, 0.15);
}
.tools-strip .magic-item.active .card-icon svg {
    fill: var(--vk-blue, #528bcc);
    opacity: 1;
}

.tools-strip .magic-item-content {
    display: flex;
    flex-direction: row;
    align-items: center;
    justify-content: flex-start !important;
    width: 100%;
}

.tools-strip .card-icon {
    width: 28px;
    height: 28px;
    flex-shrink: 0;
    padding: 5px;
    background-color: var(--accent-color, rgba(var(--ui-bg-rgb), 0.1));
    border-radius: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: background-color 0.2s;
}

.tools-strip .card-icon svg {
    width: 100%;
    height: 100%;
    fill: #ffffff;
    opacity: 0.8;
    transition: fill 0.2s, opacity 0.2s;
}
</style>
