<script setup>
import { ref, watch, computed, onMounted } from 'vue';
import BottomSheet from '@/components/ui/BottomSheet.vue';
import { catalogFilters, activeProvider } from '@/core/states/catalogState.js';
import { fetchDatacatTags, datacatTags } from '@/core/services/catalog/datacatProvider.js';
import { fetchJanitorTags, janitorTags } from '@/core/services/catalog/janitorProvider.js';
import { chubTags, fetchChubTags } from '@/core/services/catalog/chubProvider.js';
import { t } from '@/utils/i18n.js';

const useDatacatTags = computed(() => activeProvider.value === 'datacat');

function normalizeTag(rawTag) {
    if (typeof rawTag === 'string') {
        const name = rawTag.trim();
        return name ? { id: name, name } : null;
    }

    if (!rawTag || typeof rawTag !== 'object') return null;

    const rawName = rawTag.name ?? rawTag.slug ?? rawTag.id;
    const name = typeof rawName === 'string' ? rawName.trim() : String(rawName ?? '').trim();
    if (!name) return null;

    return {
        id: rawTag.id ?? name,
        name
    };
}

const ALL_TAGS = computed(() => {
    const source = activeProvider.value === 'chub'
        ? (chubTags.value || [])
        : (useDatacatTags.value ? datacatTags.value : janitorTags.value);

    return [...source]
        .map(normalizeTag)
        .filter(Boolean)
        .sort((a, b) => a.name.localeCompare(b.name));
});

onMounted(() => {
    fetchDatacatTags();
    fetchJanitorTags();
    fetchChubTags();
});

const props = defineProps({ visible: Boolean });
const emit = defineEmits(['update:visible', 'apply']);

const nsfw = ref(true);
const nsfl = ref(false);
const showNsflWarning = ref(false);
const minTokens = ref(29);
const maxTokens = ref(100000);
const selectedTagIds = ref(new Set());
const selectedTagNames = ref(new Set());
const selectedExcludeTagIds = ref(new Set());
const selectedExcludeTagNames = ref(new Set());
const tagSearch = ref('');

const isChub = computed(() => activeProvider.value === 'chub');

const filteredTags = computed(() => {
    const q = tagSearch.value.toLowerCase();
    return q
        ? ALL_TAGS.value.filter(t => t.name.toLowerCase().includes(q))
        : ALL_TAGS.value;
});

// Update global state AND trigger search ONLY when closing
watch(() => props.visible, (newVal, oldVal) => {
    // When opening: copy global state to local refs
    if (newVal) {
        const f = catalogFilters.value;
        nsfw.value = f.nsfw !== false;
        nsfl.value = f.nsfl === true;
        minTokens.value = f.minTokens ?? 29;
        maxTokens.value = f.maxTokens ?? 100000;
        selectedTagIds.value = new Set(f.tagIds || []);
        selectedTagNames.value = new Set(f.tagNames || []);
        selectedExcludeTagIds.value = new Set(f.excludeTagIds || []);
        selectedExcludeTagNames.value = new Set(f.excludeTagNames || []);
        tagSearch.value = '';
        // Refresh Chub tags when opening filters
        if (isChub.value) fetchChubTags();
    } 
    // When closing: save local refs to global state and trigger search
    else if (oldVal === true) {
        const f = catalogFilters.value;
        const currentTagIds = [...selectedTagIds.value].sort();
        const currentTagNames = [...selectedTagNames.value].sort();
        const currentExcludeTagIds = [...selectedExcludeTagIds.value].sort();
        const currentExcludeTagNames = [...selectedExcludeTagNames.value].sort();
        const oldTagIds = [...(f.tagIds || [])].sort();
        const oldTagNames = [...(f.tagNames || [])].sort();
        const oldExcludeTagIds = [...(f.excludeTagIds || [])].sort();
        const oldExcludeTagNames = [...(f.excludeTagNames || [])].sort();

        const changed = 
            nsfw.value !== (f.nsfw !== false) ||
            nsfl.value !== (f.nsfl === true) ||
            minTokens.value !== (f.minTokens ?? 29) ||
            maxTokens.value !== (f.maxTokens ?? 100000) ||
            JSON.stringify(currentTagIds) !== JSON.stringify(oldTagIds) ||
            JSON.stringify(currentTagNames) !== JSON.stringify(oldTagNames) ||
            JSON.stringify(currentExcludeTagIds) !== JSON.stringify(oldExcludeTagIds) ||
            JSON.stringify(currentExcludeTagNames) !== JSON.stringify(oldExcludeTagNames);

        if (changed) {
            catalogFilters.value = {
                ...catalogFilters.value,
                nsfw: nsfw.value,
                nsfl: nsfl.value,
                minTokens: minTokens.value,
                maxTokens: maxTokens.value,
                tagIds: [...selectedTagIds.value],
                tagNames: [...selectedTagNames.value],
                excludeTagIds: [...selectedExcludeTagIds.value],
                excludeTagNames: [...selectedExcludeTagNames.value]
            };
            emit('apply');
        }
    }
});

