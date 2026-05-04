import { db, getSyncDeletedEntries } from '@/utils/db.js';
import { isSyncIncludingApiKeys } from '@/core/config/ProviderProfiles.js';

export const MANIFEST_VERSION = 2;

export function entryKey(type, id) {
    return `${type}:${id}`;
}

export function clone(obj) {
    return JSON.parse(JSON.stringify(obj));
}

export function generateDeviceId() {
    const stored = localStorage.getItem('gz_sync_device_id');
    if (stored) return stored;
    const id = Date.now().toString(36) + Math.random().toString(36).substr(2, 8);
    localStorage.setItem('gz_sync_device_id', id);
    return id;
}

export function getDeviceId() {
    return localStorage.getItem('gz_sync_device_id') || generateDeviceId();
}

export async function buildManifest(lastSync, deviceId) {
    return {
        version: MANIFEST_VERSION,
        deviceId: deviceId || getDeviceId(),
        lastSync: lastSync || 0,
        createdAt: Date.now(),
        entries: {}
    };
}

export async function readLocalManifestV2() {
    return (await db.get('gz_sync_manifest_v2')) || null;
}

export async function writeLocalManifestV2(manifest) {
    await db.set('gz_sync_manifest_v2', manifest);
}

export async function collectSingletonEntries() {
    const singletons = [
        { type: 'lorebooks', id: 'lorebooks', data: await db.get('gz_lorebooks') },
        { type: 'api_presets', id: 'api_presets', data: await db.get('gz_api_connection_presets') },
        { type: 'theme_presets', id: 'theme_presets', data: await db.get('gz_theme_presets') },
        { type: 'theme_state', id: 'theme_state', data: await db.get('gz_theme_active_preset') }
    ];

    const lsData = {};
    const lsKeys = [
        'silly_cradle_presets', 'silly_cradle_current_preset_id', 'gz_preset_connections',
        'regex_scripts', 'gz_active_persona_id', 'gz_persona_connections',
        'gz_lang', 'gz_theme', 'gz_chat_padding_lr', 'gz_force_mobile_layout',
        'gz_battery_saver_ui',
        'api-endpoint', 'api-max-tokens', 'api-context',
        'gz_api_provider', 'gz_api_endpoint_normalized',
        'gz_api_temp', 'gz_api_topp', 'gz_api_stream',
        'gz_api_auto_hide_images', 'gz_api_auto_hide_images_n',
        'gz_api_request_reasoning', 'gz_api_reasoning_start', 'gz_api_reasoning_end', 'gz_api_reasoning_effort',
        'gz_api_omit_temperature', 'gz_api_omit_top_p', 'gz_api_omit_reasoning', 'gz_api_omit_reasoning_effort',
        'gz_api_connect_timeout', 'gz_api_stream_timeout',
        'gz_embedding_use_same', 'gz_embedding_target', 'gz_embedding_scan_depth',
        'gz_embedding_threshold', 'gz_embedding_top_k', 'gz_embedding_max_chunk_tokens',
        'gz_embedding_enabled',
        'gz_imggen_enabled', 'gz_imggen_api_type', 'gz_imggen_endpoint', 'gz_imggen_model',
        'gz_imggen_size', 'gz_imggen_quality', 'gz_imggen_aspect_ratio', 'gz_imggen_image_size',
        'gz_imggen_naistera_model', 'gz_imggen_naistera_aspect_ratio',
        'gz_imggen_naistera_send_char_avatar', 'gz_imggen_naistera_send_user_avatar',
        'gz_imggen_routmy_model', 'gz_imggen_routmy_aspect_ratio', 'gz_imggen_routmy_image_size',
        'gz_imggen_routmy_quality', 'gz_imggen_routmy_send_char_avatar', 'gz_imggen_routmy_send_user_avatar',
        'gz_imggen_image_context_enabled', 'gz_imggen_image_context_count',
        'gz_imggen_additional_refs',
        'gz_active_llm_profile_id', 'gz_service_profile_map', 'gz_provider_profiles_migrated',
        'gz_sync_include_api_keys'
    ];
    const includeKeys = isSyncIncludingApiKeys();
    if (includeKeys) {
        lsKeys.push('api-key', 'api-model', 'gz_provider_profiles', 'gz_imggen_api_key', 'gz_imggen_naistera_api_key', 'gz_imggen_routmy_api_key');
    }
    for (const k of lsKeys) {
        const v = localStorage.getItem(k);
        if (v !== null) lsData[k] = v;
    }
    singletons.push({ type: 'local_storage', id: 'local_storage', data: Object.keys(lsData).length > 0 ? lsData : null });
    return singletons;
}

