<script setup>
import { ref, computed, watch } from 'vue';
import SheetView from '@/components/ui/SheetView.vue';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { showToast } from '@/core/states/toastState.js';
import { fetchRemoteModels } from '@/core/config/APISettings.js';
import { getActiveLLMProfile, SERVICE_NAMES } from '@/core/config/ProviderProfiles.js';
import { useServiceProviders } from '@/composables/api/useServiceProviders.js';

const {
    memoryProviderSettings,
    onMemoryProviderInput,
    openProviderSelector,
    getActiveProfileMeta,
    loadAllServiceSettings
} = useServiceProviders();

const props = defineProps({
  memoryBook: {
    type: Object,
    required: true
  },
  currentMessages: {
    type: Array,
    default: () => []
  },
  characterName: {
    type: String,
    default: ''
  },
  sessionId: {
    type: [String, Number],
    default: ''
  },
  memoryDraftState: {
    type: Object,
    default: () => ({ active: false, startedAt: 0, elapsedMs: 0, label: '' })
  },
  pendingMemoryMessageIds: {
    type: Set,
    default: () => new Set()
  }
});

const emit = defineEmits([
  'close',
  'back',
  'open-settings',
  'open-maintenance',
  'open-preview',
  'update-search-type',
  'reindex-all',
  'scan-chat',
  'batch-generate',
  'generate-draft',
  'delete-all-drafts',
  'approve-draft',
  'delete-draft',
  'delete-entry',
  'cancel-draft',
  'change-model',
  'flush-save'
]);

const sheet = ref(null);
const t = (key) => translations[currentLang.value]?.[key] || key;

// Computed properties
const vectorEnabled = computed(() => {
  return props.memoryBook?.settings?.vectorSearchEnabled !== false;
});

const memorySearchType = computed(() => {
  const settings = props.memoryBook?.settings || {};
  if (settings.vectorSearchEnabled === false) return 'keys';
  if ((settings.keyMatchMode || 'glaze') === 'both') return 'both';
  return 'vector';
});

const entries = computed(() => {
  return Array.isArray(props.memoryBook?.entries) ? props.memoryBook.entries : [];
});

const pendingDrafts = computed(() => {
  return Array.isArray(props.memoryBook?.pendingDrafts) ? props.memoryBook.pendingDrafts : [];
});

const stableConversationCount = computed(() => {
  return props.currentMessages.filter(m => 
    m && !m.isTyping && !m.isHidden && !m.isError && (m.role === 'user' || m.role === 'char')
  ).length;
});

const generationSettingsSummary = computed(() => {
  const interval = normalizeAutoCreateInterval(props.memoryBook);
  const autoCreate = props.memoryBook.settings?.autoCreateEnabled !== false ? t('memory_books_summary_auto_on') : t('memory_books_summary_auto_off');
  const autoGenerate = props.memoryBook.settings?.autoGenerateEnabled === true ? t('memory_books_summary_auto_text') : t('memory_books_summary_manual_text');
  const delayed = props.memoryBook.settings?.useDelayedAutomation !== false ? t('memory_books_summary_delayed') : t('memory_books_summary_immediate');
  const target = props.memoryBook.settings?.injectionTarget === 'summary_macro' ? '{{summary}}' : t('memory_books_summary_summary_block');
  const maxEntries = Math.max(1, Math.min(20, Number(props.memoryBook.settings?.maxInjectedEntries || 7)));
  const batchSize = Math.max(1, Math.min(50, Number(props.memoryBook.settings?.batchSize || 3)));
  const outputTokens = Number.isFinite(Number(props.memoryBook.settings?.generationMaxTokens)) && Number(props.memoryBook.settings?.generationMaxTokens) > 0
    ? `${Math.round(Number(props.memoryBook.settings.generationMaxTokens))} ${t('memory_books_summary_out')}`
    : t('memory_books_summary_auto_out');
  return `${interval} ${t('memory_books_summary_msgs')} • ${t('memory_books_summary_batch')} ${batchSize} • ${outputTokens} • ${autoCreate} • ${autoGenerate} • ${delayed} • ${target} • ${maxEntries} ${t('memory_books_summary_in_prompt')}`;
});

const statusSummary = computed(() => {
  return entries.value.reduce((acc, entry) => {
    const status = entry?.status === 'needs_rebuild' ? 'needs_rebuild' : 'active';
    acc[status] = (acc[status] || 0) + 1;
    return acc;
  }, { active: 0, needs_rebuild: 0 });
});

