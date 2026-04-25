/**
 * Pure JS LMDB reader for Isar-based Tavo backups.
 * Heuristically extracts JSON and texts without WebAssembly or native bindings.
 */
import JSZip from 'jszip';
import { db } from '@/utils/db.js';
import { importSillyTavernChat } from '@/core/services/chatImporter.js';
import { convertSTPreset } from '@/core/services/presetImportService.js';

// Basic Type Mapping from Isar Schema (extracted via heuristic)
const TYPE_NAMES = {
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
    0x006c: "regex_conversation_ref",
    0x0080: "lorebook"
};

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
                        } catch (e) {
                            // fall back to text
                        }
                    }
                    if (!text.includes('\ufffd')) {
                        items.push({ type: "text", data: text });
                    }
                }
            } catch (e) {
                // Ignore decoding errors
            }
        } else {
            i++;
        }
    }
    return items;
}

export function parseTavoLMDB(arrayBuffer) {
    const dv = new DataView(arrayBuffer);
    const buffer = new Uint8Array(arrayBuffer);
    const pageSize = 4096;

    const categories = {};
    for (const k of Object.values(TYPE_NAMES)) categories[k] = new Map();

    let bigCount = 0;

    for (let pOffset = 0; pOffset < buffer.length; pOffset += pageSize) {
        if (pOffset + 16 > buffer.length) break;
        const flags = dv.getUint16(pOffset + 10, true);
        if ((flags & 0x02) === 0x02) { // P_LEAF
            const lower = dv.getUint16(pOffset + 12, true);
            const numNodes = (lower - 16) / 2;

            for (let i = 0; i < numNodes; i++) {
                const nodeOffset = dv.getUint16(pOffset + 16 + (i * 2), true);
                if (nodeOffset === 0) continue;

                const ptr = pOffset + nodeOffset;

                const mn_dsize = dv.getUint32(ptr, true);
                const mn_flags = dv.getUint16(ptr + 4, true);
                const mn_ksize = dv.getUint16(ptr + 6, true);

                // Ensure valid Isar key (18 prefix) -> 1 byte 0x18 + 7 bytes
                if (mn_ksize >= 8 && buffer[ptr + 8] === 0x18) {
                    const type_id = (buffer[ptr + 10] << 8) | buffer[ptr + 11];
                    const type_name = TYPE_NAMES[type_id];
                    if (!type_name) continue;

                    const entity_id = dv.getUint32(ptr + 12, false); // BIG ENDIAN

                    let dataBuffer = null;
                    const keyOffset = ptr + 8;
                    const dataOffset = keyOffset + mn_ksize;

                    // Inline data
                    if (mn_flags === 0) {
                        dataBuffer = buffer.subarray(dataOffset, dataOffset + mn_dsize);
                    }
                    // Overflow pages (F_BIGDATA)
                    else if (mn_flags === 1) {
                        bigCount++;
                        const pgno = dv.getUint32(dataOffset, true);
                        if (pgno * pageSize < buffer.length) {
                            const ovfOffset = pgno * pageSize;
                            const ovfFlags = dv.getUint16(ovfOffset + 10, true);
                            if ((ovfFlags & 0x04) === 0x04) { // P_OVERFLOW
                                dataBuffer = buffer.subarray(ovfOffset + 16, ovfOffset + 16 + mn_dsize);
                            }
                        }
                    }

                    if (dataBuffer) {
                        const fields = extractStringsAndJson(dataBuffer);
                        const entry = { entity_id, fields };

                        if (type_name === 'message' && dataBuffer.length >= 88) {
                            try {
                                const msgDv = new DataView(dataBuffer.buffer, dataBuffer.byteOffset, dataBuffer.byteLength);
                                entry.timestamp = Number(msgDv.getBigInt64(48, true));
                                entry.conversationId = Number(msgDv.getBigInt64(64, true));
                                entry.characterId = Number(msgDv.getBigInt64(80, true));
                            } catch (e) { }
                        }

                        categories[type_name].set(entity_id, entry);
                    }
                }
            }
        }
    }

    // Convert maps back to arrays
    for (const k in categories) {
        categories[k] = Array.from(categories[k].values());
    }

    // Group chats
    const chats = [];
    if (categories.conversation && categories.message) {
        const msgByConv = {};
        for (const msg of categories.message) {
            if (msg.conversationId) {
                if (!msgByConv[msg.conversationId]) msgByConv[msg.conversationId] = [];
                msgByConv[msg.conversationId].push(msg);
            }
        }
        for (const conv of categories.conversation) {
            const cid = conv.entity_id;
            const msgs = msgByConv[cid] || [];
            msgs.sort((a, b) => (a.timestamp || a.entity_id) - (b.timestamp || b.entity_id));
            chats.push({ conversation: conv, messages: msgs });
        }
    }

    return { categories, chats };
}

/**
 * Base64 decoder for shared prefs decoding
 */
