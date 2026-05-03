/**
 * Chub.ai provider.
 * Browse/search via REST API. Character download via metadata API.
 * CORS: api.chub.ai returns Access-Control-Allow-Origin: * — direct fetch ok (useProxy=false).
 */
import { catalogGet } from './catalogHttp.js';
import { ref } from 'vue';

const API_BASE = 'https://api.chub.ai';
const AVATAR_BASE = 'https://avatars.charhub.io/avatars/';

const CHUB_HEADERS = {
    'Accept': 'application/json',
    'Origin': 'https://chub.ai',
    'Referer': 'https://chub.ai/'
};

// filters.sort → Chub API sort + optional max_days_ago
const SORT_MAP = {
    popular: { sort: 'download_count' },
    trending_week: { sort: 'download_count', max_days_ago: '7' },
    trending_24h: { sort: 'download_count', max_days_ago: '1' },
    latest: { sort: 'id' },
    rating: { sort: 'star_count' },
    updated: { sort: 'last_activity_at' }
};

// ─── Tags ────────────────────────────────────────────────────────────────────

export const chubTags = ref([]);
let _chubTagsFetched = false;
let _chubTagsLoading = false;

/**
 * Fetch popular ChubAI topics (tags) by aggregating
 * topics from top characters across multiple sort orders.
 * Mirrors the approach in SillyTavern's chub-browse.js.
 */
export async function fetchChubTags() {
    if (_chubTagsFetched || _chubTagsLoading) return chubTags.value;
    _chubTagsLoading = true;

    try {
        const sortOrders = ['download_count', 'id', 'star_count', 'default'];
        const PAGES_PER_SORT = 2;

        const results = await Promise.all(sortOrders.map(async (sortOrder) => {
            const chars = [];
            for (let page = 1; page <= PAGES_PER_SORT; page++) {
                try {
                    const params = new URLSearchParams({
                        search: '',
                        first: '200',
                        page: String(page),
                        sort: sortOrder,
                        nsfw: 'true',
                        nsfl: 'true',
                        include_forks: 'false',
                        min_tokens: '50'
                    });
                    const data = await catalogGet(`${API_BASE}/search?${params}`, CHUB_HEADERS, false);
                    const nodes = data.nodes || data.data?.nodes || [];
                    if (nodes.length === 0) break;
                    chars.push(...nodes);
                } catch {
                    break;
                }
            }
            return chars;
        }));

        const tagCounts = new Map();
        for (const chars of results) {
            for (const char of chars) {
                for (const tag of (char.topics || [])) {
                    const normalized = tag.toLowerCase().trim();
                    if (normalized && normalized.length > 1 && normalized.length < 40) {
                        tagCounts.set(normalized, (tagCounts.get(normalized) || 0) + 1);
                    }
                }
            }
        }

        const sortedTags = [...tagCounts.entries()]
            .sort((a, b) => b[1] - a[1])
            .slice(0, 600)
            .map(([tag]) => tag);

        if (sortedTags.length > 0) {
            chubTags.value = sortedTags.map(name => ({ name }));
        }

        _chubTagsFetched = true;
    } catch (e) {
        console.warn('[chub] Failed to fetch tags:', e);
    } finally {
        _chubTagsLoading = false;
    }

    return chubTags.value;
}

// ─── Browse / Search ──────────────────────────────────────────────────────────

/**
 * Browse or search characters on Chub.ai.
 * @param {{ query?: string, page?: number, limit?: number, filters?: object }} opts
 * @returns {{ characters: CatalogItem[], total: number, hasMore: boolean }}
 */