const staleCoverageCount = computed(() => {
  return props.currentMessages.filter(msg => msg?.memoryCoverage?.stale).length;
});

const keyMatchMode = computed(() => {
  const mode = props.memoryBook?.settings?.keyMatchMode || 'glaze';
  if (mode === 'glaze') return 'Glaze boundaries';
  if (mode === 'both') return 'Plain + Glaze';
  return 'Plain contains';
});

const draftsNeedingGeneration = computed(() => {
  return pendingDrafts.value.filter(d => !d.content && d.status === 'pending_generation' && !isDraftGenerating(d.id));
});

const uncoveredSegments = computed(() => {
  const coveredIds = new Set();
  for (const entry of entries.value) {
    if (Array.isArray(entry.messageIds)) entry.messageIds.forEach(id => coveredIds.add(id));
  }
  for (const draft of pendingDrafts.value) {
    if (Array.isArray(draft.messageIds)) draft.messageIds.forEach(id => coveredIds.add(id));
  }

  const stableMessages = props.currentMessages.filter(m =>
    m && !m.isTyping && !m.isHidden && !m.isError && (m.role === 'user' || m.role === 'char')
  );
  const uncovered = stableMessages.filter(m => m.id && !coveredIds.has(m.id));
  const interval = normalizeAutoCreateInterval(props.memoryBook);
  const segmentsNeeded = Math.floor(uncovered.length / interval);
  const remainder = uncovered.length % interval;

  return {
    count: uncovered.length,
    segmentsNeeded,
    interval,
    remainder
  };
});

const shouldEnableVectorSearch = computed(() => {
  // This should check embedding config - for now return true
  // Will be passed from parent
  return true;
});

const currentMemoryModelLabel = computed(() => {
  const settings = props.memoryBook?.settings || {};
  const isCustom = settings.generationSource === 'custom';
  if (isCustom) {
    return settings.generationModel || 'Custom endpoint';
  }
  return settings.generationModel || getActiveLLMProfile().model || 'Current LLM model';
});

async function openQuickModelSelector() {
  const settings = props.memoryBook?.settings || {};
  const isCustom = settings.generationSource === 'custom';
  let endpoint, key;
  if (isCustom) {
    endpoint = settings.generationEndpoint || '';
    key = settings.generationApiKey || '';
  } else {
    const profile = getActiveLLMProfile();
    endpoint = profile.endpoint || '';
    key = profile.apiKey || '';
  }

  if (!endpoint) {
    showToast(t('memory_books_endpoint_not_configured'));
    return;
  }

  showBottomSheet({
    title: t('memory_books_loading_models'),
    items: [{ label: t('memory_books_fetching_models'), onClick: () => {} }]
  });

  try {
    const models = await fetchRemoteModels(endpoint, key);
    const currentModel = settings.generationModel || '';
    const items = models.map(m => ({
      label: m,
      icon: currentModel === m ? '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>' : null,
      onClick: () => {
        closeBottomSheet();
        emit('change-model', m);
      }
    }));
    if (!models.length) {
      items.push({ label: t('memory_books_no_models'), onClick: closeBottomSheet });
    }
    items.push({
      label: t('memory_books_enter_model_manually'),
      onClick: () => {
        closeBottomSheet();
        setTimeout(() => {
          showBottomSheet({
            title: t('memory_books_enter_model_name'),
            input: {
              placeholder: t('memory_books_model_placeholder'),
              value: currentModel,
              confirmLabel: t('btn_save'),
              onConfirm: (value) => {
                closeBottomSheet();
                emit('change-model', value.trim());
              }
            }
          });
        }, 50);
      }
    });
    closeBottomSheet();
    setTimeout(() => showBottomSheet({ title: t('label_model'), items }), 50);
  } catch (e) {
    console.warn('Failed to fetch models for quick memory model switch:', e);
    closeBottomSheet();
    showToast(t('memory_books_no_models') + ': ' + (e.message || String(e)));
  }
}

// Helper functions
function normalizeAutoCreateInterval(memoryBook) {
  return Math.max(1, Math.min(200, Number(memoryBook?.settings?.autoCreateInterval || 15)));
}

function formatElapsedSeconds(ms) {
  const sec = Math.floor(ms / 1000);
  return `${sec}s`;
}