export async function decodeSharedPreferences(prefsBuffer) {
    const text = new TextDecoder("utf-8").decode(prefsBuffer);
    try {
        const prefs = JSON.parse(text);
        const decoded = {};
        for (const [k, v] of Object.entries(prefs)) {
            if (typeof v === 'string') {
                try {
                    const str = atob(v);
                    try {
                        decoded[k] = JSON.parse(str);
                    } catch (e) {
                        decoded[k] = str;
                    }
                } catch {
                    decoded[k] = v;
                }
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

/**
 * Imports a Tavo (.tbk) Backup internally inside Glaze via LMDB heuristic parsing.
 * @param {File|Blob} zipFile
 * @param {Function} [onProgress]
 */
export async function importTavoBackupFromZip(zipFile, onProgress) {
    const progress = (msg) => { if (onProgress) onProgress(msg); };
    const result = { characters: 0, lorebooks: 0, presets: 0, chats: 0, errors: [] };

    const zip = await JSZip.loadAsync(zipFile);

    // ── Clear existing DB before import ─────────────────────────────────────
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

    // Helper: resolve a charaCard/... path from the ZIP and return a base64 data URL
    async function readAvatarFromZip(charaCardPath) {
        if (!charaCardPath || !charaCardPath.includes('/')) return null;
        // Strip leading path component and look in CharacterCards/
        const filename = charaCardPath.split('/').pop();
        // Try to find the file in the zip (case-insensitive, any folder)
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
        } catch (e) {
            return null;
        }
    }

    // Process Personas
    progress('personas');
    if (tavoData.categories.persona_ref && tavoData.categories.persona_ref.length > 0) {
        for (const pref of tavoData.categories.persona_ref) {
            try {
                // Filter out empty strings
                const strings = pref.fields.filter(f => f.type === 'text' && f.data.trim().length > 0).map(f => f.data);
                if (strings.length < 2) continue;

                // Avatar is stored as charaCard/...
                const rawAvatar = strings.find(s => s.startsWith('charaCard/'));
                const textOnly = strings.filter(s => s !== rawAvatar);

                let prompt = "";
                let name = "User Persona";
                if (textOnly.length >= 2) {
                    // Usually name is much shorter than description
                    textOnly.sort((a, b) => b.length - a.length);
                    prompt = textOnly[0];
                    name = textOnly[textOnly.length - 1]; // smallest
                } else if (textOnly.length > 0) {
                    name = textOnly[0];
                }

                const persona = {
                    id: Date.now().toString(36) + Math.random().toString(36).substr(2),
                    prompt: prompt || "",
                    name: name || "User Persona",
                    avatar: rawAvatar ? await readAvatarFromZip(rawAvatar) : null
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
                // Empty strings are often spacing, keep robust logic
                const strings = ep.fields.filter(f => f.type === 'text' && f.data.trim().length > 0).map(f => f.data);
                if (strings.length < 4) continue;

                // Identify endpoint URL (first string that starts with http)
                const urlIndex = strings.findIndex(s => s.startsWith('http://') || s.startsWith('https://'));
                const baseIndex = urlIndex !== -1 ? urlIndex : 0;

                const preset = {
                    id: 'tavo_' + Date.now().toString(36) + Math.random().toString(36).substr(2),
                    endpoint: strings[baseIndex] || "",
                    model: strings[baseIndex + 2] || "",
                    key: strings[baseIndex + 3] || "",
                    name: strings.length > baseIndex + 4 ? strings[baseIndex + 4] : (strings[baseIndex] || "Tavo Endpoint"),
                    max_tokens: '8000',
                    context: '32000',
                    temp: '0.7',
                    topp: '0.9',
                    stream: true
                };
                if (!existingApiPresets.some(p => p.endpoint === preset.endpoint && p.key === preset.key)) {
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
                const texts = regGroup.fields.filter(f => f.type === 'text' && f.data.trim().length > 0).map(f => f.data);
                const jsons = regGroup.fields.filter(f => f.type === 'json').map(f => f.data);

                // Fallback: sometimes regex JSON contains complex characters that make tavoBackupReader fail
                const unparsed = regGroup.fields.filter(f => f.type === 'text' && f.data.trim().startsWith('[') && f.data.includes('"findRegex"'));
                for (const u of unparsed) {
                    try { jsons.push(JSON.parse(u.data)); } catch (e) { }
                }

                const groupName = texts.length > 0 ? texts[texts.length - 1] : '';

                for (const jsonBlock of jsons) {
                    if (Array.isArray(jsonBlock)) {
                        for (const rule of jsonBlock) {
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
                                    substituteRegex: rule.substitution === "none" ? 0 : 1,
                                    ephemerality: [1, 2],
                                    minDepth: rule.minDepth || null,
                                    maxDepth: rule.maxDepth || null
                                });
                            }
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
                // The entries JSON block is the first json field; the name is the last text field
                const entriesField = lb.fields.find(f => f.type === 'json' && Array.isArray(f.data));
                const nameField = lb.fields.filter(f => f.type === 'text').pop();
                if (!entriesField) continue;

                const lbName = nameField ? nameField.data : 'Tavo Lorebook';
                const entries = entriesField.data.map(e => ({
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
                    name: lbName,
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
                // preset.fields usually has a JSON block of prompts and the name at the end
                let promptsJson = null;
                let presetName = "Tavo Preset";
                for (let i = 0; i < preset.fields.length; i++) {
                    const f = preset.fields[i];
                    if (f.type === 'json' && Array.isArray(f.data) && f.data.length > 0 && f.data[0].identifier) {
                        promptsJson = f.data;
                    } else if (f.type === 'text' && f.data.length < 50 && !f.data.includes('{')) {
                        presetName = f.data;
                    }
                }

                if (promptsJson) {
                    const pData = {
                        name: presetName,
                        prompts: promptsJson
                    };
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
    const charNameToId = {};
    if (tavoData.categories.character && tavoData.categories.character.length > 0) {
        for (const char of tavoData.categories.character) {
            try {
                const strings = char.fields.filter(f => f.type === 'text' && f.data.trim().length > 0).map(f => f.data);
                const jsons = char.fields.filter(f => f.type === 'json').map(f => f.data);

                let charData = { id: Date.now().toString(36) + Math.random().toString(36).substr(2) };

                // If it's a V2 JSON inside
                const v2Json = jsons.find(j => j.spec === 'chara_card_v2' || j.spec === 'chara_card_v3');
                if (v2Json && v2Json.data) {
                    charData = { ...charData, ...v2Json.data };
                    // v2 cards don't embed the avatar path separately; try to find it by name
                    const avatarStr = strings.find(s => s.startsWith('charaCard/'));
                    if (avatarStr) charData.avatar = await readAvatarFromZip(avatarStr);
                } else if (strings.length >= 2) {
                    // Fallback heuristic extraction
                    const avatarStr = strings.find(s => s.startsWith('charaCard/'));
                    if (avatarStr) charData.avatar = await readAvatarFromZip(avatarStr);

                    const rem = strings.filter(s => s !== avatarStr);
                    // Name is consistently the final string field in Tavo's character entity unrolling
                    charData.name = rem.length > 0 ? rem.pop() : "Unknown";

                    // The easiest and most robust way to find Description and First_mes 
                    // from the loosely coupled strings is by length sorting
                    const sortedByLen = [...rem].sort((a, b) => b.length - a.length);
                    charData.description = sortedByLen.length > 0 ? sortedByLen[0] : "";
                    charData.first_mes = sortedByLen.length > 1 ? sortedByLen[1] : "";

                    // Bundle the rest to avoid silent data loss (short descriptions, tags, scenarios)
                    if (sortedByLen.length > 2) {
                        const leftover = sortedByLen.slice(2);

                        // Extract probable tags (short, single-line strings)
                        const probableTags = leftover.filter(s => s.length < 60 && !s.includes('\n') && !s.startsWith('http') && !s.startsWith('charaCard/'));
                        if (probableTags.length > 0) {
                            // SillyTavern and Glaze expect an array of strings for tags
                            charData.tags = probableTags.map(t => t.trim());
                        }

                        // The rest goes to creator_notes
                        const remaining = leftover.filter(s => !probableTags.includes(s) && !s.startsWith('http') && !s.startsWith('charaCard/'));
                        if (remaining.length > 0) {
                            charData.creator_notes = remaining.join("\n\n---\n");
                        }
                    }
                } else {
                    continue; // cannot parse
                }

                if (!charData.name) charData.name = "Unknown";
                await db.saveCharacter(charData);
                charNameToId[char.entity_id] = charData.id;
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
                const cid = chatBlock.conversation.entity_id;

                const msgs = chatBlock.messages.filter(m => m.fields && m.fields.length > 0);
                if (msgs.length === 0) continue;

                // Find the first AI message to determine which character this chat belongs to.
                // User messages have characterId === 0 in Tavo (not -1).
                const firstCharMsg = msgs.find(m => m.characterId && m.characterId !== 0);
                if (!firstCharMsg) continue;
                const charEntityId = firstCharMsg.characterId;

                const glazeCharId = charNameToId[charEntityId];
                if (!glazeCharId) {
                    continue;
                }

                // Convert messages to ST format JSONL and use existing importer
                const lines = [];
                const metadata = {
                    user_name: "User",
                    character_name: "Char",
                    create_date: new Date().toISOString(),
                    chat_metadata: { exported_from: "Tavo", import_date: Date.now() }
                };
                lines.push(JSON.stringify(metadata));

                for (const tMsg of msgs) {
                    // Find actual text ignoring IDs, hashes, and internal image paths
                    const txt = tMsg.fields.filter(f => f.type === 'text' && f.data.length > 5 && !f.data.startsWith('charaCard/')).map(f => f.data).join("\n");
                    // characterId === 0 or negative means user message in Tavo
                    const isUser = !tMsg.characterId || tMsg.characterId <= 0;
                    const stMsg = {
                        name: isUser ? "User" : "Char",
                        is_user: isUser,
                        is_system: false,
                        send_date: new Date(tMsg.timestamp || Date.now()).toISOString(),
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

    return result;
}
