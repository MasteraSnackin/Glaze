/**
 * JannyAI (jannyai.com) provider.
 * Search via MeiliSearch API. Character details via HTML scrape (Astro island props).
 */
import { catalogGetText, catalogPost } from './catalogHttp.js';
import { janitorTagMap } from './janitorProvider.js';

const SEARCH_URL = 'https://search.jannyai.com/multi-search';
const BASE_URL = 'https://jannyai.com';
const TOKEN_KEY = 'gz_janny_token';

// Hardcoded fallback token (changes rarely)
const FALLBACK_TOKEN = '88a6463b66e04fb07ba87ee3db06af337f492ce511d93df6e2d2968cb2ff2b30';

// JannyAI images CDN
const JANNY_IMAGE_CDN = 'https://image.jannyai.com/bot-avatars/';

// ─── Token Management ─────────────────────────────────────────────────────────

async function fetchSearchToken() {
    try {
        const html = await catalogGetText(`${BASE_URL}/characters/search`, {
            'Origin': BASE_URL,
            'Referer': `${BASE_URL}/`
        }, true);

        // Try client-config JS file first
        let configPath = null;
        const configMatch = html.match(/client-config\.[a-zA-Z0-9_-]+\.js/);
        if (configMatch) {
            configPath = `/_astro/${configMatch[0]}`;
        } else {
            // Fallback: look for SearchPage bundle which imports client-config
            const spMatch = html.match(/SearchPage\.[a-zA-Z0-9_-]+\.js/);
            if (spMatch) {
                const spJs = await catalogGetText(`${BASE_URL}/_astro/${spMatch[0]}`, {
                    'Referer': `${BASE_URL}/`
                }, true);
                const impMatch = spJs.match(/client-config\.[a-zA-Z0-9_-]+\.js/);
                if (impMatch) configPath = `/_astro/${impMatch[0]}`;
            }
        }

        if (configPath) {
            const configJs = await catalogGetText(`${BASE_URL}${configPath}`, {
                'Referer': `${BASE_URL}/`
            }, true);
            // Extract 64-char hex token
            const tokenMatch = configJs.match(/"([a-f0-9]{64})"/);
            if (tokenMatch) return tokenMatch[1];
        }

        return FALLBACK_TOKEN;
    } catch {
        return FALLBACK_TOKEN;
    }
}

async function getSearchToken() {
    const cached = localStorage.getItem(TOKEN_KEY);
    if (cached) return cached;

    const token = await fetchSearchToken();
    localStorage.setItem(TOKEN_KEY, token);
    return token;
}

function clearSearchToken() {
    localStorage.removeItem(TOKEN_KEY);
}

// ─── Search ───────────────────────────────────────────────────────────────────

const JANNY_HEADERS = (token) => ({
    'Accept': '*/*',
    'Authorization': `Bearer ${token}`,
    'Origin': BASE_URL,
    'Referer': `${BASE_URL}/`,
    'x-meilisearch-client': 'Meilisearch instant-meilisearch (v0.19.0) ; Meilisearch JavaScript (v0.41.0)'
});

function tagIdsToNames(tagIds) {
    if (!Array.isArray(tagIds)) return [];
    return tagIds.map(id => janitorTagMap.value[id]).filter(Boolean);
}

function stripHtml(html) {
    if (!html) return '';
    return html.replace(/<[^>]*>/g, '').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&=quot;/g, '"').replace(/&=#39;/g, "'").replace(/&amp;/g, '&');
}

function slugify(text) {
    if (!text) return '';
    return text.toString().toLowerCase()
        .replace(/\s+/g, '-')           // Replace spaces with -
        .replace(/[^\w-]+/g, '')       // Remove all non-word chars (except -)
        .replace(/--+/g, '-')         // Replace multiple - with single -
        .replace(/^-+/, '')             // Trim - from start of text
        .replace(/-+$/, '');            // Trim - from end of text
}

function resolveJannyAvatar(url) {
    if (!url) return null;
    if (url.startsWith('http')) return url;
    // Filename (no slashes) → jannyai image CDN path
    if (!url.includes('/')) return `${JANNY_IMAGE_CDN}${url}`;
    return url;
}

function decodeAstroValue(value) {
    if (!Array.isArray(value)) return value;
    const [type, data] = value;
    if (type === 0) {
        if (typeof data === 'object' && data !== null && !Array.isArray(data)) {
            const decoded = {};
            for (const [key, val] of Object.entries(data)) {
                decoded[key] = decodeAstroValue(val);
            }
            return decoded;
        }
        return data;
    } else if (type === 1) {
        return data.map(item => decodeAstroValue(item));
    }
    return data;
}

function normalizeJannyHit(hit) {
    const stdTags = tagIdsToNames(hit.tagIds);
    const tags = [hit.isNsfw ? 'NSFW' : 'SFW', ...stdTags];

    // JannyAI page URLs REQUIRE 'character-' prefix in the slug portion.
    // We must also slugify the name/slug to remove special characters (like slashes) that cause 404.
    let baseSlug = hit.slug || hit.name || hit.id;
    let slug = slugify(baseSlug);

    if (slug && !slug.startsWith('character-')) {
        slug = 'character-' + slug;
    }

    return {
        id: hit.id,
        name: hit.name || 'Unknown',
        avatarUrl: resolveJannyAvatar(hit.avatar),
        description: hit.description || '',
        tags: [...new Set(tags)],
        tokens: hit.totalToken || 0,
        creator: hit.creatorUsername || '',
        creator_id: hit.creatorId || '',
        nsfw: Boolean(hit.isNsfw),
        slug: slug,
        source: 'janny'
    };
}

