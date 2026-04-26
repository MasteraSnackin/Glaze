<script setup>
import { ref, computed } from 'vue';
import SheetView from '@/components/ui/SheetView.vue';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';

const props = defineProps({
  breakdown: { type: Object, default: null },
  historyHidePreview: { type: Object, default: () => ({ count: 0, tokens: 0 }) },
  contextSegments: { type: Object, default: () => ({ used: [], reserve: null }) },
  contextLegendItems: { type: Array, default: () => [] },
  contextBreakdownItems: { type: Array, default: () => [] },
  shouldRecommendHide: { type: Boolean, default: false },
  historyUsagePercent: { type: Number, default: 0 },
  historyFillThreshold: { type: Number, default: 85 },
  historyHidePercent: { type: Number, default: 30 },
  isCalculating: { type: Boolean, default: false }
});

const emit = defineEmits(['close', 'back', 'hide-messages', 'save-settings']);
const t = (key) => translations[currentLang.value]?.[key] || key;

const sheet = ref(null);
const showSettings = ref(false);
const localFillThreshold = ref(85);
const localHidePercent = ref(30);

const used = computed(() => props.breakdown?.totalUsed || 0);
const safeContext = computed(() => props.breakdown?.safeContext || 0);
const remaining = computed(() => Math.max(0, props.breakdown?.remaining || 0));
const contextSize = computed(() => props.breakdown?.contextSize || safeContext.value);

const usedWidth = computed(() => {
  return 0; // Keeping for arbitrary compatibility if ever needed externally, but unreferenced internally
});

const combinedBreakdownItems = computed(() => {
  const items = props.contextBreakdownItems.map(item => {
    const legendItem = props.contextLegendItems.find(l => l.key === item.key);
    return {
      ...item,
      className: legendItem ? legendItem.className : ''
    };
  });

  const reserveKeys = ['lorebook', 'vectorLore', 'lorebookTotal', 'lorebookReserve'];
  const mainItems = items.filter(item => !reserveKeys.includes(item.key));
  const reserveItems = items.filter(item => reserveKeys.includes(item.key));

  return [...mainItems, ...reserveItems];
});

const hideButtonLabel = computed(() => {
  const count = props.historyHidePreview.count;
  return count ? `Hide top ${count}` : 'Hide top messages';
});

const sheetTitle = computed(() => showSettings.value ? 'Context Settings' : 'Context');

const flatSegments = computed(() => {
  const segments = [];
  const segmentsMap = new Map();

  (props.contextSegments.used || []).forEach(seg => {
    segmentsMap.set(seg.key, seg);
  });

  const reserve = props.contextSegments.reserve;
  if (reserve) {
    (reserve.used || []).forEach(seg => {
      segmentsMap.set(seg.key, seg);
    });
    if (reserve.remaining > 0) {
      segmentsMap.set('lorebookReserveEmpty', {
        key: 'lorebookReserveEmpty',
        percent: (reserve.remaining / contextSize.value) * 100,
        className: reserve.className
      });
    }
  }

  let usedSum = 0;
  segmentsMap.forEach(seg => {
    usedSum += seg.percent;
  });
  const globalEmptyPercent = Math.max(0, 100 - usedSum);

  const orderTemplate = props.contextBreakdownItems
    .map(item => item.key)
    .filter(key => !['lorebook', 'vectorLore', 'lorebookReserve'].includes(key));

  // 1. Main context items (at the top)
  orderTemplate.forEach(key => {
    if (segmentsMap.has(key)) {
      segments.push(segmentsMap.get(key));
      segmentsMap.delete(key);
    }
  });

  // 2. Empty space (in the middle, pushing reserve down)
  if (globalEmptyPercent > 0) {
    segments.push({
      key: 'globalEmpty',
      percent: globalEmptyPercent,
      className: ''
    });
  }

  // 3. Reserve items (pressed to the bottom)
  ['lorebook', 'vectorLore', 'lorebookReserveEmpty'].forEach(key => {
    if (segmentsMap.has(key)) {
      segments.push(segmentsMap.get(key));
      segmentsMap.delete(key);
    }
  });

  segmentsMap.forEach(seg => segments.push(seg));
  return segments;
});

