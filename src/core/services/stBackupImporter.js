import JSZip from 'jszip';
import { parseCharacterCard } from '@/utils/characterIO.js';
import { importSillyTavernChat } from '@/core/services/chatImporter.js';
import { convertSTPreset } from '@/core/services/presetImportService.js';
import { importSTLorebook, initLorebookState, saveLorebooks } from '@/core/states/lorebookState.js';
import { db } from '@/utils/db.js';

/**
 * Imports a SillyTavern backup ZIP file.
 * Merges characters, lorebooks, presets, chats, and personas into the current DB.
 * @param {File|Blob} zipFile
 * @param {Function} [onProgress] - Called with a status string at each phase.
 * @returns {Promise<{characters: number, lorebooks: number, presets: number, chats: number, personas: number, errors: string[]}>}
 */
export async function importSTBackupFromZip(zipFile, onProgress) {
    const progress = (msg) => { if (onProgress) onProgress(msg); };
    const result = { characters: 0, lorebooks: 0, presets: 0, chats: 0, personas: 0, errors: [] };

    const zip = await JSZip.loadAsync(zipFile);

    // ── Clear existing DB before import ─────────────────────────────────────
    progress('clearing');
    const database = await db.open();
    await new Promise((res, rej) => {
        const tx = database.transaction(['characters', 'personas', 'keyvalue'], 'readwrite');
        tx.objectStore('characters').clear();
        tx.objectStore('personas').clear();
        // Clear all keys from keyvalue (lorebooks, api presets, chats)
        tx.objectStore('keyvalue').clear();

        tx.oncomplete = res;
        tx.onerror = () => rej(tx.error);
    });
    database.close();
    // Clear presets and regexes from localStorage
    localStorage.removeItem('silly_cradle_presets');
    localStorage.removeItem('regex_scripts');

    // charFolderName (no extension) → characterId, populated during character import
    const charNameToId = {};

    // ── Phase 1: Characters ─────────────────────────────────────────────────
    progress('characters');
    const charPaths = Object.keys(zip.files).filter(p => {
        if (!p.startsWith('characters/') || zip.files[p].dir) return false;
        const parts = p.split('/');
        return parts.length === 2 && parts[1].toLowerCase().endsWith('.png');
    });

    for (const path of charPaths) {
        try {
            const buf = await zip.files[path].async('arraybuffer');
            const filename = path.split('/').pop();
            const file = new File([buf], filename, { type: 'image/png' });
            const charData = await parseCharacterCard(file);
            if (!charData.id) {
                charData.id = Date.now().toString(36) + Math.random().toString(36).substr(2);
            }
            await db.saveCharacter(charData);
            charNameToId[filename.replace(/\.png$/i, '')] = charData.id;
            result.characters++;
        } catch (err) {
            result.errors.push(`Character ${path}: ${err.message}`);
        }
    }

    // ── Phase 2: Lorebooks ───────────────────────────────────────────────────
    progress('lorebooks');
    await initLorebookState();
    const lorebookPaths = Object.keys(zip.files).filter(p =>
        p.startsWith('worlds/') && !zip.files[p].dir && p.toLowerCase().endsWith('.json')
    );

    for (const path of lorebookPaths) {
        try {
            const text = await zip.files[path].async('string');
            const json = JSON.parse(text);
            const fileName = path.split('/').pop();
            await importSTLorebook(json, fileName);
            result.lorebooks++;
        } catch (err) {
            result.errors.push(`Lorebook ${path}: ${err.message}`);
        }
    }
    if (result.lorebooks > 0) await saveLorebooks();

    // ── Phase 3: Presets ─────────────────────────────────────────────────────
    progress('presets');
    const presetPaths = Object.keys(zip.files).filter(p =>
        p.startsWith('OpenAI Settings/') && !zip.files[p].dir && p.toLowerCase().endsWith('.json')
    );

    if (presetPaths.length > 0) {
        const existingPresetsRaw = localStorage.getItem('silly_cradle_presets');
        const existingPresets = existingPresetsRaw ? JSON.parse(existingPresetsRaw) : {};

        for (const path of presetPaths) {
            try {
                const text = await zip.files[path].async('string');
                const json = JSON.parse(text);
                const fileName = path.split('/').pop().replace(/\.json$/i, '');
                const preset = convertSTPreset(json, fileName);
                const id = Date.now().toString(36) + Math.random().toString(36).substr(2);
                preset.id = id;
                existingPresets[id] = preset;
                result.presets++;
            } catch (err) {
                result.errors.push(`Preset ${path}: ${err.message}`);
            }
        }
        localStorage.setItem('silly_cradle_presets', JSON.stringify(existingPresets));
    }

    // ── Phase 4: Chats ───────────────────────────────────────────────────────
    progress('chats');
    const chatPaths = Object.keys(zip.files).filter(p => {
        if (!p.startsWith('chats/') || zip.files[p].dir) return false;
        const ext = p.toLowerCase();
        return ext.endsWith('.jsonl') || ext.endsWith('.json');
    });

    for (const path of chatPaths) {
        try {
            const parts = path.split('/');
            if (parts.length < 3) continue; // must be chats/<folder>/<file>
            const charFolderName = parts[1];
            const characterId = charNameToId[charFolderName];
            if (!characterId) {
                result.errors.push(`Chat ${path}: no imported character matched folder "${charFolderName}"`);
                continue;
            }
            const text = await zip.files[path].async('string');
            const blob = new Blob([text], { type: 'text/plain' });
            await importSillyTavernChat(blob, characterId, null);
            result.chats++;
        } catch (err) {
            result.errors.push(`Chat ${path}: ${err.message}`);
        }
    }

    // ── Phase 5: Personas ────────────────────────────────────────────────────
    progress('personas');

    // settings.json might be in the root or inside a folder if the user zipped the entire ST folder.
    const settingsPath = Object.keys(zip.files).find(p => p.toLowerCase().endsWith('settings.json') && !zip.files[p].dir);

    if (settingsPath) {
        try {
            const text = await zip.files[settingsPath].async('string');
            const settings = JSON.parse(text);

            // ST stores personas under power_user, not at root level
            const pu = settings.power_user || settings;
            const personasMap = pu.personas || settings.personas || {};
            const descriptionsMap = pu.persona_descriptions || settings.persona_descriptions || {};

            for (const [avatarFilename, personaName] of Object.entries(personasMap)) {
                if (!avatarFilename) continue;

                const descData = descriptionsMap[avatarFilename] || {};

                // Try to load the avatar image from User Avatars/ folder
                let avatarData = null;
                const avatarPath = Object.keys(zip.files).find(p =>
                    p.toLowerCase().endsWith(avatarFilename.toLowerCase()) &&
                    p.toLowerCase().includes('user avatars')
                );
                if (avatarPath) {
                    try {
                        const buf = await zip.files[avatarPath].async('arraybuffer');
                        const bytes = new Uint8Array(buf);
                        let binary = '';
                        for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
                        avatarData = 'data:image/png;base64,' + btoa(binary);
                    } catch (_) { /* avatar not critical */ }
                }

                const persona = {
                    id: Date.now().toString(36) + Math.random().toString(36).substr(2),
                    name: personaName,
                    avatar: avatarData,
                    prompt: descData.description || '',
                };

                await db.savePersona(persona);
                result.personas++;
            }
        } catch (err) {
            result.errors.push(`Personas (settings.json): ${err.message}`);
        }
    }

    return result;
}
