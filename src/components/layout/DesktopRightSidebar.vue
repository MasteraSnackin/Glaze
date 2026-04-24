<script setup>
import { ref, computed, watch, defineAsyncComponent } from 'vue';
import BottomSheet from '@/components/ui/BottomSheet.vue';
import MagicDrawer from '@/components/chat/MagicDrawer.vue';
import Tooltip from '@/components/ui/Tooltip.vue';
import { sidebarState } from '@/core/states/sidebarState.js';

const PresetView = defineAsyncComponent(() => import('@/views/PresetView.vue'));
const ApiView = defineAsyncComponent(() => import('@/views/ApiView.vue'));
const PersonasView = defineAsyncComponent(() => import('@/views/PersonasView.vue'));
const LorebookSheet = defineAsyncComponent(() => import('@/components/sheets/LorebookSheet.vue'));
const RegexSheet = defineAsyncComponent(() => import('@/components/sheets/RegexSheet.vue'));
const ToolsView = defineAsyncComponent(() => import('@/views/ToolsView.vue'));

const props = defineProps({
    bottomSheetState: Object,
    sidebarState: Object,
    activeChatCharObj: Object,
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
    'magic-glossary'
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
const hasSheet = computed(() => props.bottomSheetState.visible || props.sidebarState.isOccupied);

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
const toolStripItems = [
    { id: 'view-personas', label: 'Personas', icon: 'M19 3H5c-1.11 0-2 .9-2 2v14c0 1.1.89 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-7 3c1.66 0 3 1.34 3 3s-1.34 3-3 3-3-1.34-3-3 1.34-3 3-3zm6 12H6v-1c0-2 4-3.1 6-3.1s6 1.1 6 3.1v1z' },
    { id: 'view-presets', label: 'Presets', icon: 'M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6h-6V2zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z' },
    { id: 'view-api', label: 'API', icon: 'M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96z' },
    { id: 'view-lorebook', label: 'Lorebook', icon: 'M4 6H2v14c0 1.1.9 2 2 2h14v-2H4V6zm16-4H8c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-1 9H9V9h10v2zm-4 4H9v-2h6v2zm4-8H9V5h10v2z' },
    { id: 'view-regex', label: 'Regex', icon: 'M9.4 16.6L4.8 12l4.6-4.6L8 6l-6 6 6 6 1.4-1.4zm5.2 0l4.6-4.6-4.6-4.6L16 6l6 6-6 6-1.4-1.4z' },
];

const activeToolComponent = computed(() =>
    activeTool.value ? toolComponentMap[activeTool.value] : null
);

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
          'tools-mode': !isChat,
          'is-chat': isChat,
          'sidebar-collapsed': collapsed
      }"
      :style="{ width: rightSidebarWidth + 'px', minWidth: rightSidebarWidth + 'px', maxWidth: rightSidebarWidth + 'px' }"
  >
      <div class="sidebar-drag-handle right-handle" @mousedown="startRightResize"></div>

      <!-- ── Chat mode: MagicDrawer icon strip + BottomSheet ── -->
      <template v-if="isChat">
          <MagicDrawer
              :visible="true"
              :sidebar-mode="true"
              :icon-only="hasSheet || collapsed"
              :class="{ 'left-icon-strip': hasSheet && !collapsed }"
              :active-char="activeChatCharObj"
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
              @request-preview="() => {}"
              @close="() => {}"
          />

          <BottomSheet
               v-if="bottomSheetState.visible"
               v-bind="bottomSheetState"
               :sidebar-mode="true"
               @close="emit('closeBottomSheet')"
          />
      </template>

      <!-- ── Non-chat mode: Tools icon strip + ToolsView + tool sheets ── -->
      <template v-else>
          <!-- Collapsed: vertical tool icon strip mirroring MagicDrawer icon styling -->
          <template v-if="collapsed">
              <div class="tools-strip magic-drawer-sidebar icon-only">
                  <div class="drawer-content">
                      <Tooltip
                          v-for="item in toolStripItems"
                          :key="item.id"
                          :text="item.label"
                          placement="left"
                      >
                          <div
                              class="magic-item"
                              :class="{ active: activeTool === item.id }"
                              @click="openTool(item.id)"
                          >
                              <div class="magic-item-content">
                                  <div class="card-icon">
                                      <svg viewBox="0 0 24 24"><path :d="item.icon"/></svg>
                                  </div>
                              </div>
                          </div>
                      </Tooltip>
                  </div>
              </div>
          </template>

          <!-- Expanded: ToolsView background + active tool sheet -->
          <template v-else>
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