function open() {
    showSettings.value = false;
    sheet.value?.open();
}

function onSheetClose() {
    emit('close');
}

function handleBack() {
    emit('back');
}

function close() {
    sheet.value?.close();
}

function openSettings() {
    localFillThreshold.value = props.historyFillThreshold;
    localHidePercent.value = props.historyHidePercent;
    showSettings.value = true;
}

function saveSettings() {
    emit('save-settings', { fillThreshold: localFillThreshold.value, hidePercent: localHidePercent.value });
    showSettings.value = false;
}

defineExpose({ open, close });
</script>

<template>
  <SheetView
    ref="sheet"
    :title="sheetTitle"
    :show-back="showSettings"
    :fit-content="false"
    @close="onSheetClose"
    @back="showSettings ? (showSettings = false) : handleBack()"
  >
    <!-- Loading/Error State -->
    <div v-if="isCalculating || !breakdown" class="tokenizer-loading">
      <div class="tokenizer-loading-icon">
        <svg viewBox="0 0 24 24"><path d="M11 17h2v-6h-2v6zm0-8h2V7h-2v2zm1-7C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2z"/></svg>
      </div>
      <p class="tokenizer-loading-text">
        Context calculation is taking longer than expected. Please check that your API settings are configured correctly and try again.
      </p>
    </div>

    <!-- Main Content -->
    <div v-else class="tokenizer-content">
      <template v-if="!showSettings">
        <!-- Summary KPIs -->
        <div class="tokenizer-summary">
          <div class="tokenizer-kpi">
            <strong>{{ used }}</strong>
            <span>used / {{ contextSize }}</span>
          </div>
          <div class="tokenizer-kpi">
            <strong>{{ remaining }}</strong>
            <span>remaining</span>
          </div>
          <div class="tokenizer-kpi">
            <strong>{{ historyUsagePercent }}%</strong>
            <span>history fill</span>
          </div>
        </div>

        <!-- Unified Layout -->
        <div class="tokenizer-layout">
          <!-- Context Bar -->
          <div class="tokenizer-bar-container">
            <div class="tokenizer-bar">
              <div
                v-for="segment in flatSegments"
                :key="segment.key"
                class="tokenizer-segment"
                :class="segment.className"
                :style="{ height: `${segment.percent}%` }"
              />
            </div>
          </div>

          <!-- Breakdown List -->
          <div class="tokenizer-breakdown-list">
            <div
              v-for="(item, idx) in combinedBreakdownItems"
              :key="'item-' + idx"
              class="tokenizer-breakdown-row"
            >
              <div class="tokenizer-breakdown-row-left">
                <span v-if="item.className" class="tokenizer-legend-swatch" :class="item.className" />
                <span v-else class="tokenizer-legend-swatch-empty" />
                <span>{{ item.label }}</span>
              </div>
              <strong class="tokenizer-breakdown-value">{{ item.value }}</strong>
            </div>
          </div>
        </div>

        <!-- Recommendation -->
        <div v-if="shouldRecommendHide" class="tokenizer-recommendation">
          <div class="tokenizer-recommendation-title">
History is near its limit
</div>
          <div class="tokenizer-recommendation-text">
            Hide about {{ historyHidePreview.count }} top message{{ historyHidePreview.count === 1 ? '' : 's' }} to free about {{ historyHidePreview.tokens }} tokens.
          </div>
        </div>

        <!-- Actions -->
        <div class="tokenizer-actions">
          <button
            type="button"
            class="tokenizer-btn tokenizer-btn-primary"
            @click="$emit('hide-messages')"
          >
            {{ hideButtonLabel }}
          </button>
          <button
            type="button"
            class="tokenizer-btn tokenizer-btn-secondary"
            @click="openSettings"
          >
            Settings
          </button>
        </div>
      </template>

      <!-- Settings sub-view -->
      <template v-else>
        <div class="tokenizer-settings-item">
          <label>History fill threshold (%)</label>
          <input type="number" min="1" max="100" v-model.number="localFillThreshold">
        </div>
        <div class="tokenizer-settings-item">
          <label>Hide top messages (%)</label>
          <input type="number" min="1" max="95" v-model.number="localHidePercent">
        </div>
        <p class="tokenizer-recommendation-text">