function formatGenerationTime(timestamp) {
  if (!timestamp) return '';
  const date = new Date(timestamp);
  const now = new Date();
  const diffMs = now - date;
  const diffMins = Math.floor(diffMs / 60000);
  if (diffMins < 1) return 'just now';
  if (diffMins < 60) return `${diffMins}m ago`;
  const diffHours = Math.floor(diffMins / 60);
  if (diffHours < 24) return `${diffHours}h ago`;
  const diffDays = Math.floor(diffHours / 24);
  if (diffDays < 7) return `${diffDays}d ago`;
  return date.toLocaleDateString();
}

function normalizeEntryMessageIds(entry) {
  return Array.isArray(entry?.messageIds) ? entry.messageIds : [];
}

function getDraftProgress(draftId) {
  if (!draftId) return null;
  return props.memoryDraftState?.activeDrafts?.[draftId] || null;
}

function isDraftGenerating(draftId) {
  return !!getDraftProgress(draftId);
}

// Event handlers
function open() {
  loadAllServiceSettings();
  sheet.value?.open();
}

// Called by SheetView @close event (user swiped down or tapped overlay)
function onSheetClose() {
  emit('flush-save');
  emit('close');
}

// Called programmatically from parent via ref (memoryBooksSheet.value.close())
function close() {
  emit('flush-save');
  sheet.value?.close();
}

function handleBack() {
  emit('back');
}

function handleOpenSettings() {
  emit('open-settings');
}

function handleOpenMaintenance() {
  emit('open-maintenance');
}

function handleReindexAll() {
  emit('reindex-all');
}

function handleScanChat() {
  emit('scan-chat');
}

function handleBatchGenerate() {
  emit('batch-generate');
}

function handleGenerateDraft(draftId) {
  console.debug('[MemoryBooksSheet] handleGenerateDraft', { draftId });
  emit('generate-draft', draftId);
}

function handleCancelDraft(draftId) {
  emit('cancel-draft', draftId);
}

function handleSearchTypeClick() {
  emit('update-search-type');
}

function handleEntryClick(entry) {
  emit('open-preview', { entry, kind: 'Memory Entry' });
}

function handleDraftClick(draft) {
  if (!draft?.content) return;
  emit('open-preview', { entry: draft, kind: 'Memory Draft' });
}

function handleApproveDraft(draftId) {
  emit('approve-draft', draftId);
}

function handleDeleteDraft(draftId) {
  emit('delete-draft', draftId);
}

function handleDeleteAllDrafts() {
  emit('delete-all-drafts');
}

function handleDeleteEntry(entryId) {
  emit('delete-entry', entryId);
}

defineExpose({ open, close });
</script>

