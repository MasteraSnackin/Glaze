import { reactive, watch } from 'vue';
import { db } from '@/utils/db.js';

export { scanLorebooks } from '@/core/services/lorebookSearchService.js';
export { vectorSearchLorebooks } from '@/core/services/lorebookVectorSearch.js';
export {
    indexLorebookEntry,
    indexLorebookEntries,
    getEmbeddingRecord,
    getEmbeddingStatus,
    isLorebookEmbeddingFresh,
    deleteLorebookEntryEmbedding,
    deleteLorebookEmbeddings,
    getEntryIndexingText,
    computeTextHash,
    buildEmbeddingFingerprint
} from '@/core/services/lorebookEmbeddingService.js';

// --- State Definition ---
export const lorebookState = reactive({
    lorebooks: [],
    globalSettings: {
        scanDepth: 10,
        maxInjectedEntries: 5,
        contextPercent: 100,
        budgetCap: 0,
        reserveMode: 'percent',
        reserveValue: 10,
        minActivations: 0,
        maxDepth: 0,
        maxRecursionSteps: 0,
        insertionStrategy: 'character_first',
        injectionPosition: 'worldInfoBefore',
        includeNames: true,
        recursiveScan: true,
        caseSensitive: false,
        matchWholeWords: false,
        useGroupScoring: false,
        alertOnOverflow: false,
        searchType: 'keys',
        embeddingTarget: 'content',
        vectorThreshold: 0.45,
        vectorTopK: 10,
        keywordVectorSplit: 50
    },
    activations: {
        character: {},
        chat: {}
    },
    initialized: false,
});

// --- Actions ---

export async function initLorebookState(force = false) {
    if (lorebookState.initialized && !force) return;
    try {
        const data = await db.get('gz_lorebooks');
        lorebookState.lorebooks = [];
        lorebookState.activations = { character: {}, chat: {} };
        if (data) {
            if (Array.isArray(data)) {
                lorebookState.lorebooks = data;
            } else if (data.lorebooks) {
                lorebookState.lorebooks = data.lorebooks;
                if (data.settings) {
                    if (data.settings.reserveMode === undefined) {
                        data.settings.reserveMode = 'percent';
                    }
                    if (data.settings.reserveValue === undefined) {
                        const legacyBudget = Number(data.settings.budgetCap || 0);
                        const legacyPercent = Number(data.settings.contextPercent || 0);
                        const effectivePercent = legacyPercent >= 100 ? 10 : Math.max(legacyPercent, 10);
                        data.settings.reserveValue = legacyBudget > 0 ? legacyBudget : effectivePercent;
                        if (legacyBudget <= 0 && legacyPercent > 0) {
                            data.settings.reserveMode = 'percent';
                        }
                    }
                    if (data.settings.reserveValue >= 100 &&
                        data.settings.reserveMode === 'percent' &&
                        (!data.settings.budgetCap || Number(data.settings.budgetCap) === 0) &&
                        Number(data.settings.contextPercent || 0) >= 100) {
                        data.settings.reserveValue = 10;
                    }
                    if (!data.settings.injectionPosition) {
                        data.settings.injectionPosition = 'worldInfoBefore';
                    }
                    if (!Number.isFinite(Number(data.settings.maxInjectedEntries)) || Number(data.settings.maxInjectedEntries) <= 0) {
                        data.settings.maxInjectedEntries = 5;
                    }
                    Object.assign(lorebookState.globalSettings, data.settings);
                }
                if (data.activations) {
                    lorebookState.activations = data.activations;
                }
            }

            lorebookState.lorebooks.forEach(lb => {
                if (!Array.isArray(lb.entries)) return;
                lb.entries.forEach(entry => {
                    if (!entry.id) {
                        entry.id = Date.now().toString(36) + Math.random().toString(36).substr(2, 5);
                    }
                    if (entry.position === 0) entry.position = 'worldInfoBefore';
                    if (entry.position === 1) entry.position = 'worldInfoAfter';
                    if (!entry.position) entry.position = 'matchGlobal';
                });
            });
        }
    } catch (e) {
        console.error('Failed to load lorebooks', e);
    }
    lorebookState.initialized = true;
}

export async function saveLorebooks() {
    await db.queuedSet('gz_lorebooks', {
        lorebooks: JSON.parse(JSON.stringify(lorebookState.lorebooks)),
        settings: JSON.parse(JSON.stringify(lorebookState.globalSettings)),
        activations: JSON.parse(JSON.stringify(lorebookState.activations))
    });
}

