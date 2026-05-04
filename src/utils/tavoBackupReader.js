/**
 * Pure JS LMDB/ObjectBox reader for Tavo backups.
 * Uses FlatBuffer format for structured field extraction.
 */
import JSZip from 'jszip';
import { db, flushDbWriteQueue } from '@/utils/db.js';
import { importSillyTavernChat } from '@/core/services/chatImporter.js';
import { convertSTPreset } from '@/core/services/presetImportService.js';
import { initLorebookState, flushLorebookSave } from '@/core/states/lorebookState.js';
import { initPresetState, flushPresetSave } from '@/core/states/presetState.js';

const TYPE_NAMES = {
    0x0000: "_meta",
    0x0004: "character",
    0x0018: "conversation",
    0x001c: "model_setting",
    0x0024: "endpoint",
    0x0028: "persona_ref",
    0x0038: "message",
    0x0040: "chat_theme",
    0x0048: "preset",
    0x0058: "ltm_settings",
    0x0060: "ltm",
    0x0064: "regex",
    0x0068: "regex_conversation_ref",
    0x006c: "lorebook_entry",
    0x0080: "lorebook",
    0x0084: "lorebook_character_ref",
    0x00a0: "ltm_conversation_ref",
    0x00c0: "conversation_settings",
    0x00dc: "ltm_settings_ref",
    0x00e0: "message_metadata",
    0x00e4: "vision_settings",
    0x00e8: "vision_conversation_ref",
    0x00ec: "ltm_personality",
    0x00f0: "_unknown_f0"
};

function readFieldString(buf, offset) {
    if (offset + 4 > buf.length) return null;
    const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
    const strOffset = dv.getUint32(offset, true);
    if (strOffset < 4) return null;
    const strAbs = offset + strOffset;
    if (strAbs + 4 > buf.length) return null;
    const slen = dv.getUint32(strAbs, true);
    if (slen === 0) return '';
    if (slen > 1000000 || strAbs + 4 + slen > buf.length) return null;
    try {
        return new TextDecoder("utf-8").decode(buf.subarray(strAbs + 4, strAbs + 4 + slen)).replace(/\0+$/, '');
    } catch { return null; }
}

function readFieldStringVector(buf, offset) {
    if (offset + 4 > buf.length) return null;
    const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
    const vecOffset = dv.getUint32(offset, true);
    if (vecOffset < 4) return null;
    const vecAbs = offset + vecOffset;
    if (vecAbs + 4 > buf.length) return null;
    const vlen = dv.getUint32(vecAbs, true);
    if (vlen > 100000 || vecAbs + 4 + vlen * 4 > buf.length) return null;
    const result = [];
    for (let i = 0; i < vlen; i++) {
        const elemPos = vecAbs + 4 + i * 4;
        if (elemPos + 4 > buf.length) break;
        const elemOff = dv.getUint32(elemPos, true);
        if (elemOff < 4) break;
        const elemAbs = elemPos + elemOff;
        if (elemAbs + 4 > buf.length) break;
        const eslen = dv.getUint32(elemAbs, true);
        if (elemAbs + 4 + eslen > buf.length) break;
        try {
            result.push(new TextDecoder("utf-8").decode(buf.subarray(elemAbs + 4, elemAbs + 4 + eslen)).replace(/\0+$/, ''));
        } catch { break; }
    }
    return result;
}

function readFieldInt64(buf, offset) {
    if (offset + 8 > buf.length) return null;
    const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
    return Number(dv.getBigInt64(offset, true));
}

function readFieldInt32(buf, offset) {
    if (offset + 4 > buf.length) return null;
    const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
    return dv.getInt32(offset, true);
}

function readFieldFloat64(buf, offset) {
    if (offset + 8 > buf.length) return null;
    const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
    return dv.getFloat64(offset, true);
}

function readFieldBool(buf, offset) {
    if (offset >= buf.length) return null;
    return buf[offset] !== 0;
}