<template>
  <SheetView
    ref="sheet"
    :title="t('magic_memory_books')"
    :show-back="true"
    :fit-content="false"
    @close="onSheetClose"
    @back="handleBack"
  >
    <div class="memory-books-content">
      <!-- Session Overview -->
      <div class="memory-session-overview">
        <div class="memory-session-overview-head">
          <div>
            <div class="memory-session-title">
{{ characterName }}
</div>
            <div class="memory-session-note">
{{ t('memory_books_session') }} {{ sessionId }}
</div>
          </div>
          <div class="memory-session-chip">
{{ stableConversationCount }} {{ t('memory_books_stable_msgs') }}
</div>
        </div>
        <div class="memory-session-overview-meta">
{{ generationSettingsSummary }}
</div>
        <div class="memory-quick-model-row" @click="openQuickModelSelector">
          <span class="memory-quick-model-label">{{ t('label_model') }}</span>
          <span class="memory-quick-model-value">{{ currentMemoryModelLabel }}</span>
          <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
        </div>
      </div>

      <div class="memory-settings-item">
        <label>{{ t('label_search_type') }}</label>
        <div class="memory-clickable-selector" @click="handleSearchTypeClick">
          <span>
            {{ memorySearchType === 'both' ? t('memory_books_search_combined') : memorySearchType === 'vector' ? t('memory_books_search_vector') : t('memory_books_search_keys') }}
          </span>
          <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
        </div>
        <div class="memory-note">{{ t('memory_books_search_type_note') }}</div>
      </div>
      <div v-if="!shouldEnableVectorSearch" class="memory-note">{{ t('memory_books_no_embeddings') }}</div>

      <!-- Status Summary -->
      <div class="memory-status-summary">
        <div class="memory-status-summary-item ok">
          <strong>{{ statusSummary.active || 0 }}</strong>
          <span>{{ t('memory_books_status_active') }}</span>
        </div>
        <div class="memory-status-summary-item warning">
          <strong>{{ statusSummary.needs_rebuild || 0 }}</strong>
          <span>{{ t('memory_books_status_needs_rebuild') }}</span>
        </div>
        <div class="memory-status-summary-item danger">
          <strong>{{ staleCoverageCount || 0 }}</strong>
          <span>{{ t('memory_books_status_stale') }}</span>
        </div>
        <div class="memory-status-summary-item draft">
          <strong>{{ pendingDrafts.length || 0 }}</strong>
          <span>{{ t('memory_books_status_drafts') }}</span>
        </div>
      </div>

      <!-- Action Buttons -->
      <div class="memory-actions">
        <button type="button" class="memory-btn memory-btn-secondary" @click="handleOpenSettings">
          {{ t('memory_books_btn_gen_settings') }}
        </button>
        <button type="button" class="memory-btn memory-btn-secondary" @click="handleOpenMaintenance">
          {{ t('memory_books_btn_maintenance') }}
        </button>
        <button
          type="button"
          class="memory-btn memory-btn-secondary"
          :disabled="!vectorEnabled"
          @click="handleReindexAll"
        >
          {{ t('memory_books_btn_reindex') }}
        </button>
        <button type="button" class="memory-btn memory-btn-primary" @click="close">
          {{ t('btn_close') }}
        </button>
      </div>

      <!-- Provider Settings -->
      <div class="memory-sheet-section" style="margin-bottom: 8px;">
        <div class="memory-sheet-section-head">
          <label>{{ t('memory_books_provider_config') }}</label>
        </div>
        <div class="memory-settings-item-checkbox">
            <div class="memory-settings-text-col">
                <label>{{ t('label_use_llm_api') || 'Use LLM API' }}</label>
                <div class="memory-settings-desc">
{{ t('desc_use_llm_api_memory') || 'Use the same endpoint as LLM for memory book generation' }}
</div>
            </div>
            <input type="checkbox" :checked="memoryProviderSettings.useSame" @change="onMemoryProviderInput('useSame', $event.target.checked)" class="vk-switch">
        </div>
        <template v-if="!memoryProviderSettings.useSame">
            <div class="memory-settings-item">
                <label>{{ t('label_memory_endpoint') || 'Memory Gen Endpoint' }}</label>
                <input type="text" :value="memoryProviderSettings.endpoint" @input="onMemoryProviderInput('endpoint', $event.target.value)" placeholder="http://127.0.0.1:5000/v1" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" style="width: 100%; border: 1px solid var(--border-color); background: var(--bg-item); padding: 12px; border-radius: 12px; color: var(--text-primary); font-size: 15px;">
            </div>
            <div class="memory-settings-item">
                <label>{{ t('label_memory_model') || 'Model' }}</label>
                <input type="text" :value="memoryProviderSettings.model" @input="onMemoryProviderInput('model', $event.target.value)" placeholder="gpt-4o-mini" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" style="width: 100%; border: 1px solid var(--border-color); background: var(--bg-item); padding: 12px; border-radius: 12px; color: var(--text-primary); font-size: 15px;">
            </div>
            <div class="memory-settings-item">
                <label>{{ t('label_memory_key') || 'API Key' }}</label>
                <input type="password" :value="memoryProviderSettings.key" @input="onMemoryProviderInput('apiKey', $event.target.value)" placeholder="sk-..." autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" style="width: 100%; border: 1px solid var(--border-color); background: var(--bg-item); padding: 12px; border-radius: 12px; color: var(--text-primary); font-size: 15px;">
            </div>
        </template>
      </div>

      <!-- Batch Actions (Scan & Generate) -->
      <div v-if="draftsNeedingGeneration.length > 0 || uncoveredSegments.count > 0" class="memory-batch-actions">
        <template v-if="draftsNeedingGeneration.length > 0 || memoryDraftState.active">
          <div class="memory-batch-info">
            <template v-if="memoryDraftState.active">
              <strong>{{ t('memory_books_batch_generating') }}</strong>
              <template v-if="memoryDraftState.activeCount > 1">
                {{ memoryDraftState.activeCount }} {{ t('memory_books_drafts_in_parallel') }}
              </template>
              <template v-else>
                {{ memoryDraftState.label || t('memory_books_draft_label') }}
              </template>
            </template>
            <template v-else>
              <strong>{{ draftsNeedingGeneration.length }}</strong> {{ draftsNeedingGeneration.length > 1 ? t('memory_books_drafts_need_gen').split('|')[1].trim() : t('memory_books_drafts_need_gen').split('|')[0].trim() }}
            </template>
          </div>
          <div class="memory-batch-buttons">
            <button
              type="button"
              class="memory-btn memory-btn-primary"
              :disabled="draftsNeedingGeneration.length === 0"
              @click.stop.prevent="handleBatchGenerate"
              @touchend.stop.prevent="handleBatchGenerate"
            >
              {{ memoryDraftState.active ? t('memory_books_btn_generate_remaining') : t('memory_books_btn_generate_batch') }}
            </button>
          </div>
        </template>
        <template v-else-if="uncoveredSegments.count > 0">
          <div class="memory-batch-info">
            <strong>{{ uncoveredSegments.count }}</strong> {{ t('memory_books_uncovered_msgs') }} ({{ uncoveredSegments.segmentsNeeded }} {{ t('memory_books_full_segments_of') }} {{ uncoveredSegments.interval }})
            <template v-if="uncoveredSegments.remainder > 0">