let _lorebookSaveTimer = null;
watch(() => lorebookState, () => {
    if (_lorebookSaveTimer) clearTimeout(_lorebookSaveTimer);
    _lorebookSaveTimer = setTimeout(() => {
        saveLorebooks();
        _lorebookSaveTimer = null;
    }, 500);
}, { deep: true });

export function flushLorebookSave() {
    if (_lorebookSaveTimer) {
        clearTimeout(_lorebookSaveTimer);
        _lorebookSaveTimer = null;
    }
    return saveLorebooks();
}

export function createLorebook(name = 'New World Info') {
    const newLb = {
        id: Date.now().toString(36) + Math.random().toString(36).substr(2, 5),
        name,
        entries: [],
        enabled: true,
        insertion_order: 100,
    };
    lorebookState.lorebooks.push(newLb);
    return newLb;
}

export function deleteLorebook(id) {
    const idx = lorebookState.lorebooks.findIndex(lb => lb.id === id);
    if (idx !== -1) {
        lorebookState.lorebooks.splice(idx, 1);
    }
}

export function setLorebookActivation(lbId, scope, targetId) {
    if (scope === 'global') {
        const lb = lorebookState.lorebooks.find(l => l.id === lbId);
        if (lb) lb.enabled = !lb.enabled;
    } else if (scope === 'character') {
        if (!lorebookState.activations.character) lorebookState.activations.character = {};
        if (!lorebookState.activations.character[targetId]) lorebookState.activations.character[targetId] = [];

        const list = lorebookState.activations.character[targetId];
        const idx = list.indexOf(lbId);
        if (idx === -1) list.push(lbId);
        else list.splice(idx, 1);
    } else if (scope === 'chat') {
        if (!lorebookState.activations.chat) lorebookState.activations.chat = {};
        if (!lorebookState.activations.chat[targetId]) lorebookState.activations.chat[targetId] = [];

        const list = lorebookState.activations.chat[targetId];
        const idx = list.indexOf(lbId);
        if (idx === -1) list.push(lbId);
        else list.splice(idx, 1);
    }
}

export function getActiveLorebooksForContext(charId, chatId) {
    return lorebookState.lorebooks
        .filter(lb => {
            if (lb.enabled) return true;
            if (charId && lorebookState.activations?.character?.[charId]?.includes(lb.id)) return true;
            if (chatId && lorebookState.activations?.chat?.[chatId]?.includes(lb.id)) return true;
            return false;
        })
        .map(lb => lb.name);
}

