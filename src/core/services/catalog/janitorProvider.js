/**
 * JanitorAI (jannyai.com) provider.
 * Search via MeiliSearch API. Character details via HTML scrape (Astro island props).
 * Fallback search via Hampter API.
 */
import { catalogGet, catalogGetText, catalogPost } from './catalogHttp.js';
import { ref } from 'vue';

const HAMPTER_URL = 'https://janitorai.com/hampter/characters';
const BASE_URL = 'https://janitorai.com';

/**
 * Browse via Hampter API — used for 'trending' and 'popular' sort modes.
 *
 * CORS: janitorai.com/hampter returns Access-Control-Allow-Origin: *
 * so the request goes DIRECTLY (useProxy=false).
 *
 * @param {{ query?: string, page?: number, sort?: 'trending'|'popular', filters?: object }} opts
 */
export async function janitorHampterSearch({ query = '', page = 1, sort = 'trending', filters = {} } = {}) {
    let sortMode = 'trending';
    const activeSort = filters.sort || sort;

    if (activeSort === 'popular') sortMode = 'popular';
    else if (activeSort === 'trending_week') sortMode = 'trending';
    else if (activeSort === 'trending_24h') sortMode = 'trending24';
    else if (activeSort === 'newest') sortMode = 'latest';
    else sortMode = activeSort; // fallback to generic

    const params = new URLSearchParams({ sort: sortMode, page: String(page) });
    if (query) params.set('search', query);

    if (filters.nsfw === false) params.set('mode', 'sfw');
    else params.set('mode', 'all');

    // Add predefined tags
    if (filters.tagIds && filters.tagIds.length > 0) {
        for (const tagId of filters.tagIds) {
            params.append('tag_id[]', String(tagId));
        }
    }

    // Add custom string tags
    if (filters.tagNames && filters.tagNames.length > 0) {
        for (const tagName of filters.tagNames) {
            params.append('custom_tags[]', tagName);
        }
    }

    // useProxy=false: ACAO:* means direct fetch works fine
    const data = await catalogGet(`${HAMPTER_URL}?${params}`, {
        'Origin': 'https://janitorai.com',
        'Referer': 'https://janitorai.com/'
    }, false);

    const hits = Array.isArray(data) ? data : (data.characters || data.data || []);
    return {
        characters: hits.map(normalizeHampterHit),
        total: data.total || 0,
        totalPages: 1
    };
}

// ─── Character Details (HTML scrape) ─────────────────────────────────────────

/**
 * Fetch full character details from JanitorAI's Hampter endpoint.
 * Returns Glaze-compatible character data.
 * @param {string} id Character UUID
 */
export async function janitorFetchCharacter(id) {
    const url = `${HAMPTER_URL}/${id}`;

    // We can fetch directly without proxy since ACAO is * but we need standard headers
    const data = await catalogGet(url, {
        'Accept': 'application/json, text/plain, */*',
        'Origin': BASE_URL,
        'Referer': `${BASE_URL}/`
    }, false);

    return convertHampterToGlaze(data);
}

// ─── Normalization ────────────────────────────────────────────────────────────


export function resolveJanitorAvatar(url) {
    if (!url) return null;
    if (url.startsWith('http')) return url;
    if (url.startsWith('/')) return `https://ella.janitorai.com${url}?width=400`;
    // Filename (no slashes) → bot-avatars CDN path
    if (!url.includes('/')) return `https://ella.janitorai.com/bot-avatars/${url}?width=400`;
    return `https://ella.janitorai.com/${url}?width=400`;
}

// Default fallback JanitorAI tags
const FALLBACK_TAG_MAP = {
    1: '♂ Male', 2: '♀ Female', 3: '⚧ Non-binary', 4: '🌟 Celebrity', 5: '👤 OC',
    6: '📚 Fictional', 7: '🌍 Real', 8: '🎮 Game', 9: '🎌 Anime', 10: '📜 Historical',
    11: '👑 Royalty', 12: '🕵️ Detective', 13: '🦸 Hero', 14: '🦹 Villain', 15: '🪄 Magical',
    16: '🐾 Non-human', 17: '👾 Monster', 18: '👾 Monster Girl', 19: '🛸 Alien', 20: '🤖 Robot',
    21: '⚖️ Politics', 22: '🧛 Vampire', 23: '🏔️ Giant', 24: '🤖 OpenAI', 25: '🧝 Elf',
    26: '👥 Multiple', 27: '📱 VTuber', 28: '🖤 Dominant', 29: '🩶 Submissive', 30: '📖 Scenario',
    31: '📟 Pokemon', 32: '📎 Assistant', 34: '🌐 Non-English', 36: '🧠 Philosophy',
    38: '🎲 RPG', 39: '⛪ Religion', 41: '📖 Books', 42: '🎭 AnyPOV', 43: '🖤 Angst',
    44: '🦊 Demi-Human', 45: '⚔️ Enemies to Lovers', 46: '🔞 Smut', 47: '👨‍❤️‍👨 MLM',
    48: '👩‍❤️‍👩 WLW', 49: '💥 Action', 50: '💖 Romance', 51: '👻 Horror', 52: '🍰 Slice of Life',
    53: '🛡️ Fantasy', 54: '🎭 Drama', 55: '🤣 Comedy', 56: '🔍 Mystery', 57: '🚀 Sci-Fi',
    59: '🔪 Yandere', 60: '🐾 Furry', 61: '🎬 Movies/TV'
};

