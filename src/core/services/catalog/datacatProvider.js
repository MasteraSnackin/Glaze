/**
 * DataCat (datacat.run) provider.
 * Anonymous session via deviceToken → sessionToken.
 * All API calls go through catalogHttp (CapacitorHttp on native, corsproxy on web).
 */
import { catalogGet, catalogPost } from './catalogHttp.js';
import { ref } from 'vue';

const BASE = 'https://datacat.run';
const KEY_DEVICE = 'gz_dc_device';
const KEY_TOKEN = 'gz_dc_token';

// ─── Session ──────────────────────────────────────────────────────────────────

function getDeviceToken() {
    let token = localStorage.getItem(KEY_DEVICE);
    if (!token) {
        // Generate a UUID v4
        token = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
            const r = Math.random() * 16 | 0;
            return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
        });
        localStorage.setItem(KEY_DEVICE, token);
    }
    return token;
}

function getSessionToken() {
    return localStorage.getItem(KEY_TOKEN);
}

function setSessionToken(token) {
    localStorage.setItem(KEY_TOKEN, token);
}

/**
 * Initialize anonymous DataCat session. Stores sessionToken in localStorage.
 * @returns {Promise<string>} sessionToken
 */
export async function datacatInit() {
    const deviceToken = getDeviceToken();
    const data = await catalogPost(`${BASE}/api/liberator/identify`, { deviceToken }, {
        'Origin': 'https://datacat.run',
        'Referer': 'https://datacat.run/'
    });
    if (!data?.sessionToken) throw new Error('DataCat: no sessionToken in response');
    setSessionToken(data.sessionToken);
    return data.sessionToken;
}

/**
 * Returns a valid sessionToken, initializing if needed.
 */
async function getToken() {
    let token = getSessionToken();
    if (!token) token = await datacatInit();
    return token;
}

function authHeaders(token) {
    return {
        'X-Session-Token': token,
        'Origin': 'https://datacat.run',
        'Referer': 'https://datacat.run/'
    };
}

/**
 * Validate current session token.
 * @returns {Promise<boolean>}
 */
export async function datacatValidate() {
    const token = getSessionToken();
    if (!token) return false;
    try {
        await catalogGet(`${BASE}/api/characters/recent-public?limit=1&summary=1`, authHeaders(token));
        return true;
    } catch (e) {
        if (e.status === 401 || e.status === 403) {
            localStorage.removeItem(KEY_TOKEN);
            return false;
        }
        return true; // network error — assume still valid
    }
}

/**
 * Ensure session is valid; re-init if not.
 */
export async function datacatEnsureSession() {
    const valid = await datacatValidate();
    if (!valid) await datacatInit();
}

// ─── Browse / Search ──────────────────────────────────────────────────────────

const MIN_TOKENS = 889;

/**
 * Browse recent public characters.
 *
 * NOTE: /api/characters/recent-public does NOT support sortBy.
 * For 'popular', 'trending_week', or 'trending_24h', use datacatFresh() directly.
 *
 * @param {{ page?: number, limit?: number, tagIds?: number[], nsfw?: boolean, filters?: object }} opts
 */