export async function importSTLorebook(json, fileName = 'Imported', options = {}) {
    try {
        const { enabled = true, activationScope = null, activationTargetId = null } = options;
        let normalizedEntries = [];
        const entriesRaw = json.entries || [];
        const glazeMetaEntries = json?.glazeMetadata?.entries || {};

        if (Array.isArray(entriesRaw)) {
            normalizedEntries = entriesRaw;
        } else if (typeof entriesRaw === 'object') {
            normalizedEntries = Object.values(entriesRaw);
        }

        const newLb = {
            id: Date.now().toString(36) + Math.random().toString(36).substr(2, 5),
            name: json.name || fileName.replace('.json', ''),
            enabled,
            entries: normalizedEntries.map((entry, index) => {
                const rawKeys = entry.keys || entry.key || [];
                const rawSecondary = entry.secondary_keys || entry.keysecondary || [];
                const metadataPosition = glazeMetaEntries?.[index]?.position;
                const restoredPosition = (metadataPosition === 'worldInfoBefore' || metadataPosition === 'worldInfoAfter' || metadataPosition === 'lorebooksMacro' || metadataPosition === 'matchGlobal')
                    ? metadataPosition
                    : null;
                return {
                    id: entry.uid?.toString() || (Date.now() + Math.random()).toString(36),
                    keys: Array.isArray(rawKeys) ? rawKeys : String(rawKeys || '').split(',').map(k => k.trim()).filter(k => k),
                    content: entry.content || '',
                    enabled: entry.enabled !== false && entry.disable !== true,
                    secondary_keys: Array.isArray(rawSecondary) ? rawSecondary : String(rawSecondary || '').split(',').map(k => k.trim()).filter(k => k),
                    comment: entry.comment || '',
                    order: entry.order !== undefined ? entry.order : 100,
                    probability: entry.probability !== undefined ? entry.probability : 100,
                    constant: entry.constant || false,
                    selectiveLogic: entry.selectiveLogic ?? 0,
                    matchWholeWords: entry.matchWholeWords ?? null,
                    caseSensitive: entry.caseSensitive ?? null,
                    useGroupScoring: entry.useGroupScoring ?? null,
                    scanDepth: entry.scanDepth,
                    position: restoredPosition || ((entry.position === 0)
                        ? 'worldInfoBefore'
                        : (entry.position === 1)
                            ? 'worldInfoAfter'
                            : ((entry.position === 'worldInfoBefore' || entry.position === 'worldInfoAfter' || entry.position === 'lorebooksMacro' || entry.position === 'matchGlobal') ? entry.position : 'matchGlobal')),
                    characterFilter: entry.characterFilter,
                    preventRecursion: entry.preventRecursion || false,
                    delayUntilRecursion: entry.delayUntilRecursion || false,
                    sticky: entry.sticky || 0,
                    cooldown: entry.cooldown || 0,
                    delay: entry.delay || 0,
                    group: entry.group || '',
                    groupProminence: entry.groupProminence || 100,
                    ignoreBudget: entry.ignoreBudget || false
                };
            })
        };

        lorebookState.lorebooks.push(newLb);
        if (activationScope === 'character' && activationTargetId) {
            if (!lorebookState.activations.character) lorebookState.activations.character = {};
            if (!lorebookState.activations.character[activationTargetId]) {
                lorebookState.activations.character[activationTargetId] = [];
            }
            if (!lorebookState.activations.character[activationTargetId].includes(newLb.id)) {
                lorebookState.activations.character[activationTargetId].push(newLb.id);
            }
        }
        return newLb;
    } catch (err) {
        throw new Error('Invalid SillyTavern Lorebook format: ' + err.message);
    }
}

export function exportSTLorebook(lorebook) {
    const entries = {};
    const glazeMetadata = { entries: {} };
    const globalInjectionPosition = lorebookState.globalSettings?.injectionPosition || 'worldInfoBefore';
    (lorebook.entries || []).forEach((entry, index) => {
        const rawPosition = entry.position || 'matchGlobal';
        const resolvedPosition = rawPosition === 'matchGlobal' ? globalInjectionPosition : rawPosition;
        const stPosition = resolvedPosition === 'worldInfoAfter' ? 1 : 0;

        entries[index.toString()] = {
            uid: index,
            key: entry.keys || [],
            keysecondary: entry.secondary_keys || [],
            comment: entry.comment || '',
            content: entry.content || '',
            constant: entry.constant || false,
            selective: (entry.secondary_keys && entry.secondary_keys.length > 0),
            order: entry.order ?? 100,
            position: stPosition,
            disable: entry.enabled === false,
            displayIndex: index,
            addMemo: true,
            group: entry.group || '',
            groupOverride: false,
            groupWeight: entry.groupProminence || 100,
            sticky: entry.sticky || 0,
            cooldown: entry.cooldown || 0,
            delay: entry.delay || 0,
            probability: entry.probability ?? 100,
            depth: 4,
            useProbability: (entry.probability !== undefined && entry.probability < 100),
            role: null,
            vectorized: false,
            excludeRecursion: false,
            preventRecursion: entry.preventRecursion || false,
            delayUntilRecursion: entry.delayUntilRecursion || false,
            scanDepth: entry.scanDepth ?? null,
            caseSensitive: entry.caseSensitive ?? null,
            matchWholeWords: entry.matchWholeWords ?? null,
            useGroupScoring: entry.useGroupScoring ?? null,
            automationId: '',
            selectiveLogic: entry.selectiveLogic ?? 0,
            ignoreBudget: entry.ignoreBudget || false,
            matchPersonaDescription: false,
            matchCharacterDescription: false,
            matchCharacterPersonality: false,
            matchCharacterDepthPrompt: false,
            matchScenario: false,
            matchCreatorNotes: false,
            outletName: '',
            triggers: [],
            ...(entry.characterFilter ? { characterFilter: entry.characterFilter } : {})
        };

        glazeMetadata.entries[index.toString()] = {
            position: rawPosition
        };
    });

    return { entries, glazeMetadata };
}