function parseObjectBoxEntity(dataBuf, fieldDefs) {
    if (dataBuf.length < 8) return {};
    const dv = new DataView(dataBuf.buffer, dataBuf.byteOffset, dataBuf.byteLength);

    const rootOffset = dv.getUint32(0, true);
    if (rootOffset < 4 || rootOffset >= dataBuf.length) return {};

    const tableStart = rootOffset;
    if (tableStart + 4 > dataBuf.length) return {};
    const soffset = dv.getInt32(tableStart, true);
    const vtableStart = tableStart - soffset;
    if (vtableStart < 0 || vtableStart + 4 > dataBuf.length) return {};

    const vtableSize = dv.getUint16(vtableStart, true);
    if (vtableSize < 4 || vtableSize > dataBuf.length) return {};
    const numFields = (vtableSize - 4) / 2;

    const offsets = [];
    for (let j = 0; j < numFields; j++) {
        const offPos = vtableStart + 4 + j * 2;
        if (offPos + 2 > dataBuf.length) break;
        offsets.push(dv.getUint16(offPos, true));
    }

    const result = {};
    for (const def of fieldDefs) {
        if (def.index >= offsets.length) continue;
        const fieldOffset = offsets[def.index];
        if (fieldOffset === 0) continue;

        const absPos = tableStart + fieldOffset;

        let val;
        switch (def.type) {
            case 'string': val = readFieldString(dataBuf, absPos); break;
            case 'string_vector': val = readFieldStringVector(dataBuf, absPos); break;
            case 'int64': val = readFieldInt64(dataBuf, absPos); break;
            case 'int32': val = readFieldInt32(dataBuf, absPos); break;
            case 'float64': val = readFieldFloat64(dataBuf, absPos); break;
            case 'bool': val = readFieldBool(dataBuf, absPos); break;
            default: val = null;
        }
        if (val !== null && val !== undefined) {
            result[def.name] = val;
        }
    }
    return result;
}

const CHARACTER_FIELDS = [
    { index: 1, name: 'name', type: 'string' },
    { index: 3, name: 'creatorNotesMultilingual', type: 'string' },
    { index: 4, name: 'scenario', type: 'string' },
    { index: 5, name: 'first_mes', type: 'string' },
    { index: 6, name: 'alternate_greetings', type: 'string' },
    { index: 13, name: 'avatarPath', type: 'string' },
    { index: 14, name: 'description', type: 'string' },
    { index: 15, name: 'creator_notes', type: 'string' },
    { index: 16, name: 'fav', type: 'bool' },
    { index: 21, name: 'mes_example', type: 'string' },
    { index: 22, name: 'personality', type: 'string' },
    { index: 23, name: 'system_prompt', type: 'string' },
    { index: 24, name: 'post_history_instructions', type: 'string' },
    { index: 25, name: 'creator', type: 'string' },
    { index: 26, name: 'character_version', type: 'string' },
    { index: 27, name: 'extensions_json', type: 'string' },
];

const MESSAGE_FIELDS = [
    { index: 1, name: 'characterId', type: 'int64' },
    { index: 2, name: 'text', type: 'string' },
    { index: 4, name: 'swipe_text', type: 'string' },
    { index: 5, name: 'charName', type: 'string' },
    { index: 6, name: 'avatarPath', type: 'string' },
    { index: 7, name: 'timestamp', type: 'int64' },
    { index: 8, name: 'isHidden', type: 'bool' },
    { index: 10, name: 'extras_json', type: 'string' },
];

const CONVERSATION_FIELDS = [
    { index: 2, name: 'createdAt', type: 'int64' },
    { index: 3, name: 'updatedAt', type: 'int64' },
    { index: 17, name: 'presetId', type: 'int64' },
    { index: 18, name: 'characterId', type: 'int64' },
];

const ENDPOINT_FIELDS = [
    { index: 1, name: 'name', type: 'string' },
    { index: 3, name: 'model', type: 'string' },
    { index: 4, name: 'protocol', type: 'string' },
    { index: 5, name: 'url', type: 'string' },
    { index: 6, name: 'stream', type: 'bool' },
    { index: 13, name: 'params_json', type: 'string' },
];

const PRESET_FIELDS = [
    { index: 1, name: 'name', type: 'string' },
    { index: 4, name: 'format_json', type: 'string' },
    { index: 5, name: 'prompts_json', type: 'string' },
];

const PERSONA_FIELDS = [
    { index: 1, name: 'avatarPath', type: 'string' },
    { index: 3, name: 'name', type: 'string' },
    { index: 4, name: 'description', type: 'string' },
];

