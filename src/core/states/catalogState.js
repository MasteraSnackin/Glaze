/**
 * Reactive state for the Character Catalog feature.
 * Manages provider selection, search results, pagination, and character import.
 */
import { ref, watch } from 'vue';
import { db } from '@/utils/db.js';
import { extractCharacterBook } from '@/utils/characterIO.js';
import { generateAllThumbnails } from '@/utils/thumbnailUtils.js';
import { datacatBrowse, datacatSearch, datacatEnsureSession } from '@/core/services/catalog/datacatProvider.js';
import { janitorHampterSearch, fetchJanitorTags } from '@/core/services/catalog/janitorProvider.js';
import { jannySearch } from '@/core/services/catalog/jannyProvider.js';
import { chubSearch } from '@/core/services/catalog/chubProvider.js';
import { Capacitor } from '@capacitor/core';
import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';

// ─── State ────────────────────────────────────────────────────────────────────

export const catalogResults = ref([]);
export const catalogLoading = ref(false);
export const catalogError = ref(null);
export const catalogPage = ref(1);
export const catalogHasMore = ref(true);
export const catalogQuery = ref('');
export const catalogTotal = ref(0);

const SORT_KEY = 'gz_catalog_sort';
const FILTERS_KEY = 'gz_catalog_filters';
const PROVIDER_KEY = 'gz_catalog_provider';

export const activeProvider = ref(localStorage.getItem(PROVIDER_KEY) || 'janitor');
watch(activeProvider, v => localStorage.setItem(PROVIDER_KEY, v));

const PROVIDER_SORT_DEFAULTS = {
    janitor: 'trending',
    janny: 'newest',
    datacat: 'recent',
    chub: 'popular'
};
export { PROVIDER_SORT_DEFAULTS };

export function setActiveProvider(id) {
    activeProvider.value = id;
    const saved = localStorage.getItem(`gz_catalog_sort_${id}`)
        || PROVIDER_SORT_DEFAULTS[id];
    catalogFilters.value = { ...catalogFilters.value, sort: saved, tagIds: [], tagNames: [] };
}

function loadSavedFilters() {
    try {
        const saved = JSON.parse(localStorage.getItem(FILTERS_KEY) || '{}');
        return {
            nsfw: saved.nsfw !== undefined ? saved.nsfw : false,
            nsfl: saved.nsfl !== undefined ? saved.nsfl : false,
            tagIds: Array.isArray(saved.tagIds) ? saved.tagIds : [],
            tagNames: Array.isArray(saved.tagNames) ? saved.tagNames : [],
            minTokens: saved.minTokens ?? 29,
            maxTokens: saved.maxTokens ?? 100000
        };
    } catch {
        return { nsfw: false, nsfl: false, tagIds: [], tagNames: [], minTokens: 29, maxTokens: 100000 };
    }
}

const savedFilters = loadSavedFilters();

const _initialProvider = localStorage.getItem(PROVIDER_KEY) || 'janitor';
const _initialSort = localStorage.getItem(`gz_catalog_sort_${_initialProvider}`)
    || localStorage.getItem(SORT_KEY)
    || PROVIDER_SORT_DEFAULTS[_initialProvider];

// Filters state
export const catalogFilters = ref({
    sort: _initialSort,
    ...savedFilters
});

watch(() => catalogFilters.value.sort, (v) => {
    localStorage.setItem(SORT_KEY, v);
    localStorage.setItem(`gz_catalog_sort_${activeProvider.value}`, v);
});
watch(catalogFilters, (v) => {
    localStorage.setItem(FILTERS_KEY, JSON.stringify({
        nsfw: v.nsfw,
        nsfl: v.nsfl,
        tagIds: v.tagIds,
        tagNames: v.tagNames,
        minTokens: v.minTokens,
        maxTokens: v.maxTokens
    }));
}, { deep: true });

// Extraction state (JanitorAI via DataCat)
export const extractionStatus = ref(null); // { inProgress, queuePosition, phase } | null
export const extractionLoading = ref(false);

// ─── Search / Browse ──────────────────────────────────────────────────────────

const PAGE_SIZE = 24;

/**
 * Load (or reload) the catalog. Pass reset=true to go back to page 1.
 */
