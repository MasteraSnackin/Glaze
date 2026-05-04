import { db } from '@/utils/db.js';

export function needsConflict(localEntry, cloudEntry) {
    return !!localEntry && !localEntry.deleted && localEntry.updatedAt > cloudEntry.updatedAt;
}

export async function getLocalConflictEntity(type, id, { getLocalCharacterWithImages, getLocalPersona, getLocalChat }) {
    if (type === 'character') return getLocalCharacterWithImages(id);
    if (type === 'persona') return getLocalPersona(id);
    if (type === 'chat') return getLocalChat(id);
    return null;
}

export function getConflictName(type, localEntity, cloudEntity, id) {
    if (type === 'character' || type === 'persona') {
        return localEntity?.name || cloudEntity?.name || id;
    }
    if (type === 'chat') {
        return getChatName(localEntity, cloudEntity, id);
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
        const existing = await db.get('characters', conflict.id);
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