function tagState(tag) {
    // Returns 'include', 'exclude', or 'none'
    if (tag.id) {
        if (selectedTagIds.value.has(tag.id)) return 'include';
        if (selectedExcludeTagIds.value.has(tag.id)) return 'exclude';
        return 'none';
    } else {
        if (selectedTagNames.value.has(tag.name)) return 'include';
        if (selectedExcludeTagNames.value.has(tag.name)) return 'exclude';
        return 'none';
    }
}

function cycleTag(tag) {
    // Cycle: none → include → exclude → none
    const state = tagState(tag);
    if (tag.id) {
        const incSet = new Set(selectedTagIds.value);
        const excSet = new Set(selectedExcludeTagIds.value);
        if (state === 'none') {
            incSet.add(tag.id);
        } else if (state === 'include') {
            incSet.delete(tag.id);
            excSet.add(tag.id);
        } else {
            excSet.delete(tag.id);
        }
        selectedTagIds.value = incSet;
        selectedExcludeTagIds.value = excSet;
    } else {
        const incSet = new Set(selectedTagNames.value);
        const excSet = new Set(selectedExcludeTagNames.value);
        if (state === 'none') {
            incSet.add(tag.name);
        } else if (state === 'include') {
            incSet.delete(tag.name);
            excSet.add(tag.name);
        } else {
            excSet.delete(tag.name);
        }
        selectedTagNames.value = incSet;
        selectedExcludeTagNames.value = excSet;
    }
}

function isTagActive(tag) {
    return tagState(tag) !== 'none';
}

function clearTags() {
    selectedTagIds.value = new Set();
    selectedTagNames.value = new Set();
    selectedExcludeTagIds.value = new Set();
    selectedExcludeTagNames.value = new Set();
}

function closeSheet() {
    emit('update:visible', false);
}

function onNsflToggle() {
    if (!nsfl.value) {
        // Trying to enable — show warning
        showNsflWarning.value = true;
    } else {
        // Disabling — just toggle off
        nsfl.value = false;
    }
}

function confirmNsfl() {
    nsfl.value = true;
    showNsflWarning.value = false;
}

function cancelNsfl() {
    showNsflWarning.value = false;
}

const selectedTags = computed(() => {
    const res = [];
    ALL_TAGS.value.forEach(t => {
        const st = tagState(t);
        if (st !== 'none') {
            res.push({ ...t, state: st });
        }
    });
    return res;
});

const totalSelectedCount = computed(() => 
    selectedTagIds.value.size + selectedTagNames.value.size + 
    selectedExcludeTagIds.value.size + selectedExcludeTagNames.value.size
);
</script>

<template>
    <BottomSheet :visible="visible" :title="t('catalog_filters') || 'Filters'" @close="closeSheet" :popupOnDesktop="true" :popupWidth="360">
        <div class="filters-content">

            <!-- NSFW Toggle -->
            <div class="filter-section nsfw-row" style="margin-bottom: 5px;">
                <div class="filter-label" style="margin: 0;">
{{ t('catalog_filter_nsfw') || 'Show NSFW' }}
</div>
                <label class="toggle-switch">
                    <input type="checkbox" v-model="nsfw">
                    <span class="slider"></span>
                </label>
            </div>

            <!-- NSFL Toggle (Chub only) -->
            <div v-if="isChub" class="filter-section nsfw-row" style="margin-bottom: 5px;">
                <div class="filter-label" style="margin: 0;">
{{ t('catalog_filter_nsfl') || 'Show NSFL' }}
</div>
                <label class="toggle-switch" @click.prevent="onNsflToggle">
                    <input type="checkbox" :checked="nsfl">
                    <span class="slider nsfl-slider"></span>
                </label>
            </div>

            <!-- Tokens -->
            <div class="filter-section">
                <div class="filter-label">
{{ t('catalog_token_range') || 'Token Range' }}
</div>
                <div class="filter-row">
                    <div class="filter-input-wrap">
                        <span class="input-label">{{ t('catalog_min') || 'Min' }}</span>
                        <input type="number" v-model.number="minTokens" class="filter-input" />
                    </div>
                    <div class="filter-range-dash">