export async function datacatBrowse({ page = 1, limit = 24, tagIds = [], nsfw = false, filters = {} } = {}) {
    const sort = filters.sort || 'recent';

    // Fresh-endpoint sorts (не поддерживают пагинацию — всегда page=1)
    if (sort !== 'recent') {
        const sortMap = {
            fresh: { sortBy: 'fresh', window: 'all' },
            score_week: { sortBy: 'score', window: 'thisWeek' },
            score_24h: { sortBy: 'score', window: 'last24h' },
            chat_count_week: { sortBy: 'chat_count', window: 'thisWeek' },
            chat_count_24h: { sortBy: 'chat_count', window: 'last24h' },
        };
        const mapped = sortMap[sort] || sortMap.fresh;
        const limit24 = mapped.window === 'last24h' || mapped.window === 'all' ? 80 : 0;
        const limitWeek = mapped.window === 'thisWeek' || mapped.window === 'all' ? 40 : 0;

        const isNsfw = filters.nsfw !== undefined ? filters.nsfw : nsfw;
        const res = await datacatFresh({ sortBy: mapped.sortBy, window: mapped.window, limit24, limitWeek, nsfw: isNsfw });
        return { characters: res.characters, total: res.total, hasMore: false };
    }

    // Recent sort — offset-based pagination
    const token = await getToken();
    const offset = (page - 1) * limit;
    const minTok = filters.minTokens ?? MIN_TOKENS;
    const isNsfw = filters.nsfw !== undefined ? filters.nsfw : nsfw;
    const filterTagIds = filters.tagIds?.length ? filters.tagIds : tagIds;

    const params = new URLSearchParams({
        limit: String(limit),
        offset: String(offset),
        summary: '1',
        minTotalTokens: String(minTok)
    });
    if (filters.maxTokens) params.set('maxTotalTokens', String(filters.maxTokens));
    if (filterTagIds.length) params.set('tagIds', filterTagIds.join(','));
    if (!isNsfw) params.set('blockedTagIds', '2');

    const data = await catalogGet(`${BASE}/api/characters/recent-public?${params}`, authHeaders(token));
    return {
        characters: (data.characters || []).map(normalizeListItem),
        total: data.totalCount || 0,
        hasMore: undefined  // вычислится стандартно в catalogState
    };
}

/**
 * Get trending/fresh characters.
 *
 * @param {{ sortBy?: 'score'|'fresh'|'chat_count', window?: 'all'|'last24h'|'thisWeek', limit24?: number, limitWeek?: number }} opts
 *   sortBy='score'      → DataCat AI scoring (trending)
 *   sortBy='chat_count' → most chatted (popular)
 *   sortBy='fresh'      → newest within each window
 *   window='all'        → merge both windows (default)
 *   window='last24h'    → only last 24h characters
 *   window='thisWeek'   → only this week characters
 * @returns {{ characters: CatalogItem[], total: number }}
 */
export async function datacatFresh({ sortBy = 'score', window = 'all', limit24 = 80, limitWeek = 40, nsfw = true } = {}) {
    const token = await getToken();
    let url = `${BASE}/api/characters/fresh?summary=1&sortBy=${sortBy}&limit24=${limit24}&limitWeek=${limitWeek}`;
    if (!nsfw) url += '&blockedTagIds=2';
    const data = await catalogGet(
        url,
        authHeaders(token)
    );

    const last24h = (data.windows?.last24h?.characters || []).map(normalizeListItem);
    const thisWeek = (data.windows?.thisWeek?.characters || []).map(normalizeListItem);

    if (window === 'last24h') {
        return { characters: last24h, total: last24h.length };
    } else if (window === 'thisWeek') {
        return { characters: thisWeek, total: thisWeek.length };
    } else {
        // 'all': merge both, dedupe by id, sort by the requested criterion
        const seen = new Set();
        const merged = [];
        for (const c of [...thisWeek, ...last24h]) {
            if (!seen.has(c.id)) { seen.add(c.id); merged.push(c); }
        }
        return { characters: merged, total: merged.length };
    }
}

/**
 * Search characters by query.
 */
export async function datacatSearch({ query, page = 1, limit = 24, filters = {} } = {}) {
    const token = await getToken();
    const offset = (page - 1) * limit;
    const minTok = filters.minTokens ?? MIN_TOKENS;
    const isNsfw = filters.nsfw !== undefined ? filters.nsfw : false;
    const filterTagIds = filters.tagIds || [];

    const params = new URLSearchParams({
        limit: String(limit),
        offset: String(offset),
        summary: '1',
        minTotalTokens: String(minTok)
    });
    if (filters.maxTokens) params.set('maxTotalTokens', String(filters.maxTokens));
    if (!isNsfw) params.set('blockedTagIds', '2');
    if (filterTagIds.length) params.set('tagIds', filterTagIds.join(','));
    if (query) params.set('search', query);

    const data = await catalogGet(`${BASE}/api/characters/recent-public?${params}`, authHeaders(token));
    return {
        characters: (data.characters || []).map(normalizeListItem),
        total: data.totalCount || 0,
        hasMore: undefined
    };
}