export async function buildLocalManifestV2({ computeSyncHash, cloudPath, galleryCloudPath, computeImageHash, guessImageExt }) {
    const manifest = await buildManifest(Date.now(), getDeviceId());
    const previousManifest = await readLocalManifestV2();
    const previousEntries = previousManifest?.entries || {};
    manifest.entries = {};

    const characters = await db.getAll('characters');
    for (const char of characters) {
        if (!char?.id) continue;
        const { images, ...charNoImages } = char;
        const hash = await computeSyncHash(charNoImages);
        const previousEntry = previousEntries[entryKey('character', char.id)];
        manifest.entries[entryKey('character', char.id)] = {
            type: 'character',
            id: char.id,
            path: cloudPath('character', char.id),
            updatedAt: char.updatedAt || previousEntry?.updatedAt || Date.now(),
            hash,
            deleted: false
        };

        if (Array.isArray(images)) {
            for (const img of images) {
                if (!img?.id || !img?.src) continue;
                const imgExt = guessImageExt(img.src);
                const imgHash = await computeImageHash(img.src);
                const galleryKey = entryKey('gallery', `${char.id}:${img.id}`);
                const prevImgEntry = previousEntries[galleryKey];
                manifest.entries[galleryKey] = {
                    type: 'gallery',
                    id: `${char.id}:${img.id}`,
                    charId: char.id,
                    imgId: img.id,
                    path: galleryCloudPath(char.id, img.id, imgExt),
                    ext: imgExt,
                    updatedAt: prevImgEntry?.hash === imgHash && !prevImgEntry?.deleted
                        ? prevImgEntry.updatedAt
                        : Date.now(),
                    hash: imgHash,
                    deleted: false
                };
            }
        }
    }

    const personas = await db.getAll('personas');
    for (const persona of personas) {
        if (!persona?.id) continue;
        const hash = await computeSyncHash(persona);
        const previousEntry = previousEntries[entryKey('persona', persona.id)];
        manifest.entries[entryKey('persona', persona.id)] = {
            type: 'persona',
            id: persona.id,
            path: cloudPath('persona', persona.id),
            updatedAt: persona.updatedAt || previousEntry?.updatedAt || Date.now(),
            hash,
            deleted: false
        };
    }

    const chats = await db.getChats();
    for (const [charId, chatData] of Object.entries(chats || {})) {
        const hash = await computeSyncHash(chatData);
        const previousEntry = previousEntries[entryKey('chat', charId)];
        manifest.entries[entryKey('chat', charId)] = {
            type: 'chat',
            id: charId,
            path: cloudPath('chat', charId),
            updatedAt: chatData?.updatedAt || previousEntry?.updatedAt || Date.now(),
            hash,
            deleted: false
        };
    }

    const singletons = await collectSingletonEntries();
    for (const item of singletons) {
        if (item.data === null || item.data === undefined) continue;
        const manifestKey = entryKey(item.type, item.id);
        const hash = await computeSyncHash(item.data);
        const previousEntry = previousEntries[manifestKey];
        manifest.entries[entryKey(item.type, item.id)] = {
            type: item.type,
            id: item.id,
            path: cloudPath(item.type, item.id),
            updatedAt: previousEntry?.hash === hash && !previousEntry?.deleted
                ? previousEntry.updatedAt
                : Date.now(),
            hash,
            deleted: false
        };
    }

    const deletions = await getSyncDeletedEntries();
    for (const [key, deletion] of Object.entries(deletions)) {
        manifest.entries[key] = {
            type: deletion.type,
            id: deletion.id,
            path: cloudPath(deletion.type, deletion.id),
            updatedAt: deletion.updatedAt,
            hash: null,
            deleted: true
        };
    }

    manifest.lastSync = Date.now();
    return manifest;
}