export async function jannySearch({ query = '', page = 1, sort = 'newest', filters = {} } = {}) {
    let token = await getSearchToken();

    const meiliFilters = [];
    const minTok = filters.minTokens !== undefined ? filters.minTokens : 29;
    meiliFilters.push(`totalToken >= ${minTok}`);
    if (filters.maxTokens !== undefined) meiliFilters.push(`totalToken <= ${filters.maxTokens}`);
    if (filters.nsfw === false) meiliFilters.push('isNsfw = false');
    if (filters.tagIds?.length) {
        const tagClauses = filters.tagIds.map(id => `tagIds = ${id}`);
        meiliFilters.push(tagClauses.join(' AND '));
    }

    const activeSort = filters.sort || sort;
    const sortMap = {
        newest: ['createdAtStamp:desc'],
        oldest: ['createdAtStamp:asc'],
        tokens_desc: ['totalToken:desc'],
        tokens_asc: ['totalToken:asc'],
        relevant: [] // empty = MeiliSearch relevance ranking
    };
    const sortArr = sortMap[activeSort] ?? sortMap.newest;

    const body = {
        queries: [{
            indexUid: 'janny-characters',
            q: query,
            facets: ['isLowQuality', 'isNsfw', 'tagIds', 'totalToken'],
            attributesToCrop: ['description:300'],
            cropMarker: '...',
            filter: meiliFilters.length > 0 ? meiliFilters : undefined,
            attributesToHighlight: ['name', 'description'],
            hitsPerPage: 40,
            page
        }]
    };
    if (sortArr.length > 0) body.queries[0].sort = sortArr;

    try {
        const data = await catalogPost(SEARCH_URL, body, JANNY_HEADERS(token), false);
        const result = data.results?.[0] || {};
        return {
            characters: (result.hits || []).map(normalizeJannyHit),
            total: result.totalHits || 0,
            totalPages: result.totalPages || 1
        };
    } catch (e) {
        if (e.status === 401 || e.status === 403) {
            clearSearchToken();
            token = FALLBACK_TOKEN;
            const data = await catalogPost(SEARCH_URL, body, JANNY_HEADERS(token), false);
            const result = data.results?.[0] || {};
            return {
                characters: (result.hits || []).map(normalizeJannyHit),
                total: result.totalHits || 0,
                totalPages: result.totalPages || 1
            };
        }
        throw e;
    }
}

export async function jannyFetchCharacter(characterId, slug) {
    // Ensure slug has character- prefix and is cleaned up
    let effectiveSlug = slugify(slug || 'character');
    if (!effectiveSlug.startsWith('character-')) {
        effectiveSlug = 'character-' + effectiveSlug;
    }

    const url = `https://jannyai.com/characters/${characterId}_${effectiveSlug}`;
    const html = await catalogGetText(url, {
        'Origin': 'https://jannyai.com',
        'Referer': 'https://jannyai.com/',
        'Accept': 'text/html'
    }, true);

    let astroMatch = html.match(
        /astro-island[^>]*component-export="CharacterButtons"[^>]*props="([^"]+)"/
    );
    if (!astroMatch) {
        astroMatch = html.match(/astro-island[^>]*props="([^"]*character[^"]*)"/);
    }
    if (!astroMatch) throw new Error(`Could not parse JannyAI character page (404 or Cloudflare challenge)`);

    const propsDecoded = astroMatch[1]
        .replace(/&quot;/g, '"')
        .replace(/&amp;/g, '&')
        .replace(/&lt;/g, '<')
        .replace(/&gt;/g, '>')
        .replace(/&#39;/g, "'");

    const propsJson = JSON.parse(propsDecoded);
    const character = decodeAstroValue(propsJson.character);
    const imageUrl = decodeAstroValue(propsJson.imageUrl);

    let creatorUsername = null;
    const creatorMatch = html.match(/Creator:\s*(?:<\/[^>]+>\s*)?<a[^>]*>@?([^<]+)<\/a>/);
    if (creatorMatch) creatorUsername = creatorMatch[1].trim();

    const standardTags = tagIdsToNames(character.tagIds || []);
    const tags = [character.isNsfw ? 'NSFW' : 'SFW', ...standardTags];

    return {
        charData: {
            name: character.name || 'Unnamed',
            description: character.personality || '',
            personality: '',
            scenario: character.scenario || '',
            first_mes: character.firstMessage || '',
            mes_example: character.exampleDialogs || '',
            creator_notes: stripHtml(character.description || ''),
            system_prompt: '',
            post_history_instructions: '',
            alternate_greetings: [],
            tags: [...new Set(tags)],
            creator: creatorUsername || character.creatorId || '',
            creator_id: character.creatorId || '',
            character_book: null,
            extensions: { janny: { id: character.id } }
        },
        avatarUrl: imageUrl ? resolveJannyAvatar(imageUrl) : null
    };
}