• {{ uncoveredSegments.remainder }} {{ t('memory_books_batch_left_over') }}
</template>
          </div>
          <div class="memory-batch-buttons">
            <button type="button" class="memory-btn memory-btn-secondary" :disabled="uncoveredSegments.segmentsNeeded === 0" @click.stop.prevent="handleScanChat" @touchend.stop.prevent="handleScanChat">
              {{ t('memory_books_btn_scan_chat') }}
            </button>
          </div>
        </template>
      </div>

      <!-- Pending Drafts Section -->
      <div v-if="pendingDrafts.length > 0" class="memory-sheet-section">
        <div class="memory-sheet-section-head">
          <label>{{ t('memory_books_section_pending') }}</label>
          <div class="memory-section-head-actions">
            <button type="button" class="memory-head-btn destructive" @click.stop.prevent="handleDeleteAllDrafts">
              {{ t('memory_books_delete_all_pending') }}
            </button>
            <span>{{ pendingDrafts.length }}</span>
          </div>
        </div>
        <div class="memory-entry-list">
          <div
            v-for="draft in pendingDrafts"
            :key="draft.id"
            class="memory-entry-card"
            :class="{ 'is-generating': isDraftGenerating(draft.id) }"
            @click="handleDraftClick(draft)"
          >
            <div class="memory-entry-head">
              <div>
                <div class="memory-entry-title">
{{ draft.title || t('memory_books_untitled_draft') }}
</div>
                <div class="memory-entry-meta">
                  <template v-if="isDraftGenerating(draft.id)">
                    <span style="color:#ffd700;">{{ t('memory_books_generating') }}</span>
                    <template v-if="getDraftProgress(draft.id)?.elapsedMs > 0">
• {{ formatElapsedSeconds(getDraftProgress(draft.id).elapsedMs) }}
</template>
                  </template>
                  <template v-else-if="!draft.content && draft.status === 'pending_generation'">
                    <span style="color:#ffd700;">{{ t('memory_books_needs_generation') }}</span>
                    <template v-if="draft.messageRange">
• {{ t('memory_books_msg_range') }} {{ draft.messageRange.start }}-{{ draft.messageRange.end }}
</template>
                  </template>
                  <template v-else>
                    <span>{{ t('memory_books_pending_approval') }}</span>
                    <template v-if="draft.generatedAt">
• {{ t('memory_books_generated_at') }} {{ formatGenerationTime(draft.generatedAt) }}
</template>
                  </template>
                  <template v-if="vectorEnabled && draft.content">