const LOREBOOK_FIELDS = [
    { index: 1, name: 'name', type: 'string' },
    { index: 4, name: 'entries_json', type: 'string' },
];

const REGEX_FIELDS = [
    { index: 1, name: 'name', type: 'string' },
    { index: 4, name: 'rules_json', type: 'string' },
];

const LTM_SETTINGS_FIELDS = [
    { index: 1, name: 'summaryPrompt', type: 'string' },
    { index: 2, name: 'memoryPrompt', type: 'string' },
    { index: 4, name: 'maxTokens', type: 'int64' },
    { index: 11, name: 'role', type: 'string' },
];

const LTM_FIELDS = [
    { index: 4, name: 'updatedAt', type: 'int64' },
];

function extractStringsAndJson(uint8Array) {
    const items = [];
    let i = 0;
    const len = uint8Array.length;
    const decoder = new TextDecoder("utf-8");

    while (i < len) {
        if (uint8Array[i] >= 32 || uint8Array[i] === 10 || uint8Array[i] === 13 || uint8Array[i] === 9) {
            const start = i;
            while (i < len && (uint8Array[i] >= 32 || uint8Array[i] === 10 || uint8Array[i] === 13 || uint8Array[i] === 9)) {
                i++;
            }
            try {
                const text = decoder.decode(uint8Array.subarray(start, i)).trim();
                if (text.length >= 2) {
                    if (text.startsWith("[") || text.startsWith("{")) {
                        try {
                            const parsed = JSON.parse(text);
                            items.push({ type: "json", data: parsed });
                            continue;
                        } catch (e) { }
                    }
                    if (!text.includes('\ufffd')) {
                        items.push({ type: "text", data: text });
                    }
                }
            } catch (e) { }
        } else {
            i++;
        }
    }
    return items;
}

export function parseTavoLMDB(arrayBuffer) {
    const dv = new DataView(arrayBuffer);
    const buffer = new Uint8Array(arrayBuffer);
    const bufLen = buffer.length;
    const pageSize = 4096;

    const categories = {};
    for (const k of Object.values(TYPE_NAMES)) {
        if (!k.startsWith('_')) categories[k] = new Map();
    }

    const STRUCTURED_PARSERS = {
        character: CHARACTER_FIELDS,
        message: MESSAGE_FIELDS,
        conversation: CONVERSATION_FIELDS,
        endpoint: ENDPOINT_FIELDS,
        preset: PRESET_FIELDS,
        persona_ref: PERSONA_FIELDS,
        lorebook: LOREBOOK_FIELDS,
        regex: REGEX_FIELDS,
        ltm_settings: LTM_SETTINGS_FIELDS,
        ltm: LTM_FIELDS,
    };

    for (let pOffset = 0; pOffset < bufLen; pOffset += pageSize) {
        if (pOffset + 16 > bufLen) break;
        const flags = dv.getUint16(pOffset + 10, true);
        if ((flags & 0x02) !== 0x02) continue;

        const lower = dv.getUint16(pOffset + 12, true);
        if (lower < 16 || lower > pageSize || pOffset + lower > bufLen) continue;

        const numNodes = (lower - 16) / 2;
        if (numNodes <= 0 || numNodes > (pageSize - 16) / 2) continue;

        for (let i = 0; i < numNodes; i++) {
            const nodePtrOff = pOffset + 16 + (i * 2);
            if (nodePtrOff + 2 > bufLen) break;

            const nodeOffset = dv.getUint16(nodePtrOff, true);
            if (nodeOffset === 0 || nodeOffset < 16 || nodeOffset >= pageSize) continue;

            const ptr = pOffset + nodeOffset;
            if (ptr + 16 > bufLen) continue;

            const mn_dsize = dv.getUint32(ptr, true);
            const mn_flags = dv.getUint16(ptr + 4, true);
            const mn_ksize = dv.getUint16(ptr + 6, true);

            if (mn_ksize < 8 || ptr + 8 + mn_ksize > bufLen) continue;
            if (buffer[ptr + 8] !== 0x18) continue;

            const type_id = (buffer[ptr + 10] << 8) | buffer[ptr + 11];
            const type_name = TYPE_NAMES[type_id];
            if (!type_name || type_name.startsWith('_')) continue;

            const entity_id = dv.getUint32(ptr + 12, false);

            let dataBuffer = null;
            const keyOffset = ptr + 8;
            const dataOffset = keyOffset + mn_ksize;

            if (mn_flags === 0) {
                if (dataOffset + mn_dsize <= bufLen) {
                    dataBuffer = buffer.subarray(dataOffset, dataOffset + mn_dsize);
                }
            } else if (mn_flags === 1) {
                if (dataOffset + 4 <= bufLen) {
                    const pgno = dv.getUint32(dataOffset, true);
                    const ovfOffset = pgno * pageSize;
                    if (ovfOffset + 16 + mn_dsize <= bufLen) {
                        const ovfFlags = dv.getUint16(ovfOffset + 10, true);
                        if ((ovfFlags & 0x04) === 0x04) {
                            dataBuffer = buffer.subarray(ovfOffset + 16, ovfOffset + 16 + mn_dsize);
                        }
                    }
                }
            }

            if (dataBuffer && dataBuffer.length > 0) {
                const entry = { entity_id, fields: [], structured: {} };

                if (STRUCTURED_PARSERS[type_name]) {
                    entry.structured = parseObjectBoxEntity(dataBuffer, STRUCTURED_PARSERS[type_name]);
                }

                entry.fields = extractStringsAndJson(dataBuffer);

                if (type_name === 'message') {
                    const s = entry.structured;
                    if (s.timestamp) entry.timestamp = s.timestamp;
                    if (s.characterId !== undefined) entry.characterId = s.characterId;
                }

                categories[type_name].set(entity_id, entry);
            }
        }
    }

    for (const k in categories) {
        categories[k] = Array.from(categories[k].values());
    }

    const chats = [];
    if (categories.conversation && categories.message) {
        const msgByChar = {};
        for (const msg of categories.message) {
            const charId = msg.characterId || (msg.structured && msg.structured.characterId);
            if (charId) {
                if (!msgByChar[charId]) msgByChar[charId] = [];
                msgByChar[charId].push(msg);
            }
        }
        for (const conv of categories.conversation) {
            const convCharId = conv.structured && conv.structured.characterId;
            const msgs = msgByChar[convCharId] || [];
            msgs.sort((a, b) => (a.timestamp || a.entity_id) - (b.timestamp || b.entity_id));
            chats.push({ conversation: conv, messages: msgs, characterId: convCharId });
        }
    }

    return { categories, chats };
}

