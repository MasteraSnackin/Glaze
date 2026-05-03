<script setup>
import DialogList from '@/views/DialogList.vue';
import ToolStripTooltip from '@/components/ToolStripTooltip.vue';
import { currentLang } from '@/core/config/APPSettings.js';
import { translations } from '@/utils/i18n.js';
import { useSidebarResizer } from '@/composables/ui/useSidebarResizer.js';
import { attachHoverGlow } from '@/core/services/interactionEffects.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { publishAppEvent } from '@/core/events/eventHub.js';
import { computed } from 'vue';

const props = defineProps({
    currentView: String,
    activeCategories: Object,
    isDesktopFloating: Boolean,
    isGlossaryOpen: Boolean
});

const emit = defineEmits(['update:currentView', 'openChat']);

function handleGlossaryToggle() {
    publishAppEvent(APP_EVENTS.ui.glossary.toggle);
}

const t = (key) => translations[currentLang.value]?.[key] || key;

const { width: leftSidebarWidth, collapsed, startResize: startLeftResize } = useSidebarResizer('gz_left_sidebar_width', 280, 'left', 200, 600);

const vHoverGlow = {
    mounted: (el) => {
        attachHoverGlow(el);
    }
};

// Tooltip items for collapsed mode
const leftSidebarItems = computed(() => [
    { id: 'characters', label: t('tab_characters'), icon: 'M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z' },
    { id: 'glossary', label: t('menu_glossary'), icon: 'M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-6h2v6zm0-8h-2V7h2v2z' },
    { id: 'more', label: t('tab_more'), icon: 'M3 18h18v-2H3v2zm0-5h18v-2H3v2zm0-7v2h18V6H3z' }
]);
</script>

<template>
  <div class="desktop-sidebar-left" :class="{ 'sidebar-collapsed': collapsed }" :style="{ width: leftSidebarWidth + 'px', minWidth: leftSidebarWidth + 'px', maxWidth: leftSidebarWidth + 'px' }">
      <div class="sidebar-drag-handle left-handle" @mousedown="startLeftResize"></div>

      <ToolStripTooltip :items="leftSidebarItems" placement="right">
          <template #default="{ onItemEnter, onItemLeave }">
              <div 
                  class="desktop-chars-btn" 
                  :class="{ active: currentView === 'view-characters' }" 
                  data-tooltip-id="characters"
                  v-hover-glow 
                  @click="emit('update:currentView', 'view-characters')"
                  @mouseenter="(e) => collapsed ? onItemEnter('characters', e) : null"
                  @mouseleave="collapsed ? onItemLeave() : null"
              >
                  <svg viewBox="0 0 24 24"><path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"/></svg>
                  <span v-if="!collapsed">{{ t('tab_characters') }}</span>
              </div>

              <div class="desktop-dialogs-wrapper">
                  <DialogList
                      :active-category="activeCategories['view-dialogs']"
                      :collapsed="collapsed"
                      @open-chat="emit('openChat', $event)"
                  />
              </div>

              <div class="desktop-sidebar-nav">
                  <div 
                      class="desktop-more-btn" 
                      :class="{ active: isGlossaryOpen }" 
                      data-tooltip-id="glossary"
                      v-hover-glow 
                      @click="handleGlossaryToggle"
                      @mouseenter="(e) => collapsed ? onItemEnter('glossary', e) : null"
                      @mouseleave="collapsed ? onItemLeave() : null"
                  >
                      <svg viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-6h2v6zm0-8h-2V7h2v2z"/></svg>
                      <span v-if="!collapsed">{{ t('menu_glossary') }}</span>
                  </div>
                  <div 
                      class="desktop-more-btn" 
                      :class="{ active: isDesktopFloating && currentView !== 'view-glossary' }" 
                      data-tooltip-id="more"
                      v-hover-glow 
                      @click="emit('update:currentView', 'view-menu')"
                      @mouseenter="(e) => collapsed ? onItemEnter('more', e) : null"
                      @mouseleave="collapsed ? onItemLeave() : null"
                  >
                      <svg viewBox="0 0 24 24"><path d="M3 18h18v-2H3v2zm0-5h18v-2H3v2zm0-7v2h18V6H3z"/></svg>
                      <span v-if="!collapsed">{{ t('tab_more') }}</span>
                  </div>
              </div>
          </template>
      </ToolStripTooltip>
  </div>
</template>
