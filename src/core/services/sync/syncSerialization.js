import { db, clearSyncDeletedEntry } from '@/utils/db.js';
import { encryptForSync, decryptFromSync } from '@/core/services/crypto/keyManager.js';
import { showToast } from '@/core/states/toastState.js';

const MAX_SYNC_PAYLOAD_BYTES = 30 * 1024 * 1024;

export async function computeSyncHash(data) {
    const normalized = JSON.stringify(data ?? null);
    const bytes = new TextEncoder().encode(normalized);
    const digest = await crypto.subtle.digest('SHA-256', bytes);
    return Array.from(new Uint8Array(digest)).map(b => b.toString(16).padStart(2, '0')).join('');
}

export async function encryptEntity(data, key) {
    if (!key) return data;
    return encryptForSync(data, key);
}

export async function decryptEntity(encrypted, key) {
    if (!key) return encrypted;
    if (!encrypted.iv || !encrypted.data) return encrypted;
    return decryptFromSync(encrypted, key);
}

export async function getLocalCharacter(id) {
    const char = await db.getFromStore('characters', id);
    if (!char) return null;
    const { images: _images, ...rest } = char;
    return rest;
}

export async function getLocalCharacterWithImages(id) {
    return (await db.getFromStore('characters', id)) || null;
}

export async function getLocalPersona(id) {
    return (await db.getFromStore('personas', id)) || null;
}

export async function getLocalChat(charId) {
    return db.getChat(charId);
}

export async function deleteCloudFileIfExists(adapter, entry) {
    try {
        await adapter.deleteFile(entry.path);
    } catch {}
}

export async function readCloudEntityByEntry(adapter, entry, key) {
    let result = await adapter.download(entry.path);
    if (!result) {
        const altPath = entry.path.endsWith('.enc')
            ? entry.path.replace('.enc', '.json')
            : entry.path.replace('.json', '.enc');
        result = await adapter.download(altPath);
    }
    if (!result) return null;
    if (result.data.length > MAX_SYNC_PAYLOAD_BYTES) {
        console.warn(`[sync] Skipping download ${entry.type} ${entry.id}: payload ${Math.round(result.data.length / 1024 / 1024)}MB exceeds limit`);
        showToast(`Sync: ${entry.type} too large (${Math.round(result.data.length / 1024 / 1024)}MB), skipped`, 5000);
        return null;
    }
    const parsed = JSON.parse(result.data);
    return decryptEntity(parsed, key);
}

export async function applyCloudEntry(adapter, entry, key) {
    if (entry.deleted) {
        if (entry.type === 'character') {
            await db.delete('characters', entry.id);
        } else if (entry.type === 'persona') {
            await db.delete('personas', entry.id);
        } else if (entry.type === 'chat') {
            await db.delete('keyvalue', `gz_chat_${entry.id}`);
        }
        await clearSyncDeletedEntry(entry.type, entry.id);
        return null;
    }

    const entity = await readCloudEntityByEntry(adapter, entry, key);
    if (!entity) {
        throw new Error(`Cloud file not found: ${entry.path}`);
    }
    if (entry.type === 'character') {
        const existing = await db.getFromStore('characters', entry.id);
        if (existing?.images) {
            entity.images = existing.images;
        } else if (!entity.images) {
            entity.images = [];
        }
        await db.put('characters', entity);
        await clearSyncDeletedEntry(entry.type, entry.id);
    } else if (entry.type === 'persona') {
        await db.put('personas', entity);
        await clearSyncDeletedEntry(entry.type, entry.id);
    } else if (entry.type === 'chat') {
        await db.saveChat(entry.id, entity);
        await clearSyncDeletedEntry(entry.type, entry.id);
    } else if (entry.type === 'lorebooks') {
        await db.set('gz_lorebooks', entity);
    } else if (entry.type === 'api_presets') {
        await db.set('gz_api_connection_presets', entity);
    } else if (entry.type === 'theme_presets') {
        await db.set('gz_theme_presets', entity);
    } else if (entry.type === 'theme_state') {
        await db.set('gz_theme_active_preset', entity);
    } else if (entry.type === 'local_storage') {
        for (const [lsKey, lsVal] of Object.entries(entity || {})) {
            if (lsKey === 'silly_cradle_presets') {
                try {
                    const cloudPresets = JSON.parse(lsVal);
                    const localRaw = localStorage.getItem('silly_cradle_presets');
                    const localPresets = localRaw ? JSON.parse(localRaw) : {};
                    for (const [pId, cloudPreset] of Object.entries(cloudPresets)) {
                        const localRegexes = localPresets[pId]?.regexes;
                        const cloudRegexes = cloudPreset.regexes;
                        if (localRegexes?.length) {
                            if (!cloudRegexes?.length) {
                                cloudPreset.regexes = localRegexes;
                            } else {
                                const cloudIds = new Set(cloudRegexes.map(r => r.id));
                                const localOnly = localRegexes.filter(r => !cloudIds.has(r.id));
                                if (localOnly.length) cloudPreset.regexes = [...cloudRegexes, ...localOnly];
                            }
                        }
                    }
                    localStorage.setItem(lsKey, JSON.stringify({ ...localPresets, ...cloudPresets }));
                } catch (e) {
                    localStorage.setItem(lsKey, lsVal);
                }
            } else if (lsKey === 'regex_scripts') {
                try {
                    const cloudScripts = JSON.parse(lsVal);
                    const localRaw = localStorage.getItem('regex_scripts');
                    const localScripts = localRaw ? JSON.parse(localRaw) : [];
                    if (!Array.isArray(cloudScripts)) {
                        localStorage.setItem(lsKey, lsVal);
                    } else if (!localScripts.length) {
                        localStorage.setItem(lsKey, lsVal);
                    } else {
                        const cloudIds = new Set(cloudScripts.map(r => r.id));
                        const localOnly = localScripts.filter(r => !cloudIds.has(r.id));
                        localStorage.setItem(lsKey, JSON.stringify([...cloudScripts, ...localOnly]));
                    }
                } catch (e) {
                    localStorage.setItem(lsKey, lsVal);
                }
            } else {
                localStorage.setItem(lsKey, lsVal);
            }
        }
    }
    return entity;
}