—
</div>
                    <div class="filter-input-wrap">
                        <span class="input-label">{{ t('catalog_max') || 'Max' }}</span>
                        <input type="number" v-model.number="maxTokens" class="filter-input" />
                    </div>
                </div>
            </div>

            <!-- Tag chips -->
            <div class="filter-section">
                <div class="filter-label-row">
                    <div class="filter-label">
{{ t('catalog_tags') || 'Tags' }}
</div>
                    <button v-if="totalSelectedCount > 0" class="clear-tags-btn" @click="clearTags">
                        {{ (t('catalog_clear_tags') || 'Clear ({count})').replace('{count}', totalSelectedCount) }}
                    </button>
                </div>

                <!-- Selected chips preview -->
                <TransitionGroup name="tag-list" tag="div" v-if="selectedTags.length" class="selected-tags-preview">
                    <span v-for="tag in selectedTags" :key="tag.id || tag.name" class="tag-chip" :class="{
                        active: tag.state === 'include',
                        excluded: tag.state === 'exclude'
                    }" @click="cycleTag(tag)">
                        {{ tag.name }}
                        <span class="chip-state-icon" v-if="tag.state === 'include'">✓</span>
                        <span class="chip-state-icon" v-else-if="tag.state === 'exclude'">✕</span>
                    </span>
                </TransitionGroup>

                <!-- Tag search input -->
                <input
                    type="text"
                    v-model="tagSearch"
                    :placeholder="t('catalog_search_tags') || 'Search tags...'"
                    class="filter-input tag-search"
                />

                <!-- Tags grid -->
                <TransitionGroup name="tag-list" tag="div" class="tags-grid">
                    <button
                        v-for="tag in filteredTags"
                        :key="tag.id || tag.name"
                        class="tag-chip"
                        :class="{
                            active: tagState(tag) === 'include',
                            excluded: tagState(tag) === 'exclude'
                        }"
                        @click="cycleTag(tag)"
                    >
                        {{ tag.name }}
                        <span class="chip-state-icon" v-if="tagState(tag) === 'include'">✓</span>
                        <span class="chip-state-icon" v-else-if="tagState(tag) === 'exclude'">✕</span>
                    </button>
                </TransitionGroup>
            </div>

        </div>
    </BottomSheet>

    <!-- NSFL Warning Sheet -->
    <BottomSheet :visible="showNsflWarning" :title="t('catalog_nsfl_warning_title') || 'NSFL Content'" @close="cancelNsfl" :popupOnDesktop="true" :popupWidth="320">
        <div class="nsfl-warning-content">
            <div class="nsfl-warning-icon">⚠️</div>
            <div class="nsfl-warning-desc">{{ t('catalog_nsfl_warning_desc') || "You don't want to see this." }}</div>
            <div class="nsfl-warning-actions">
                <button class="nsfl-btn nsfl-btn-confirm" @click="confirmNsfl">
                    {{ t('catalog_nsfl_btn') || 'I have nothing to lose' }}
                </button>
                <button class="nsfl-btn nsfl-btn-cancel" @click="cancelNsfl">
                    {{ t('catalog_nsfl_btn_cancel') || "I don't want to die" }}
                </button>
            </div>
        </div>
    </BottomSheet>
</template>

<style scoped>
.filters-content {
    padding: 0 16px 24px;
    display: flex;
    flex-direction: column;
    gap: 20px;
}

.filter-section {
    display: flex;
    flex-direction: column;
    gap: 10px;
}

.filter-row {
    display: flex;
    align-items: center;
    gap: 12px;
}

.filter-input-wrap {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 4px;
}

.filter-range-dash {
    color: rgba(255,255,255,0.3);
    padding-top: 20px;
    font-size: 18px;
}

.input-label {
    font-size: 11px;
    color: rgba(255,255,255,0.4);
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

.filter-label {
    font-size: 12px;
    font-weight: 600;
    color: rgba(255,255,255,0.5);
    text-transform: uppercase;
    letter-spacing: 0.6px;
}

.filter-label-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
}

