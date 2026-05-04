import { db } from '@/utils/db.js';

export function needsConflict(localEntry, cloudEntry) {
    return !!localEntry && !localEntry.deleted && localEntry.updatedAt > cloudEntry.updatedAt;
}

export async function getLocalConflictEntity(type, id, { getLocalCharacterWithImages, getLocalPersona, getLocalChat }) {
    if (type === 'character') return getLocalCharacterWithImages(id);
    if (type === 'persona') return getLocalPersona(id);
    if (type === 'chat') return getLocalChat(id);
    if (type === 'lorebooks') return await db.get('gz_lorebooks');
    if (type === 'api_presets') return await db.get('gz_api_connection_presets');
    if (type === 'theme_presets') return await db.get('gz_theme_presets');
    if (type === 'theme_state') return await db.get('gz_theme_active_preset');
    if (type === 'local_storage') {
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
            'gz_sync_include_api_keys',
            'api-key', 'api-model', 'gz_provider_profiles', 'gz_imggen_api_key', 'gz_imggen_naistera_api_key', 'gz_imggen_routmy_api_key'
        ];
        const data = {};
        for (const k of lsKeys) {
            const v = localStorage.getItem(k);
            if (v !== null) data[k] = v;
        }
        return Object.keys(data).length > 0 ? data : null;
    }
    return null;
}

export function getConflictName(type, localEntity, cloudEntity, id) {
    if (type === 'character' || type === 'persona') {
        return localEntity?.name || cloudEntity?.name || id;
    }
    if (type === 'chat') {
        return getChatName(localEntity, cloudEntity, id);
    }
    if (type === 'gallery') {
        return `Gallery: ${id}`;
    }
    if (type === 'lorebooks') {
        const names = extractNames(localEntity, cloudEntity);
        return names ? `Lorebooks: ${names}` : 'Lorebooks';
    }
    if (type === 'api_presets') {
        const names = extractPresetNames(localEntity, cloudEntity);
        return names ? `API Presets: ${names}` : 'API Presets';
    }
    if (type === 'theme_presets') {
        const names = extractPresetNames(localEntity, cloudEntity);
        return names ? `Theme Presets: ${names}` : 'Theme Presets';
    }
    if (type === 'theme_state') {
        return 'Theme State';
    }
    if (type === 'local_storage') {
        const localKeys = localEntity ? Object.keys(localEntity) : [];
        const cloudKeys = cloudEntity ? Object.keys(cloudEntity) : [];
        const diffKeys = [...new Set([...localKeys, ...cloudKeys])].filter(k => {
            const lv = localEntity?.[k];
            const cv = cloudEntity?.[k];
            return lv !== cv;
        });
        if (diffKeys.length > 0 && diffKeys.length <= 3) {
            return `Settings: ${diffKeys.join(', ')}`;
        }
        return diffKeys.length > 0 ? `Settings: ${diffKeys.length} changed` : 'Settings';
    }
    return id;
}

function getChatName(localChat, cloudChat, charId) {
    const msgs = cloudChat?.messages || localChat?.messages || [];
    if (msgs.length > 0) {
        const first = msgs[0];
        const text = first.mes || first.content || '';
        const preview = text.substring(0, 40).replace(/\n/g, ' ');
        return preview || charId;
    }
    return charId;
}

function extractNames(localEntity, cloudEntity) {
    const items = localEntity || cloudEntity;
    if (!Array.isArray(items)) return null;
    const names = items.map(i => i.name || i.id).filter(Boolean).slice(0, 3);
    if (names.length === 0) return null;
    const suffix = items.length > 3 ? ` (+${items.length - 3})` : '';
    return names.join(', ') + suffix;
}

function extractPresetNames(localEntity, cloudEntity) {
    const obj = localEntity || cloudEntity;
    if (!obj || typeof obj !== 'object') return null;
    const entries = Array.isArray(obj) ? obj : Object.values(obj);
    const names = entries.map(i => i.name || i.id).filter(Boolean).slice(0, 3);
    if (names.length === 0) return null;
    const suffix = entries.length > 3 ? ` (+${entries.length - 3})` : '';
    return names.join(', ') + suffix;
}

export async function resolveConflict(conflict, choice, { ENTITY_TYPES, getLocalCharacterWithImages }) {
    if (conflict.type === ENTITY_TYPES.GALLERY) {
        if (choice === 'local') return null;
        const char = await getLocalCharacterWithImages(conflict.charId);
        if (!char) return null;
        return char;
    }
    const entity = choice === 'cloud' ? conflict.cloud : conflict.local;
    if (choice === 'cloud' && !entity) {
        if (conflict.type === ENTITY_TYPES.CHARACTER) {
            await db.delete('characters', conflict.id);
        } else if (conflict.type === ENTITY_TYPES.PERSONA) {
            await db.delete('personas', conflict.id);
        } else if (conflict.type === ENTITY_TYPES.CHAT) {
            await db.delete('keyvalue', `gz_chat_${conflict.id}`);
        }
        return null;
    }
    if (conflict.type === ENTITY_TYPES.CHARACTER) {
        const existing = await db.getFromStore('characters', conflict.id);
        if (existing?.images && !entity.images) {
            entity.images = existing.images;
        }
        await db.put('characters', entity);
    } else if (conflict.type === ENTITY_TYPES.PERSONA) {
        await db.put('personas', entity);
    } else if (conflict.type === ENTITY_TYPES.CHAT) {
        await db.saveChat(conflict.id, entity);
    }
    return entity;
}