export async function chubSearch({ query = '', page = 1, limit = 24, filters = {} } = {}) {
    const sortEntry = SORT_MAP[filters.sort || 'popular'] || SORT_MAP.popular;
    const nsfw = filters.nsfw !== false;
    const minTokens = filters.minTokens ?? 50;

    const params = new URLSearchParams({
        first: String(limit),
        page: String(page),
        sort: sortEntry.sort,
        nsfw: String(nsfw),
        nsfl: String(filters.nsfl === true),
        include_forks: 'true',
        min_tokens: String(minTokens),
        venus: 'false'
    });

    if (sortEntry.max_days_ago) params.set('max_days_ago', sortEntry.max_days_ago);
    if (query) params.set('search', query);
    if (filters.maxTokens && filters.maxTokens < 100000) params.set('max_tokens', String(filters.maxTokens));

    // ChubAI uses 'topics' for include tags and 'excludetopics' for exclude tags
    // (both are comma-separated strings of tag names, matching SillyTavern's approach)
    const includeTags = filters.tagNames || [];
    const excludeTags = filters.excludeTagNames || [];

    if (includeTags.length > 0) {
        params.set('topics', includeTags.join(','));
    }
    if (excludeTags.length > 0) {
        params.set('excludetopics', excludeTags.join(','));
    }

    const data = await catalogGet(`${API_BASE}/search?${params}`, CHUB_HEADERS, false);

    const nodes = data.nodes || data.data?.nodes || [];
    return {
        characters: nodes.map(normalizeNode),
        total: data.total || nodes.length,
        hasMore: !!(data.data?.cursor ?? data.cursor)
    };
}

// ─── Character Download ───────────────────────────────────────────────────────

/**
 * Fetch full character data from Chub metadata API.
 * @param {string} fullPath - e.g. "creator/character-slug"
 * @returns {Promise<{ charData: object, avatarUrl: string }>}
 */
export async function chubGetCharacter(fullPath) {
    const data = await catalogGet(
        `${API_BASE}/api/characters/${fullPath}?full=true`,
        CHUB_HEADERS,
        false
    );
    const node = data.node || data;
    return {
        charData: convertToGlaze(node),
        avatarUrl: `${AVATAR_BASE}${fullPath}/avatar.webp`
    };
}

// ─── Normalization ────────────────────────────────────────────────────────────

function normalizeNode(node) {
    const fullPath = node.fullPath || node.full_path || '';
    const creator = fullPath.split('/')[0] || '';
    const nsfw = Boolean(node.nsfw || node.is_nsfw);

    const isTopicNsfw = (node.topics || []).some(t => String(t).toLowerCase() === 'nsfw');
    const cleanTopics = (node.topics || []).filter(t => {
        const lower = String(t).toLowerCase();
        return lower !== 'nsfw' && lower !== 'sfw';
    });

    return {
        id: fullPath,
        name: node.name || 'Unknown',
        avatarUrl: node.avatar_url || node.max_res_url || `${AVATAR_BASE}${fullPath}/avatar.webp`,
        description: node.tagline || '',
        tags: [isTopicNsfw ? 'NSFW' : 'SFW', ...cleanTopics],
        tokens: node.nTokens || node.n_tokens || 0,
        stats: { chat: node.nDownloads || 0, message: 0 },
        creator,
        creator_id: creator,
        nsfw,
        source: 'chub',
        fullPath
    };
}

function convertToGlaze(node) {
    const def = node.definition || {};
    const fullPath = node.fullPath || node.full_path || '';
    const creator = fullPath.split('/')[0] || '';
    const nsfw = Boolean(node.nsfw || node.is_nsfw);

    const isTopicNsfw = (node.topics || []).some(t => String(t).toLowerCase() === 'nsfw');
    const cleanTopics = (node.topics || []).filter(t => {
        const lower = String(t).toLowerCase();
        return lower !== 'nsfw' && lower !== 'sfw';
    });

    return {
        name: def.name || node.name || 'Unknown',
        description: def.personality || '',
        personality: def.tavern_personality || '',
        scenario: def.scenario || '',
        first_mes: def.first_message || '',
        mes_example: def.example_dialogs || '',
        creator_notes: def.description || node.tagline || '',
        system_prompt: def.system_prompt || '',
        post_history_instructions: def.post_history_instructions || '',
        alternate_greetings: def.alternate_greetings || [],
        tags: [isTopicNsfw ? 'NSFW' : 'SFW', ...cleanTopics],
        creator,
        creator_id: creator,
        character_book: def.embedded_lorebook || null,
        extensions: { chub: { fullPath, id: node.id } }
    };
}