// ─── Character Download ───────────────────────────────────────────────────────

/**
 * Download a character card in V2-like format and convert to Glaze schema.
 * @param {string} uuid
 * @returns {Promise<{ charData: object, avatarUrl: string }>}
 */
export async function datacatGetCharacter(uuid) {
    const token = await getToken();
    const ts = Date.now();
    const data = await catalogGet(
        `${BASE}/api/characters/${uuid}/download?t=${ts}&variant=janitor_core`,
        authHeaders(token)
    );

    const raw = data.data || data;
    const meta = data.metadata || {};
    return {
        charData: convertToGlaze(raw, meta),
        avatarUrl: resolveAvatarUrl(pickAvatarSource(raw, meta))
    };
}

// ─── JanitorAI Extraction ─────────────────────────────────────────────────────

const IDEMPOTENCY_KEY = () => 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
    const r = Math.random() * 16 | 0;
    return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
});

function detectExtractionSource(url) {
    if (/^https?:\/\/(?:www\.)?saucepan\.ai\/companion\//i.test(url)) return 'saucepan';
    return 'janitor';
}

async function datacatGetCharacterAvatar(uuid) {
    const token = await getToken();
    const ts = Date.now();
    const data = await catalogGet(
        `${BASE}/api/characters/${uuid}?t=${ts}`,
        authHeaders(token)
    );
    return resolveAvatarUrl(pickAvatarSource(data?.character || data || {}, data?.metadata || {}));
}

function buildExtractionRequest(url, publicFeed = true) {
    const idempotencyKey = IDEMPOTENCY_KEY();
    const source = detectExtractionSource(url);

    if (source === 'saucepan') {
        return {
            endpoint: `${BASE}/api/saucepan-extract/run`,
            body: {
                companion: url,
                extractHidden: false,
                includeSearch: true,
                alwaysReextract: false,
                netnsRole: 'general_scraper',
                sourceKind: 'one_off',
                sourceRef: idempotencyKey,
                vpnNamespace: 'general_scraper',
                idempotencyKey
            }
        };
    }

    return {
        endpoint: `${BASE}/api/character/smart-extract-v2`,
        body: {
            url,
            appearOnPublicFeed: publicFeed,
            useSeparateWorkerServer: true,
            inlinePostExtractCreatorProfile: true,
            idempotencyKey
        }
    };
}

async function datacatExtract(url, publicFeed = true) {
    const token = await getToken();
    const request = buildExtractionRequest(url, publicFeed);
    return catalogPost(
        request.endpoint,
        request.body,
        authHeaders(token)
    );
}

async function datacatExtractionStatus() {
    const token = await getToken();
    const ts = Date.now();
    const data = await catalogGet(`${BASE}/api/extraction/status?t=${ts}`, authHeaders(token));
    return {
        inProgress: data.inProgress || null,
        queue: data.queue || [],
        history: data.history || [],
        taskHistory: data.taskHistory || [],
        job: data.job || null,
        run: data.run || null,
        latestTerminalJob: data.latestTerminalJob || null
    };
}

/**
 * Submit a JanitorAI URL for DataCat extraction, poll until done, then fetch the card.
 * If the character already exists on DataCat, skips polling and downloads directly.
 *
 * @param {string} url  JanitorAI character URL
 * @param {object} opts
 * @param {function} opts.onDone          - called with { charData, avatarUrl, characterId }
 * @param {function} [opts.onError]       - called with Error on failure or timeout
 * @param {function} [opts.onPhaseChange] - called with phase string during polling
 * @returns {function} cancel — stops polling and suppresses callbacks
 */
export function datacatExtractAndPoll(url, { onDone, onError, onPhaseChange } = {}) {
    let pollInterval = null;
    let cancelled = false;

    const cancel = () => {
        cancelled = true;
        if (pollInterval) { clearInterval(pollInterval); pollInterval = null; }
    };

    const finish = async (characterId) => {
        try {
            const result = await datacatGetCharacter(characterId);
            const fallbackAvatarUrl = !result.avatarUrl && detectExtractionSource(url) === 'saucepan'
                ? await datacatGetCharacterAvatar(characterId).catch(() => null)
                : null;
            const avatarUrl = result.avatarUrl || fallbackAvatarUrl;
            if (!cancelled) onDone?.({ charData: result.charData, avatarUrl, characterId });
        } catch (e) {
            if (!cancelled) onError?.(e);
        }
    };

    (async () => {
        try {
            const extractRes = await datacatExtract(url, true);
            if (cancelled) return;

            // Character already exists on DataCat — no polling needed
            if (extractRes?.characterId) {
                await finish(extractRes.characterId);
                return;
            }

            // New extraction queued — poll until terminal
            const myRequestId = extractRes?.requestId || null;
            const preStatus = await datacatExtractionStatus().catch(() => null);
            const prevRunId = preStatus?.run?.requestId || null;
            const UUID_RE = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;
            const targetUuid = url.match(UUID_RE)?.[0] || null;
            let attempts = 0;
            const MAX = 60;

            pollInterval = setInterval(async () => {
                if (cancelled) { clearInterval(pollInterval); return; }
                attempts++;
                if (attempts > MAX) {
                    clearInterval(pollInterval); pollInterval = null;
                    if (!cancelled) onError?.(new Error('Extraction timed out'));
                    return;
                }
                try {
                    const status = await datacatExtractionStatus();
                    if (cancelled) return;

                    const run = status.run;
                    onPhaseChange?.(status.inProgress?.phase || run?.phase || '');

                    let characterId = null;

                    if (myRequestId) {
                        if (run?.requestId === myRequestId && run?.lifecycle === 'terminal')
                            characterId = run.characterId || run.targetId;
                        if (!characterId) {
                            const th = status.taskHistory?.find(h => h.id === myRequestId && h.status === 'terminal');
                            if (th) characterId = th.target?.id;
                        }
                        if (!characterId) {
                            const h = status.history?.find(h => h.requestId === myRequestId);
                            if (h) characterId = h.characterId;
                        }
                    }

                    if (!characterId && run?.lifecycle === 'terminal' && run?.requestId !== prevRunId) {
                        if (!targetUuid || run.targetId === targetUuid)
                            characterId = run.characterId || run.targetId;
                    }

                    if (!characterId && targetUuid) {
                        const h = status.history?.find(h => h.url?.includes(targetUuid));
                        if (h?.characterId) characterId = h.characterId;
                    }

                    if (characterId) {
                        clearInterval(pollInterval); pollInterval = null;
                        await finish(characterId);
                    }
                } catch { }
            }, 3000);
        } catch (e) {
            if (!cancelled) onError?.(e);
        }
    })();

    return cancel;
}

// ─── Normalization ────────────────────────────────────────────────────────────

function stripEmoji(str) {
    if (!str) return str;
    return str.replace(/(?:[\u{1F300}-\u{1FFFF}\u{2600}-\u{27BF}\s]|\u{FE0F}|\u{200D})+/gu, '').trim();
}

const IMAGE_BASE = 'https://ella.janitorai.com/bot-avatars/';
const SAUCEPAN_CDN_BASE = 'https://cdn.saucepan.ai';

export const datacatTags = ref([]);
let _datacatTagsFetched = false;

export async function fetchDatacatTags() {
    if (_datacatTagsFetched) return datacatTags.value;
    try {
        const token = await getToken();
        // Uses the faceted endpoint provided for tags mapping
        const data = await catalogGet(
            `${BASE}/api/tags/faceted?mode=recent&blockedTagIds=2&limit=250&offset=0&sort=count&includeTagIds=2`,
            authHeaders(token)
        );

        if (data && data.tags && Array.isArray(data.tags)) {
            datacatTags.value = data.tags.map(t => ({ id: t.id, name: t.name, slug: t.slug }));
        }
        _datacatTagsFetched = true;
        return datacatTags.value;
    } catch (e) {
        console.warn('[datacat] Failed to fetch tags:', e);
        return datacatTags.value;
    }
}

function pickAvatarSource(raw = {}, meta = {}) {
    return raw.avatar
        || raw.image
        || raw.image_url
        || raw.avatar_url
        || raw.max_res_url
        || meta.image
        || meta.image_url
        || meta.avatar
        || meta.avatar_url
        || null;
}

function resolveAvatarUrl(url) {
    if (!url) return null;
    if (url.startsWith('http')) return url;
    if (url.startsWith('//')) return `https:${url}`;
    if (url.startsWith('/images/')) return `${SAUCEPAN_CDN_BASE}${url}`;
    if (url.startsWith('images/')) return `${SAUCEPAN_CDN_BASE}/${url}`;
    if (/^[0-9a-f-]+\/highres$/i.test(url)) return `${SAUCEPAN_CDN_BASE}/images/${url}`;
    if (url.startsWith('/')) return `https://ella.janitorai.com${url}`;
    if (!url.includes('/')) return IMAGE_BASE + url;
    return `https://ella.janitorai.com/${url}`;
}

function normalizeListItem(c) {
    const stdTags = (c.tags || []).map(t => (typeof t === 'string' ? stripEmoji(t) : stripEmoji(t.name))).filter(Boolean);
    const tags = [(c.is_nsfw || c.isNsfw) ? 'NSFW' : 'SFW', ...stdTags];

    return {
        // API returns character_id (UUID) as the primary identifier
        id: c.character_id || c.characterId || c.uuid || c.id,
        name: c.name || c.chat_name || c.chatName || 'Unknown',
        avatarUrl: resolveAvatarUrl(pickAvatarSource(c)),
        tags: [...new Set(tags)],
        tokens: c.total_tokens || c.totalTokens || 0,
        stats: { chat: c.chat_count || 0, message: c.message_count || 0 },
        creator: c.creator_name || c.creatorName || '',
        creator_id: c.creator_id || c.creatorId || '',
        nsfw: Boolean(c.is_nsfw || c.isNsfw),
        source: 'datacat'
    };
}

function convertToGlaze(raw, meta = {}) {
    const stdTags = (raw.tags || [])
        .map(t => (typeof t === 'string' ? stripEmoji(t) : stripEmoji(t?.name)))
        .filter(Boolean);

    const tags = [(raw.is_nsfw || raw.isNsfw) ? 'NSFW' : 'SFW', ...stdTags];

    return {
        name: raw.name || raw.chatName || raw.chat_name || 'Unknown',
        description: raw.personality || raw.description || '',
        personality: '',
        scenario: raw.scenario || '',
        first_mes: raw.first_mes || raw.first_message || '',
        mes_example: raw.mes_example || '',
        creator_notes: meta.raw_description_html || raw.creator_notes || raw.description || '',
        system_prompt: raw.system_prompt || '',
        post_history_instructions: raw.post_history_instructions || '',
        alternate_greetings: Array.isArray(raw.alternate_greetings) ? raw.alternate_greetings : [],
        tags: [...new Set(tags)],
        creator: meta.janitor_creator_name || raw.creator || '',
        creator_id: meta.janitor_creator_id || raw.creator_id || raw.creatorId || '',
        character_book: raw.character_book || null,
        extensions: { datacat: { id: raw.characterId || raw.character_id || raw.uuid || raw.id } }
    };
}