.filter-input {
    width: 100%;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 10px;
    padding: 9px 12px;
    color: #fff;
    font-size: 14px;
    outline: none;
    transition: border-color 0.2s, background 0.2s;
    box-sizing: border-box;
}

.filter-input:focus {
    border-color: var(--vk-blue, #4080ff);
    background: rgba(255, 255, 255, 0.12);
}

.tag-search {
    margin-bottom: 6px;
}

.nsfw-row {
    flex-direction: row;
    justify-content: space-between;
    align-items: center;
    padding: 4px 0;
}

.toggle-switch {
    position: relative;
    display: inline-block;
    width: 44px;
    height: 24px;
}

.toggle-switch input {
    opacity: 0;
    width: 0;
    height: 0;
}

.slider {
    position: absolute;
    cursor: pointer;
    inset: 0;
    background: rgba(255, 255, 255, 0.15);
    transition: 0.3s;
    border-radius: 24px;
}

.slider:before {
    position: absolute;
    content: "";
    height: 18px;
    width: 18px;
    left: 3px;
    bottom: 3px;
    background: #fff;
    transition: 0.3s;
    border-radius: 50%;
}

input:checked + .slider {
    background: var(--vk-blue, #4080ff);
}

input:checked + .slider.nsfl-slider {
    background: #ff4444;
}

input:checked + .slider:before {
    transform: translateX(20px);
}

/* Tag chips */
.selected-tags-preview {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    padding: 4px 0;
    border-bottom: 1px solid rgba(255,255,255,0.06);
    padding-bottom: 10px;
}

.tags-grid {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    padding: 2px 0;
}

.tag-chip {
    padding: 6px 12px;
    border-radius: 20px;
    border: 1px solid rgba(255,255,255,0.12);
    background: rgba(255,255,255,0.05);
    color: rgba(255,255,255,0.65);
    font-size: 12px;
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s, color 0.15s;
    font-family: inherit;
    white-space: nowrap;
    display: flex;
    align-items: center;
    gap: 5px;
}

.tag-chip.active {
    background: rgba(var(--vk-blue-rgb, 64, 128, 255), 0.2);
    border-color: var(--vk-blue, #4080ff);
    color: #fff;
}

.tag-chip.excluded {
    background: rgba(255, 68, 68, 0.2);
    border-color: #ff4444;
    color: #ff4444;
}

.chip-state-icon {
    font-size: 10px;
    opacity: 0.8;
    font-weight: 700;
}

.clear-tags-btn {
    background: none;
    border: none;
    color: var(--vk-blue, #4080ff);
    font-size: 13px;
    cursor: pointer;
    padding: 0;
    font-family: inherit;
}

/* NSFL Warning */
.nsfl-warning-content {
    padding: 20px 16px 24px;
    display: flex;
    flex-direction: column;
    align-items: center;
    text-align: center;
    gap: 16px;
}

.nsfl-warning-icon {
    font-size: 48px;
    line-height: 1;
}

.nsfl-warning-desc {
    font-size: 15px;
    color: rgba(255, 255, 255, 0.8);
    line-height: 1.5;
}

.nsfl-warning-actions {
    display: flex;
    flex-direction: column;
    gap: 8px;
    width: 100%;
    margin-top: 4px;
}

.nsfl-btn {
    width: 100%;
    border: none;
    border-radius: 12px;
    padding: 12px;
    font-size: 14px;
    font-weight: 600;
    cursor: pointer;
    font-family: inherit;
    transition: opacity 0.2s, transform 0.1s;
}

.nsfl-btn:active {
    transform: scale(0.98);
    opacity: 0.9;
}

.nsfl-btn-confirm {
    background: #ff4444;
    color: #fff;
}

.nsfl-btn-cancel {
    background: rgba(255, 255, 255, 0.1);
    color: rgba(255, 255, 255, 0.7);
}

/* Transitions */
.tag-list-enter-active,
.tag-list-leave-active {
    transition: all 0.25s cubic-bezier(0.4, 0, 0.2, 1);
}

.tag-list-enter-from,
.tag-list-leave-to {
    opacity: 0;
    transform: scale(0.8);
}

/* Ensure smooth moving when others are added/removed */
.tag-list-move {
    transition: transform 0.25s cubic-bezier(0.4, 0, 0.2, 1);
}
</style>