• {{ t('memory_books_badge_hybrid') }}
</template>
                  <template v-if="draft.keys && draft.keys.length && draft.content">
                    • {{ draft.keys.slice(0, 3).join(', ') }}
                  </template>
                </div>
              </div>
              <div class="memory-draft-actions" @click.stop>
                <span v-if="isDraftGenerating(draft.id)" class="memory-status-badge" style="background:rgba(255,215,0,0.1);color:#ffd700;">{{ t('memory_books_badge_generating') }}</span>
                <span v-else-if="!draft.content && draft.status === 'pending_generation'" class="memory-status-badge" style="background:rgba(255,215,0,0.1);color:#ffd700;">{{ t('memory_books_badge_needs_gen') }}</span>
                <span v-else class="memory-status-badge draft">{{ t('memory_books_badge_draft') }}</span>
                <span v-if="vectorEnabled" class="memory-status-badge vector">vec</span>
                <button
                  v-if="isDraftGenerating(draft.id)"
                  type="button"
                  class="memory-entry-delete"
                  @click.stop.prevent="handleCancelDraft(draft.id)"
                  @touchend.stop.prevent="handleCancelDraft(draft.id)"
                >
                  {{ t('memory_books_btn_stop') }}
                </button>
                <button
                  v-else-if="!draft.content && draft.status === 'pending_generation'"
                  type="button"
                  class="memory-entry-generate"
                  @click.stop.prevent="handleGenerateDraft(draft.id)"
                  @touchend.stop.prevent="handleGenerateDraft(draft.id)"
                >
                  {{ t('memory_books_btn_generate') }}
                </button>
                <button
                  v-else
                  type="button"
                  class="memory-entry-approve"
                  :disabled="!draft.content || isDraftGenerating(draft.id)"
                  @click.stop.prevent="handleApproveDraft(draft.id)"
                  @touchend.stop.prevent="handleApproveDraft(draft.id)"
                >
                  {{ t('memory_books_btn_approve') }}
                </button>
                <button
                  type="button"
                  class="memory-entry-delete"
                  @click.stop.prevent="handleDeleteDraft(draft.id)"
                  @touchend.stop.prevent="handleDeleteDraft(draft.id)"
                >
                  {{ t('btn_delete') }}
                </button>
              </div>
            </div>
            <div class="memory-entry-preview">
              <template v-if="draft.content">
                {{ draft.content.slice(0, 180) }}
              </template>
              <span v-else-if="isDraftGenerating(draft.id)" style="color:#ffd700;">{{ t('memory_books_generating_elapsed') }} {{ formatElapsedSeconds(getDraftProgress(draft.id)?.elapsedMs || 0) }}</span>
              <span v-else style="color:var(--text-gray);">{{ t('memory_books_no_content') }}</span>
            </div>
          </div>
        </div>
      </div>

      <!-- Approved Memories Section -->
      <div class="memory-sheet-section">
        <div class="memory-sheet-section-head">
          <label>{{ t('memory_books_section_approved') }}</label>
          <span>{{ entries.length }}</span>
        </div>
        <div v-if="entries.length > 0" class="memory-entry-list">
          <div
            v-for="entry in entries"
            :key="entry.id"
            class="memory-entry-card"
            :class="{ 'is-warning': entry.status === 'needs_rebuild' }"
            @click="handleEntryClick(entry)"
          >
            <div class="memory-entry-head">
              <div>
                <div class="memory-entry-title">
{{ entry.title || t('memory_books_untitled_memory') }}
</div>
                <div class="memory-entry-meta">
                  {{ entry.status === 'needs_rebuild' ? t('memory_books_entry_needs_rebuild') : t('memory_books_entry_active') }} • {{ normalizeEntryMessageIds(entry).length }} {{ t('memory_books_entry_messages') }}
                  {{ vectorEnabled ? ' • ' + t('memory_books_badge_hybrid') : ' • ' + t('memory_books_search_keys') }}
                  <template v-if="entry.keys && entry.keys.length">
                    • {{ entry.keys.slice(0, 3).join(', ') }}
                  </template>
                </div>
              </div>
              <div class="memory-status-badges">
                <span
                  class="memory-status-badge"
                  :class="entry.status === 'needs_rebuild' ? 'warning' : 'ok'"
                >
                  {{ entry.status === 'needs_rebuild' ? t('memory_books_entry_needs_rebuild') : t('memory_books_entry_active') }}
                </span>
                <span v-if="vectorEnabled" class="memory-status-badge vector">vec</span>
                <span v-if="entry.id" class="memory-status-badge indexed">idx</span>
              </div>
            </div>
            <div class="memory-entry-preview">
              {{ entry.content ? entry.content.slice(0, 180) : t('memory_books_entry_no_content') }}
            </div>
          </div>
        </div>
        <div v-else class="memory-note">
          {{ t('memory_books_no_entries') }}
        </div>
      </div>
    </div>
  </SheetView>
</template>

<style scoped>
.memory-books-content {
  display: flex;
  flex-direction: column;
  padding: 20px;
  gap: 16px;
}

/* Session Overview */
.memory-session-overview {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 16px;
  background: rgba(var(--ui-bg-rgb), 0.5);
  border-radius: 12px;
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
  transition: transform 0.1s ease, background-color 0.2s, opacity 0.2s;
  overflow: hidden;
}

.preset-selector:active {
  transform: scale(0.95);
  opacity: 0.8;
}

.preset-selector svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
}

.memory-session-overview-head {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
}

.memory-session-title {
  font-size: 16px;
  font-weight: 700;
  color: var(--text-black);
}