export async function decodeSharedPreferences(prefsBuffer) {
    const text = new TextDecoder("utf-8").decode(prefsBuffer);
    try {
        const prefs = JSON.parse(text);
        const decoded = {};
        for (const [k, v] of Object.entries(prefs)) {
            if (typeof v === 'string') {
                try {
                    const str = atob(v);
                    try { decoded[k] = JSON.parse(str); } catch (e) { decoded[k] = str; }
                } catch { decoded[k] = v; }
            } else if (Array.isArray(v)) {
                decoded[k] = v.map(item => {
                    if (typeof item === 'string') {
                        try {
                            const str = atob(item);
                            try { return JSON.parse(str); } catch { return str; }
                        } catch { return item; }
                    }
                    return item;
                });
            } else {
                decoded[k] = v;
            }
        }
        return decoded;
    } catch {
        return {};
    }
}

function tryParseJson(str) {
    if (!str || typeof str !== 'string') return null;
    try { return JSON.parse(str); } catch { return null; }
}

export async function importTavoBackupFromZip(zipFile, onProgress) {
    const progress = (msg) => { if (onProgress) onProgress(msg); };
    const result = { characters: 0, lorebooks: 0, presets: 0, chats: 0, errors: [] };

    const zip = await JSZip.loadAsync(zipFile);

    progress('clearing');
    const database = await db.open();
    await new Promise((res, rej) => {
        const tx = database.transaction(['characters', 'personas', 'keyvalue'], 'readwrite');
        tx.objectStore('characters').clear();
        tx.objectStore('personas').clear();
        tx.objectStore('keyvalue').clear();
        tx.oncomplete = res;
        tx.onerror = () => rej(tx.error);
    });
    database.close();
    localStorage.removeItem('silly_cradle_presets');
    localStorage.removeItem('regex_scripts');

    const mdbFile = Object.keys(zip.files).find(p => p.toLowerCase().endsWith('data.mdb'));
    if (!mdbFile) throw new Error("No data.mdb found in Tavo backup zip.");

    progress('reading DB');
    const mdbBuffer = await zip.files[mdbFile].async('arraybuffer');
    const tavoData = parseTavoLMDB(mdbBuffer);

    async function readAvatarFromZip(charaCardPath) {
        if (!charaCardPath || !charaCardPath.includes('/')) return null;
        const filename = charaCardPath.split('/').pop();
        const zipKey = Object.keys(zip.files).find(k =>
            k.toLowerCase().endsWith(('CharacterCards/' + filename).toLowerCase()) ||
            k.toLowerCase().endsWith(filename.toLowerCase())
        );
        if (!zipKey) return null;
        try {
            const blob = await zip.files[zipKey].async('blob');
            return await new Promise((resolve) => {
                const reader = new FileReader();
                reader.onloadend = () => resolve(reader.result);
                reader.onerror = () => resolve(null);
                reader.readAsDataURL(blob);
            });
        } catch (e) { return null; }
    }

    // Process Personas
    progress('personas');
    if (tavoData.categories.persona_ref && tavoData.categories.persona_ref.length > 0) {
        for (const pref of tavoData.categories.persona_ref) {
            try {
                const s = pref.structured || {};
                const name = s.name || '';
                const prompt = s.description || '';
                const avatarPath = s.avatarPath || '';

                if (!name && !prompt) {
                    const strings = pref.fields.filter(f => f.type === 'text' && f.data.trim().length > 0).map(f => f.data);
                    if (strings.length < 1) continue;
                    const rawAvatar = strings.find(st => st.startsWith('charaCard/'));
                    const textOnly = strings.filter(st => st !== rawAvatar);
                    if (textOnly.length >= 2) {
                        textOnly.sort((a, b) => b.length - a.length);
                        const persona = {
                            id: Date.now().toString(36) + Math.random().toString(36).substr(2),
                            prompt: textOnly[0],
                            name: textOnly[textOnly.length - 1],
                            avatar: rawAvatar ? await readAvatarFromZip(rawAvatar) : null
                        };
                        await db.put('personas', persona);
                    } else if (textOnly.length > 0) {
                        const persona = {
                            id: Date.now().toString(36) + Math.random().toString(36).substr(2),
                            prompt: '',
                            name: textOnly[0],
                            avatar: rawAvatar ? await readAvatarFromZip(rawAvatar) : null
                        };
                        await db.put('personas', persona);
                    }
                    continue;
                }

                const persona = {
                    id: Date.now().toString(36) + Math.random().toString(36).substr(2),
                    prompt: prompt || "",
                    name: name || "User Persona",
                    avatar: avatarPath ? await readAvatarFromZip(avatarPath) : null
                };
                await db.put('personas', persona);
            } catch (err) {
                result.errors.push(`Tavo Persona: ${err.message}`);
            }
        }
    }

    // Process APIs
    progress('apis');
    if (tavoData.categories.endpoint && tavoData.categories.endpoint.length > 0) {
        const existingApiPresets = await db.get('gz_api_connection_presets') || [];
        for (const ep of tavoData.categories.endpoint) {
            try {
                const s = ep.structured || {};
                const params = tryParseJson(s.params_json) || {};
                const preset = {
                    id: 'tavo_' + Date.now().toString(36) + Math.random().toString(36).substr(2),
                    endpoint: s.url || "",
                    model: s.model || "",
                    key: "",
                    name: s.name || s.url || "Tavo Endpoint",
                    max_tokens: String(params.max_tokens || 8000),
                    context: String(params.context_length || 32000),
                    temp: String(params.temperature ?? 0.7),
                    topp: String(params.top_p ?? 0.9),
                    stream: s.stream !== undefined ? s.stream : true
                };
                if (!existingApiPresets.some(p => p.endpoint === preset.endpoint && p.model === preset.model)) {
                    existingApiPresets.push(preset);
                }
            } catch (err) {
                result.errors.push(`Tavo API: ${err.message}`);
            }
        }
        await db.set('gz_api_connection_presets', existingApiPresets);
    }

    // Process Regexes
    progress('regexes');
    if (tavoData.categories.regex && tavoData.categories.regex.length > 0) {
        let globalScripts = [];
        try { globalScripts = JSON.parse(localStorage.getItem('regex_scripts')) || []; } catch (e) { }
        for (const regGroup of tavoData.categories.regex) {
            try {
                const s = regGroup.structured || {};
                let rulesJson = tryParseJson(s.rules_json);
                let groupName = s.name || '';

                if (!rulesJson) {
                    const texts = regGroup.fields.filter(f => f.type === 'text' && f.data.trim().length > 0).map(f => f.data);
                    const jsons = regGroup.fields.filter(f => f.type === 'json').map(f => f.data);
                    const unparsed = regGroup.fields.filter(f => f.type === 'text' && f.data.trim().startsWith('[') && f.data.includes('"findRegex"'));
                    for (const u of unparsed) { try { jsons.push(JSON.parse(u.data)); } catch (e) { } }
                    groupName = groupName || (texts.length > 0 ? texts[texts.length - 1] : '');
                    for (const jsonBlock of jsons) {
                        if (Array.isArray(jsonBlock)) { rulesJson = jsonBlock; break; }
                    }
                }

                if (rulesJson && Array.isArray(rulesJson)) {
                    for (const rule of rulesJson) {
                        if (rule.identifier && rule.name) {
                            const finalName = groupName ? `[${groupName}] ${rule.name}` : rule.name;
                            globalScripts.push({
                                id: 'tavo_' + rule.identifier,
                                name: finalName,
                                regex: rule.findRegex || "",
                                replacement: rule.replaceString || "",
                                trimOut: Array.isArray(rule.trimStrings) ? rule.trimStrings.join('\n') : "",
                                placement: [1, 2],
                                disabled: rule.enabled === false,
                                markdownOnly: false,
                                runOnEdit: false,
                                macroRules: rule.substitution === "none" ? "0" : "1",
                                ephemerality: [1, 2],
                                minDepth: rule.minDepth || null,
                                maxDepth: rule.maxDepth || null
                            });
                        }
                    }
                }
            } catch (err) {
                result.errors.push(`Tavo Regex: ${err.message}`);
            }
        }
        localStorage.setItem('regex_scripts', JSON.stringify(globalScripts));
    }

    // Process Lorebooks
    progress('lorebooks');
    if (tavoData.categories.lorebook && tavoData.categories.lorebook.length > 0) {
        const existingLorebooksData = await db.get('gz_lorebooks') || { lorebooks: [], settings: {}, activations: {} };
        const existingLorebooks = Array.isArray(existingLorebooksData)
            ? existingLorebooksData
            : (existingLorebooksData.lorebooks || []);

        for (const lb of tavoData.categories.lorebook) {
            try {
                const s = lb.structured || {};
                let entriesJson = tryParseJson(s.entries_json);
                let lbName = s.name || '';

                if (!entriesJson) {
                    const entriesField = lb.fields.find(f => f.type === 'json' && Array.isArray(f.data));
                    const nameField = lb.fields.filter(f => f.type === 'text').pop();
                    if (!entriesField) continue;
                    entriesJson = entriesField.data;
                    lbName = lbName || (nameField ? nameField.data : 'Tavo Lorebook');
                }

                if (!entriesJson || !Array.isArray(entriesJson)) continue;

                const entries = entriesJson.map(e => ({
                    id: 'tavo_' + (e.identifier || Date.now().toString(36) + Math.random().toString(36).substr(2)),
                    keys: Array.isArray(e.keywords) ? e.keywords : [],
                    secondary_keys: Array.isArray(e.secondaryKeywords) ? e.secondaryKeywords : [],
                    content: e.content || '',
                    comment: e.name || '',
                    enabled: e.enabled !== false,
                    constant: e.strategy === 'constant',
                    selectiveLogic: 0,
                    order: 100,
                    probability: typeof e.probability === 'number' ? e.probability : 100,
                    scanDepth: typeof e.scanDepth === 'number' ? e.scanDepth : 2,
                    caseSensitive: e.caseSensitive ?? false,
                    matchWholeWords: e.matchWholeWord ?? false,
                    sticky: e.sticky || 0,
                    cooldown: e.cooldown || 0,
                    delay: e.delay || 0,
                    group: e.groupName || '',
                    preventRecursion: e.preventRecursion || false,
                    excludeRecursion: e.excludeRecursion || false,
                }));

                existingLorebooks.push({
                    id: 'tavo_lb_' + lb.entity_id,
                    name: lbName || 'Tavo Lorebook',
                    enabled: true,
                    entries,
                });
                result.lorebooks++;
            } catch (err) {
                result.errors.push(`Tavo Lorebook: ${err.message}`);
            }
        }

        const saveData = typeof existingLorebooksData === 'object' && !Array.isArray(existingLorebooksData)
            ? { ...existingLorebooksData, lorebooks: existingLorebooks }
            : { lorebooks: existingLorebooks, settings: {}, activations: {} };
        await db.set('gz_lorebooks', saveData);
    }

    // Process Presets
    progress('presets');
    if (tavoData.categories.preset && tavoData.categories.preset.length > 0) {
        const existingPresetsRaw = localStorage.getItem('silly_cradle_presets');
        const existingPresets = existingPresetsRaw ? JSON.parse(existingPresetsRaw) : {};

        for (const preset of tavoData.categories.preset) {
            try {
                const s = preset.structured || {};
                let promptsJson = tryParseJson(s.prompts_json);
                let presetName = s.name || "Tavo Preset";

                if (!promptsJson) {
                    for (let i = 0; i < preset.fields.length; i++) {
                        const f = preset.fields[i];
                        if (f.type === 'json' && Array.isArray(f.data) && f.data.length > 0 && f.data[0].identifier) {
                            promptsJson = f.data;
                        } else if (f.type === 'text' && f.data.length < 50 && !f.data.includes('{')) {
                            presetName = f.data;
                        }
                    }
                }

                if (promptsJson) {
                    const pData = { name: presetName, prompts: promptsJson };
                    const converted = convertSTPreset(pData, presetName);
                    const id = Date.now().toString(36) + Math.random().toString(36).substr(2);
                    converted.id = id;
                    existingPresets[id] = converted;
                    result.presets++;
                }
            } catch (err) {
                result.errors.push(`Tavo Preset: ${err.message}`);
            }
        }
        localStorage.setItem('silly_cradle_presets', JSON.stringify(existingPresets));
    }

    // Process Characters
    progress('characters');
    const charEntityIdToGlazeId = {};
    if (tavoData.categories.character && tavoData.categories.character.length > 0) {
        for (const char of tavoData.categories.character) {
            try {
                const s = char.structured || {};
                let charData = { id: Date.now().toString(36) + Math.random().toString(36).substr(2) };

                const extensionsJson = tryParseJson(s.extensions_json);
                const v2Data = extensionsJson && (extensionsJson.spec === 'chara_card_v2' || extensionsJson.spec === 'chara_card_v3')
                    ? extensionsJson.data : null;

                if (v2Data) {
                    charData = { ...charData, ...v2Data };
                    if (s.avatarPath) charData.avatar = await readAvatarFromZip(s.avatarPath);
                } else if (s.name || s.description) {
                    charData.name = s.name || "Unknown";
                    charData.description = s.description || "";
                    charData.first_mes = s.first_mes || "";
                    charData.scenario = s.scenario || "";
                    charData.personality = s.personality || "";
                    charData.mes_example = s.mes_example || "";
                    charData.creator_notes = s.creator_notes || "";
                    charData.system_prompt = s.system_prompt || "";
                    charData.post_history_instructions = s.post_history_instructions || "";
                    charData.creator = s.creator || "";
                    charData.character_version = s.character_version || "";

                    if (s.avatarPath) {
                        charData.avatar = await readAvatarFromZip(s.avatarPath);
                    }

                    if (extensionsJson) {
                        charData.talkativeness = extensionsJson.talkativeness || "0.5";
                        charData.fav = extensionsJson.fav || false;
                        charData.world = extensionsJson.world || "";
                        if (extensionsJson.depth_prompt) {
                            charData.depth_prompt = {
                                prompt: extensionsJson.depth_prompt.prompt || "",
                                depth: extensionsJson.depth_prompt.depth || 4,
                                role: extensionsJson.depth_prompt.role || 'system'
                            };
                        }
                    }

                    const altGreetJson = tryParseJson(s.alternate_greetings);
                    if (Array.isArray(altGreetJson)) {
                        charData.alternate_greetings = altGreetJson;
                    }
                } else {
                    const strings = char.fields.filter(f => f.type === 'text' && f.data.trim().length > 0).map(f => f.data);
                    const jsons = char.fields.filter(f => f.type === 'json').map(f => f.data);

                    const v2 = jsons.find(j => j.spec === 'chara_card_v2' || j.spec === 'chara_card_v3');
                    if (v2 && v2.data) {
                        charData = { ...charData, ...v2.data };
                        const avatarStr = strings.find(st => st.startsWith('charaCard/'));
                        if (avatarStr) charData.avatar = await readAvatarFromZip(avatarStr);
                    } else if (strings.length >= 2) {
                        const avatarStr = strings.find(st => st.startsWith('charaCard/'));
                        if (avatarStr) charData.avatar = await readAvatarFromZip(avatarStr);
                        const rem = strings.filter(st => st !== avatarStr);
                        charData.name = rem.length > 0 ? rem.pop() : "Unknown";
                        const sortedByLen = [...rem].sort((a, b) => b.length - a.length);
                        charData.description = sortedByLen.length > 0 ? sortedByLen[0] : "";
                        charData.first_mes = sortedByLen.length > 1 ? sortedByLen[1] : "";
                        if (sortedByLen.length > 2) {
                            const leftover = sortedByLen.slice(2);
                            const probableTags = leftover.filter(st => st.length < 60 && !st.includes('\n') && !st.startsWith('http'));
                            if (probableTags.length > 0) charData.tags = probableTags.map(t => t.trim());
                            const remaining = leftover.filter(st => !probableTags.includes(st));
                            if (remaining.length > 0) charData.creator_notes = remaining.join("\n\n---\n");
                        }
                    } else {
                        continue;
                    }
                }

                if (!charData.name) charData.name = "Unknown";
                await db.saveCharacter(charData);
                charEntityIdToGlazeId[char.entity_id] = charData.id;
                result.characters++;
            } catch (err) {
                result.errors.push(`Tavo Character: ${err.message}`);
            }
        }
    }

    // Process Chats
    progress('chats');
    if (tavoData.chats && tavoData.chats.length > 0) {
        for (const chatBlock of tavoData.chats) {
            try {
                const msgs = chatBlock.messages.filter(m => m.structured && (m.structured.text || m.structured.swipe_text));
                if (msgs.length === 0) continue;

                const charEntityId = chatBlock.characterId;
                const glazeCharId = charEntityIdToGlazeId[charEntityId];
                if (!glazeCharId) continue;

                const lines = [];
                const metadata = {
                    user_name: "User",
                    character_name: msgs[0].structured.charName || "Char",
                    create_date: msgs[0].timestamp ? new Date(msgs[0].timestamp).toISOString() : new Date().toISOString(),
                    chat_metadata: { exported_from: "Tavo", import_date: Date.now() }
                };
                lines.push(JSON.stringify(metadata));

                for (const tMsg of msgs) {
                    const s = tMsg.structured || {};
                    const txt = s.text || '';
                    const isUser = s.characterId === 0;
                    const ts = tMsg.timestamp || Date.now();

                    const stMsg = {
                        name: isUser ? "User" : (s.charName || "Char"),
                        is_user: isUser,
                        is_system: false,
                        send_date: new Date(ts).toISOString(),
                        mes: txt,
                        extra: {}
                    };
                    lines.push(JSON.stringify(stMsg));
                }

                const blob = new Blob([lines.join("\n")], { type: 'text/plain' });
                await importSillyTavernChat(blob, glazeCharId, null);
                result.chats++;
            } catch (err) {
                result.errors.push(`Tavo Chat: ${err.message}`);
            }
        }
    }

    progress('finalizing');
    await flushDbWriteQueue();

    flushPresetSave();
    await initPresetState(true);

    flushLorebookSave();
    await initLorebookState(true);

    const keysToRemove = [];
    for (let i = 0; i < localStorage.length; i++) {
        const key = localStorage.key(i);
        if (key && key.startsWith('gz_chat_recovery_')) {
            keysToRemove.push(key);
        }
    }
    keysToRemove.forEach(key => localStorage.removeItem(key));

    localStorage.setItem('gz_skip_sync_pull', Date.now().toString());
    localStorage.setItem('gz_backup_restored', Date.now().toString());

    return result;
}