export async function searchCatalog(reset = false) {
    if (catalogLoading.value) return;

    if (reset) {
        catalogPage.value = 1;
        catalogResults.value = [];
        catalogHasMore.value = true;
        catalogError.value = null;
    }

    if (!catalogHasMore.value) return;

    catalogLoading.value = true;
    catalogError.value = null;

    try {
        const query = catalogQuery.value.trim();
        const page = catalogPage.value;
        const filters = catalogFilters.value;
        const provider = activeProvider.value;

        if (provider === 'janitor' || provider === 'janny') {
            fetchJanitorTags().catch(() => { });
        }

        let result;

        if (provider === 'janitor') {
            result = await janitorHampterSearch({ query, page, filters });

        } else if (provider === 'janny') {
            // ТОЛЬКО MeiliSearch — никакого Hampter fallback
            result = await jannySearch({ query, page, filters });

        } else if (provider === 'datacat') {
            await datacatEnsureSession();
            if (query) {
                result = await datacatSearch({ query, page, limit: PAGE_SIZE, filters });
            } else {
                result = await datacatBrowse({ page, limit: PAGE_SIZE, filters });
            }

        } else if (provider === 'chub') {
            result = await chubSearch({ query, page, limit: PAGE_SIZE, filters });

        } else {
            result = await janitorHampterSearch({ query, page, filters });
        }

        // hasMore logic
        const items = result.characters || [];
        catalogResults.value = reset ? items : [...catalogResults.value, ...items];
        catalogTotal.value = result.total || 0;

        if (result.hasMore === false) {
            // Explicit false: провайдер сам сказал "больше нет" (DataCat fresh, Chub cursor)
            catalogHasMore.value = false;
        } else if (result.hasMore === true) {
            catalogHasMore.value = items.length > 0;
        } else {
            // undefined: стандартная логика по total
            catalogHasMore.value = items.length > 0 &&
                catalogResults.value.length < (result.total || Infinity);
        }

        catalogPage.value = page + 1;
    } catch (e) {
        catalogError.value = e.message || 'Failed to load catalog';
    } finally {
        catalogLoading.value = false;
    }
}

export async function loadMore() {
    await searchCatalog(false);
}

// ─── Character Import ─────────────────────────────────────────────────────────

/**
 * Import a character from catalog data into the app.
 * Downloads avatar, generates thumbnail, saves to IndexedDB.
 *
 * @param {object} charData - Glaze-compatible character object (from provider)
 * @param {string|null} avatarUrl - Remote avatar URL
 * @returns {Promise<string>} The saved character's id
 */
export async function importCharacter(charData, avatarUrl) {
    // Assign a numeric timestamp ID so CharacterList sort-by-date (parseInt(id)) works correctly
    charData.id = Date.now().toString();
    charData.updatedAt = Date.now();

    // Download and embed avatar
    if (avatarUrl) {
        try {
            const avatarBase64 = await fetchImageAsBase64(avatarUrl);
            charData.avatar = avatarBase64;
            const thumbs = await generateAllThumbnails(avatarBase64);
            charData.thumbnail = thumbs.thumbnail;
            charData.mini_thumbnail = thumbs.mini_thumbnail;
        } catch (e) {
            console.warn('[catalog] Failed to download avatar:', e.message);
            charData.avatar = null;
            charData.thumbnail = null;
        }
    }

    // Assign placeholder color if no avatar
    if (!charData.avatar) {
        charData.color = randomColor();
    }

    // Extract lorebook if present
    await extractCharacterBook(charData);

    // Save to IndexedDB
    await db.saveCharacter(charData, -1);

    // Notify CharacterList to refresh
    publishAppEvent(APP_EVENTS.domain.character.updated);

    return charData.id;
}

async function fetchImageAsBase64(url) {
    // Try direct fetch first (works on native due to CapacitorHttp... but for images
    // we use standard fetch since it returns a blob, not JSON)
    const res = await fetch(url);
    if (!res.ok) throw new Error(`Failed to fetch image: ${res.status}`);
    const blob = await res.blob();
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = reject;
        reader.readAsDataURL(blob);
    });
}

const COLORS = ['#66ccff', '#ff7eb3', '#a78bfa', '#34d399', '#fbbf24', '#f87171', '#60a5fa'];
function randomColor() {
    return COLORS[Math.floor(Math.random() * COLORS.length)];
}

// ─── Filters ──────────────────────────────────────────────────────────────────

export function resetFilters() {
    catalogFilters.value = {
        sort: PROVIDER_SORT_DEFAULTS[activeProvider.value] || 'latest',
        nsfw: false,
        nsfl: false,
        tagIds: [],
        tagNames: [],
        minTokens: 29,
        maxTokens: 100000
    };
}