export const janitorTags = ref([]);
export const janitorTagMap = ref({ ...FALLBACK_TAG_MAP });

let _tagsFetched = false;

export async function fetchJanitorTags() {
    if (_tagsFetched) return janitorTags.value;
    try {
        const data = await catalogGet('https://janitorai.com/hampter/tags', {
            'Origin': 'https://janitorai.com',
            'Referer': 'https://janitorai.com/'
        }, false);

        if (Array.isArray(data) && data.length > 0) {
            janitorTags.value = data.map(t => ({ id: t.id, name: t.name, slug: t.slug }));
            const map = {};
            for (const t of data) map[t.id] = t.name;
            janitorTagMap.value = map;
        } else {
            janitorTags.value = Object.entries(FALLBACK_TAG_MAP).map(([id, name]) => ({ id: Number(id), name }));
        }
        _tagsFetched = true;
        return janitorTags.value;
    } catch (e) {
        if (janitorTags.value.length === 0) {
            janitorTags.value = Object.entries(FALLBACK_TAG_MAP).map(([id, name]) => ({ id: Number(id), name }));
        }
        return janitorTags.value;
    }
}

/**
 * Searches for characters to extract 'top_custom_tags' for autocomplete.
 * @param {string} query 
 */
export async function fetchJanitorTopTags(query) {
    if (!query) return [];
    try {
        const params = new URLSearchParams({
            page: '1',
            mode: 'all',
            sort: 'trending',
            search: query
        });
        const data = await catalogGet(`${HAMPTER_URL}?${params}`, {
            'Origin': 'https://janitorai.com',
            'Referer': 'https://janitorai.com/'
        }, false);

        return data.top_custom_tags || [];
    } catch (e) {
        console.warn('[janitor] Failed to fetch top tags:', e);
        return [];
    }
}



/**
 * Build a minimal Glaze charData from a normalized search hit (no full fetch needed).
 * Used as fallback when the character requires login.
 */
export function janitorItemToPartialCharData(item) {
    return {
        name: item.name,
        description: '',
        personality: '',
        scenario: '',
        first_mes: '',
        mes_example: '',
        creator_notes: item.description || '',
        system_prompt: '',
        post_history_instructions: '',
        alternate_greetings: [],
        tags: item.tags || [],
        creator: item.creator || '',
        creator_id: item.creator_id || '',
        character_book: null,
        extensions: { janitor: { id: item.id } }
    };
}

function normalizeHampterHit(hit) {
    let standardTags = [];
    if (Array.isArray(hit.tags)) {
        standardTags = hit.tags.map(t => typeof t === 'string' ? t : (t.name || t.slug))
            .map(t => String(t).trim())
            .filter(t => t && t.toLowerCase() !== 'limitless');
    } else {
        standardTags = tagIdsToNames(hit.tagIds || []).filter(t => t.toLowerCase() !== 'limitless');
    }

    const tags = [(hit.isNsfw || hit.is_nsfw) ? 'NSFW' : 'SFW', ...standardTags];

    if (hit.custom_tags && Array.isArray(hit.custom_tags)) {
        tags.push(...hit.custom_tags.map(t => `#${t}`));
    }

    const chatCount = hit.stats?.chat || hit.public_chat_count || 0;
    const msgCount = hit.stats?.message || hit.public_message_count || 0;

    return {
        id: hit.id,
        name: hit.name || hit.bot_name || 'Unknown',
        avatarUrl: resolveJanitorAvatar(hit.avatar || hit.image),
        description: hit.description || hit.short_description || '',
        tags: [...new Set(tags)],
        tokens: hit.totalToken || hit.total_tokens || 0,
        stats: { chat: chatCount, message: msgCount },
        creator: hit.creatorUsername || hit.creator || '',
        creator_id: hit.creator_id || hit.creatorId || '',
        nsfw: Boolean(hit.isNsfw || hit.is_nsfw),
        slug: hit.slug || hit.id,
        source: 'janitor'
    };
}

function convertHampterToGlaze(char) {
    let standardTags = [];
    if (Array.isArray(char.tags)) {
        standardTags = char.tags.map(t => typeof t === 'string' ? t : (t.name || t.slug))
            .map(t => String(t).trim())
            .filter(t => t && t.toLowerCase() !== 'limitless');
    } else {
        standardTags = tagIdsToNames(char.tagIds || []).filter(t => t.toLowerCase() !== 'limitless');
    }

    const tags = [(char.is_nsfw || char.isNsfw) ? 'NSFW' : 'SFW', ...standardTags];

    if (char.custom_tags && Array.isArray(char.custom_tags)) {
        tags.push(...char.custom_tags.map(t => `#${t}`));
    }

    // Preserve HTML/Markdown in description
    const desc = char.description || char.creator_notes || '';

    return {
        name: char.name || char.chat_name || 'Unknown',
        description: char.personality || char.description || '',
        personality: char.personality || '',
        scenario: char.scenario || '',
        first_mes: char.first_message || char.first_mes || '',
        mes_example: char.example_dialogs || char.mes_example || char.example_dialogs || '',
        creator_notes: desc,
        system_prompt: '',
        post_history_instructions: '',
        alternate_greetings: Array.isArray(char.first_messages) ? char.first_messages : [],
        tags: [...new Set(tags)],
        creator: char.creator_name || char.creator || '',
        creator_id: char.creator_id || '',
        character_book: null,
        extensions: { janitor: { id: char.id } }
    };
}