export async function readCloudManifestV2(adapter, { cloudPath, listAllFiles, ENTITY_TYPES }) {
    const manifest = await readManifest(adapter, cloudPath);
    if (!manifest) return null;
    if (manifest?.version === MANIFEST_VERSION && manifest?.entries) {
        return manifest;
    }
    if (manifest?.version === 1 && !manifest?.entries) {
        return migrateV1ManifestToV2(adapter, manifest, { cloudPath, listAllFiles, ENTITY_TYPES });
    }
    return null;
}

async function readManifest(adapter, cloudPath) {
    try {
        const result = await adapter.download(cloudPath('manifest', 'manifest'));
        if (result) {
            return JSON.parse(result.data);
        }
        return null;
    } catch {
        return null;
    }
}

async function migrateV1ManifestToV2(adapter, v1Manifest, { cloudPath, listAllFiles, ENTITY_TYPES }) {
    const CLOUD_BASE = '/Glaze';
    const cloudFiles = await listAllFiles(adapter);
    const entries = {};

    for (const file of cloudFiles) {
        const filePath = file.path_display || file.path || '';
        const cloudModified = file.serverModified ? new Date(file.serverModified).getTime() : Date.now();

        let type = null;
        let id = null;

        if (filePath.startsWith(`${CLOUD_BASE}/characters/`)) {
            type = ENTITY_TYPES.CHARACTER;
            id = filePath.replace(`${CLOUD_BASE}/characters/`, '').replace(/\.(enc|json)$/, '');
        } else if (filePath.startsWith(`${CLOUD_BASE}/personas/`)) {
            type = ENTITY_TYPES.PERSONA;
            id = filePath.replace(`${CLOUD_BASE}/personas/`, '').replace(/\.(enc|json)$/, '');
        } else if (filePath.startsWith(`${CLOUD_BASE}/chats/`)) {
            type = ENTITY_TYPES.CHAT;
            id = filePath.replace(`${CLOUD_BASE}/chats/`, '').replace(/\.(enc|json)$/, '');
        } else if (filePath.startsWith(`${CLOUD_BASE}/`)) {
            const fileName = filePath.replace(`${CLOUD_BASE}/`, '').replace(/\.(enc|json)$/, '');
            if (fileName === 'lorebooks') { type = ENTITY_TYPES.LOREBOOKS; id = 'lorebooks'; }
            else if (fileName === 'api_presets') { type = ENTITY_TYPES.API_PRESETS; id = 'api_presets'; }
            else if (fileName === 'theme_presets') { type = ENTITY_TYPES.THEME_PRESETS; id = 'theme_presets'; }
            else if (fileName === 'theme_state') { type = ENTITY_TYPES.THEME_STATE; id = 'theme_state'; }
            else if (fileName === 'local_storage') { type = ENTITY_TYPES.LOCAL_STORAGE; id = 'local_storage'; }
            else { type = ENTITY_TYPES.LOCAL_STORAGE; id = fileName; }
        }

        if (!type || !id) continue;

        const entryKeyStr = entryKey(type, id);
        entries[entryKeyStr] = {
            type,
            id,
            path: filePath,
            updatedAt: cloudModified,
            hash: null,
            deleted: false
        };
    }

    const migrated = {
        version: MANIFEST_VERSION,
        deviceId: v1Manifest.deviceId || getDeviceId(),
        lastSync: v1Manifest.lastSync || 0,
        createdAt: v1Manifest.createdAt || Date.now(),
        entries
    };

    await adapter.upload(cloudPath('manifest', 'manifest'), JSON.stringify(migrated));
    return migrated;
}