.memory-session-note {
  font-size: 12px;
  color: var(--text-gray);
  margin-top: 2px;
}

.memory-session-chip {
  padding: 4px 10px;
  background: rgba(var(--vk-blue-rgb), 0.1);
  color: var(--vk-blue);
  border-radius: 12px;
  font-size: 12px;
  font-weight: 600;
  white-space: nowrap;
}

.memory-session-overview-meta {
  font-size: 12px;
  color: var(--text-gray);
}

.memory-quick-model-row {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 10px 12px;
  background: rgba(var(--ui-bg-rgb), 0.3);
  border-radius: 10px;
  cursor: pointer;
  transition: all 0.2s;
  margin-top: 4px;
}

.memory-quick-model-row:active {
  opacity: 0.7;
}

.memory-quick-model-label {
  font-size: 11px;
  color: var(--text-gray);
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.02em;
}

.memory-quick-model-value {
  flex: 1;
  font-size: 13px;
  color: var(--text-black);
  font-weight: 500;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.memory-quick-model-row svg {
  width: 18px;
  height: 18px;
  fill: var(--text-gray);
  flex-shrink: 0;
}

/* Settings Items */
.memory-settings-item {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.memory-settings-item label {
  font-size: 14px;
  font-weight: 600;
  color: var(--text-black);
}

.memory-clickable-selector {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 12px 16px;
  background: rgba(var(--ui-bg-rgb), 0.5);
  border-radius: 12px;
  cursor: pointer;
  transition: all 0.2s;
}

.memory-clickable-selector:active {
  opacity: 0.7;
}

.memory-clickable-selector svg {
  width: 20px;
  height: 20px;
  fill: var(--text-gray);
}

.memory-settings-item-checkbox {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 16px;
}

.memory-settings-text-col {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.memory-settings-text-col label {
  font-size: 14px;
  font-weight: 600;
  color: var(--text-black);
}

.memory-settings-desc {
  font-size: 12px;
  color: var(--text-gray);
}

.memory-note {
  font-size: 12px;
  color: var(--text-gray);
  padding: 8px;
  background: rgba(var(--ui-bg-rgb), 0.3);
  border-radius: 8px;
}

/* Status Summary */
.memory-status-summary {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 12px;
}

.memory-status-summary-item {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 4px;
  padding: 12px;
  background: rgba(var(--ui-bg-rgb), 0.5);
  border-radius: 12px;
  border: 1px solid transparent;
}

.memory-status-summary-item.ok {
  border-color: rgba(76, 175, 80, 0.3);
}

.memory-status-summary-item.warning {
  border-color: rgba(255, 184, 77, 0.3);
}

.memory-status-summary-item.danger {
  border-color: rgba(255, 107, 107, 0.3);
}

.memory-status-summary-item.draft {
  border-color: rgba(255, 215, 0, 0.3);
}

.memory-status-summary-item strong {
  font-size: 20px;
  font-weight: 700;
  color: var(--text-black);
}

.memory-status-summary-item span {
  font-size: 11px;
  color: var(--text-gray);
  text-align: center;
}

/* Action Buttons */
.memory-actions {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 12px;
}

.memory-btn {
  padding: 12px 16px;
  border: none;
  border-radius: 12px;
  font-size: 14px;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s;
  font-family: inherit;
}

.memory-btn-primary {
  background: var(--accent-color, var(--vk-blue));
  color: white;
}

.memory-btn-primary:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.memory-btn-secondary {
  background: rgba(var(--ui-bg-rgb), 0.5);
  color: var(--text-black);
  border: 1px solid rgba(255, 255, 255, 0.1);
}

.memory-btn-secondary:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.memory-btn-destructive {
  background: rgba(255, 68, 68, 0.1);
  color: #ff4444;
  border: 1px solid rgba(255, 68, 68, 0.3);
}

.memory-btn-sm {
  padding: 4px 12px;
  font-size: 12px;
}

.memory-btn:active:not(:disabled) {
  opacity: 0.7;
}

/* Batch Actions */
.memory-batch-actions {
  display: flex;
  flex-direction: column;
  gap: 12px;
  padding: 16px;
  background: rgba(var(--ui-bg-rgb), 0.3);
  border-radius: 12px;
  border: 1px solid rgba(var(--vk-blue-rgb), 0.2);
}

.memory-batch-info {
  font-size: 14px;
  color: var(--text-gray);
}

.memory-batch-info strong {
  color: var(--text-black);
  font-weight: 700;
}

.memory-batch-buttons {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 12px;
}

/* Generation Status */
.memory-generation-status-card {
  padding: 16px;
  background: rgba(255, 215, 0, 0.1);
  border: 1px solid rgba(255, 215, 0, 0.3);
  border-radius: 12px;
}

.memory-generation-status-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.memory-generation-status-row strong {
  font-size: 14px;
  color: var(--text-black);
}

.memory-generation-status-row span {
  font-size: 12px;
  color: var(--text-gray);
  font-weight: 600;
}

/* Sections */
.memory-sheet-section {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.memory-sheet-section-head {
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.memory-sheet-section-head label {
  font-size: 16px;
  font-weight: 700;
  color: var(--text-black);
}

.memory-sheet-section-head span {
  font-size: 14px;
  font-weight: 600;
  color: var(--text-gray);
  padding: 4px 10px;
  background: rgba(var(--ui-bg-rgb), 0.5);
  border-radius: 12px;
}

.memory-section-head-actions {
  display: flex;
  align-items: center;
  gap: 8px;
}

.memory-head-btn {
  border: none;
  border-radius: 10px;
  padding: 6px 10px;
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
  font-family: inherit;
}

.memory-head-btn.destructive {
  background: rgba(255, 68, 68, 0.1);
  color: #ff4444;
  border: 1px solid rgba(255, 68, 68, 0.3);
}

/* Entry List */
.memory-entry-list {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.memory-entry-card {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 16px;
  background: rgba(var(--ui-bg-rgb), 0.5);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 12px;
  cursor: pointer;
  transition: all 0.2s;
}

.memory-entry-card:active {
  opacity: 0.7;
}

.memory-entry-card.is-warning {
  border-color: rgba(255, 184, 77, 0.3);
  background: rgba(255, 184, 77, 0.05);
}

.memory-entry-card.is-generating {
  border-color: rgba(255, 215, 0, 0.4);
  background: rgba(255, 215, 0, 0.05);
}

.memory-entry-head {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 12px;
}

.memory-entry-title {
  font-size: 14px;
  font-weight: 700;
  color: var(--text-black);
}

.memory-entry-meta {
  font-size: 12px;
  color: var(--text-gray);
  margin-top: 2px;
}

.memory-entry-preview {
  font-size: 13px;
  color: var(--text-gray);
  line-height: 1.4;
  overflow: hidden;
  text-overflow: ellipsis;
}

/* Status Badges */
.memory-status-badges {
  display: flex;
  gap: 6px;
  flex-wrap: wrap;
}

.memory-status-badge {
  padding: 4px 8px;
  border-radius: 8px;
  font-size: 11px;
  font-weight: 600;
  text-transform: uppercase;
  white-space: nowrap;
}

.memory-status-badge.ok {
  background: rgba(76, 175, 80, 0.1);
  color: #4caf50;
}

.memory-status-badge.warning {
  background: rgba(255, 184, 77, 0.1);
  color: #ffb84d;
}

.memory-status-badge.draft {
  background: rgba(255, 215, 0, 0.1);
  color: #ffd700;
}

.memory-status-badge.vector {
  background: rgba(139, 92, 246, 0.1);
  color: #8b5cf6;
}

.memory-status-badge.indexed {
  background: rgba(59, 130, 246, 0.1);
  color: #3b82f6;
}

/* Draft Actions */
.memory-draft-actions {
  display: flex;
  gap: 8px;
  align-items: center;
  position: relative;
  z-index: 3;
  pointer-events: auto;
}

.memory-entry-approve,
.memory-entry-delete,
.memory-entry-generate {
  padding: 6px 12px;
  border: none;
  border-radius: 8px;
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s;
  font-family: inherit;
  position: relative;
  z-index: 4;
  pointer-events: auto;
  touch-action: manipulation;
}

.memory-entry-approve {
  background: rgba(76, 175, 80, 0.1);
  color: #4caf50;
}

.memory-entry-generate {
  background: rgba(255, 215, 0, 0.15);
  color: #ffd700;
}

.memory-entry-generate:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.memory-entry-approve:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.memory-entry-delete {
  background: rgba(255, 68, 68, 0.1);
  color: #ff4444;
}

.memory-entry-approve:active:not(:disabled),
.memory-entry-delete:active,
.memory-entry-generate:active:not(:disabled) {
  opacity: 0.7;
}

@media (max-width: 600px) {
  .memory-status-summary {
    grid-template-columns: repeat(2, 1fr);
  }
  
  .memory-actions {
    grid-template-columns: 1fr;
  }
}
</style>