Hide top messages recommendation appears when visible history reaches the configured threshold.
</p>
        <div class="tokenizer-actions">
          <button type="button" class="tokenizer-btn tokenizer-btn-secondary" @click="showSettings = false">
Back
</button>
          <button type="button" class="tokenizer-btn tokenizer-btn-primary" @click="saveSettings">
Save
</button>
        </div>
      </template>
    </div>
  </SheetView>
</template>

<style scoped>
/* Loading State */
.tokenizer-loading {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  padding: 40px 20px;
  text-align: center;
}

.tokenizer-loading-icon {
  width: 64px;
  height: 64px;
  color: var(--warning-color, #ffb84d);
  margin-bottom: 16px;
}

.tokenizer-loading-icon svg {
  width: 100%;
  height: 100%;
  fill: currentColor;
}

.tokenizer-loading-text {
  color: var(--text-gray);
  font-size: 14px;
  line-height: 1.5;
  max-width: 400px;
}

/* Main Content */
.tokenizer-content {
  display: flex;
  flex-direction: column;
  padding: 20px;
  gap: 20px;
}

/* Summary KPIs */
.tokenizer-summary {
  display: flex;
  gap: 16px;
  justify-content: space-around;
  padding: 16px;
  background: rgba(var(--ui-bg-rgb), 0.5);
  border-radius: 12px;
}

.tokenizer-kpi {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 4px;
}

.tokenizer-kpi strong {
  font-size: 24px;
  font-weight: 700;
  color: var(--text-black);
  line-height: 1;
}

.tokenizer-kpi span {
  font-size: 12px;
  color: var(--text-gray);
  text-align: center;
}

/* Layout Update */
.tokenizer-layout {
  display: flex;
  flex-direction: row;
  gap: 24px;
  align-items: stretch;
}

/* Vertical Context Bar */
.tokenizer-bar-container {
  display: flex;
  flex-direction: column;
  justify-content: flex-end;
  width: 48px; /* Narrower for a more elegant look */
  flex-shrink: 0;
  padding: 10px 0;
}

.tokenizer-bar {
  width: 100%;
  flex: 1;
  display: flex;
  flex-direction: column;
  border-radius: 12px;
  overflow: hidden;
  background: rgba(var(--ui-bg-rgb), 0.15);
  box-shadow: inset 1px 1px 2px rgba(255,255,255,0.05), inset -1px -1px 2px rgba(0,0,0,0.2);
  position: relative;
}

.tokenizer-bar::after {
  content: '';
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  height: 100%;
  background: linear-gradient(90deg, 
    rgba(255,255,255,0.05) 0%, 
    rgba(255,255,255,0.12) 20%, 
    rgba(255,255,255,0.02) 50%, 
    transparent 100%
  );
  pointer-events: none;
}

.tokenizer-segment {
  width: 100%;
  transition: height 0.3s cubic-bezier(0.4, 0, 0.2, 1);
  position: relative;
  box-shadow: inset 0 1px 0 rgba(255,255,255,0.1), inset 0 -1px 0 rgba(0,0,0,0.1);
}

/* Segment colors with cylindrical gradients */
.tokenizer-segment.segment-character, .tokenizer-legend-swatch.segment-character { 
  background: linear-gradient(to right, #ff6b6b, #e65b5b); 
}
.tokenizer-segment.segment-fixed, .tokenizer-legend-swatch.segment-fixed { 
  background: linear-gradient(to right, #4ecdc4, #3bb5ad); 
}
.tokenizer-segment.segment-summary, .tokenizer-legend-swatch.segment-summary { 
  background: linear-gradient(to right, #95e1d3, #7bcbc1); 
}
.tokenizer-segment.segment-memory, .tokenizer-legend-swatch.segment-memory { 
  background: linear-gradient(to right, #a8e6cf, #8ed1b9); 
}
.tokenizer-segment.segment-authors-note, .tokenizer-legend-swatch.segment-authors-note { 
  background: linear-gradient(to right, #ffd93d, #e6c135); 
}
.tokenizer-segment.segment-history, .tokenizer-legend-swatch.segment-history { 
  background: linear-gradient(to right, #6c5ce7, #5a4ccb); 
}
.tokenizer-segment.segment-lorebook-reserve, .tokenizer-legend-swatch.segment-lorebook-reserve { 
  background: linear-gradient(to right, #a8dadc, #8fc1c3); 
}
.tokenizer-segment.segment-lorebook, .tokenizer-legend-swatch.segment-lorebook { 
  background: linear-gradient(to right, #f4a261, #d68b4d); 
}
.tokenizer-segment.segment-vector-lore, .tokenizer-legend-swatch.segment-vector-lore { 
  background: linear-gradient(to right, #e76f51, #cb5d42); 
}

/* Breakdown List */
.tokenizer-breakdown-list {
  display: flex;
  flex-direction: column;
  gap: 8px;
  flex: 1;
  padding-right: 8px;
}

.tokenizer-breakdown-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 8px 12px;
  background: rgba(var(--ui-bg-rgb), 0.3);
  border-radius: 8px;
  font-size: 14px;
}

.tokenizer-breakdown-row-left {
  display: flex;
  align-items: center;
  gap: 8px;
  color: var(--text-gray);
}

.tokenizer-legend-swatch {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  flex-shrink: 0;
}

.tokenizer-legend-swatch-empty {
  width: 8px;
  height: 8px;
  flex-shrink: 0;
}

.tokenizer-breakdown-value {
  color: var(--text-black);
  font-weight: 600;
}

/* Recommendation */
.tokenizer-recommendation {
  padding: 16px;
  background: rgba(255, 184, 77, 0.1);
  border: 1px solid rgba(255, 184, 77, 0.3);
  border-radius: 12px;
}

.tokenizer-recommendation-title {
  font-weight: 600;
  color: var(--warning-color, #ffb84d);
  margin-bottom: 4px;
}

.tokenizer-recommendation-text {
  font-size: 14px;
  color: var(--text-gray);
}

/* Actions & Settings */
.tokenizer-actions {
  display: flex;
  gap: 12px;
  margin-top: 8px;
}

.tokenizer-btn {
  flex: 1;
  padding: 12px 16px;
  border: none;
  border-radius: 12px;
  font-size: 14px;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s;
  font-family: inherit;
}

.tokenizer-btn-primary {
  background: var(--accent-color, var(--vk-blue));
  color: white;
}

.tokenizer-btn-primary:active {
  opacity: 0.8;
}

.tokenizer-btn-secondary {
  background: rgba(var(--ui-bg-rgb), 0.5);
  color: var(--text-black);
  border: 1px solid rgba(255, 255, 255, 0.1);
}

.tokenizer-btn-secondary:active {
  opacity: 0.7;
}

.tokenizer-settings-item {
  display: flex;
  flex-direction: column;
  gap: 6px;
  margin-bottom: 14px;
}

.tokenizer-settings-item label {
  font-size: 14px;
  font-weight: 600;
  color: var(--text-black);
}

.tokenizer-settings-item input {
  padding: 10px 12px;
  border-radius: 12px;
  border: 1px solid rgba(255, 255, 255, 0.12);
  background: rgba(var(--ui-bg-rgb), 0.3);
  color: var(--text-black);
  font-size: 14px;
  font-family: inherit;
  outline: none;
}

@media (max-width: 600px) {
  .tokenizer-summary {
    gap: 12px;
  }

  .tokenizer-layout {
    gap: 16px;
    align-items: stretch;
  }
  
  .tokenizer-bar-container {
    width: 36px;
  }

  .tokenizer-actions {
    flex-direction: column;
  }
}
</style>
