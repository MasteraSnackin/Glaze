import { db } from '@/utils/db.js';

export async function dataUrlToBinary(dataUrl) {
    const res = await fetch(dataUrl);
    return await res.arrayBuffer();
}

export async function computeImageHash(dataUrl) {
    const binary = await dataUrlToBinary(dataUrl);
    const digest = await crypto.subtle.digest('SHA-256', binary);
    return Array.from(new Uint8Array(digest)).map(b => b.toString(16).padStart(2, '0')).join('');
}

export function guessImageExt(dataUrl) {
    const match = dataUrl.match(/^data:image\/([\w+]+)/);
    if (!match) return 'png';
    const raw = match[1].toLowerCase();
    if (raw === 'jpeg') return 'jpg';
    return raw;
}

export async function computeBinaryHash(arrayBuffer) {
    const digest = await crypto.subtle.digest('SHA-256', arrayBuffer);
    return Array.from(new Uint8Array(digest)).map(b => b.toString(16).padStart(2, '0')).join('');
}

async function getLocalCharacterWithImages(id) {
    return (await db.getFromStore('characters', id)) || null;
}

async function arrayBufferToDataUrl(arrayBuffer) {
    const blob = new Blob([arrayBuffer]);
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = reject;
        reader.readAsDataURL(blob);
    });
}

export async function applyGalleryEntriesForChar(adapter, entries, charId, localEntries, onConflict, { entryKey, ENTITY_TYPES }) {
    const char = await getLocalCharacterWithImages(charId);
    if (!char) return { applied: entries.length, conflicts: [] };
    if (!Array.isArray(char.images)) char.images = [];

    const localHashes = new Map();
    for (const img of char.images) {
        if (img?.src) {
            try {
                const h = await computeImageHash(img.src);
                localHashes.set(h, img);
            } catch {}
        }
    }

    let applied = 0;
    const galleryConflicts = [];
    for (const cloudEntry of entries) {
        const localEntry = localEntries?.[entryKey(ENTITY_TYPES.GALLERY, cloudEntry.id)];
        if (localEntry && !localEntry.deleted && localEntry.updatedAt > cloudEntry.updatedAt) {
            const conflict = {
                type: ENTITY_TYPES.GALLERY,
                id: cloudEntry.id,
                name: `Gallery: ${cloudEntry.imgId}`,
                charId,
                imgId: cloudEntry.imgId,
                local: { imgId: localEntry.imgId, hash: localEntry.hash, updatedAt: localEntry.updatedAt },
                cloud: { imgId: cloudEntry.imgId, hash: cloudEntry.hash, updatedAt: cloudEntry.updatedAt },
                cloudModified: cloudEntry.updatedAt
            };
            galleryConflicts.push(conflict);
            if (onConflict) onConflict(conflict);
            continue;
        }

        try {
            if (cloudEntry.deleted) {
                const localImg = char.images.find(im => im.id === cloudEntry.imgId);
                if (localImg?.src && localEntry && !localEntry.deleted) {
                    galleryConflicts.push({
                        type: ENTITY_TYPES.GALLERY,
                        id: cloudEntry.id,
                        name: `Gallery: ${cloudEntry.imgId}`,
                        charId,
                        imgId: cloudEntry.imgId,
                        local: { imgId: localEntry.imgId, hash: localEntry.hash, updatedAt: localEntry.updatedAt },
                        cloud: { imgId: cloudEntry.imgId, hash: null, updatedAt: cloudEntry.updatedAt, deleted: true },
                        cloudModified: cloudEntry.updatedAt
                    });
                    if (onConflict) onConflict(galleryConflicts[galleryConflicts.length - 1]);
                } else {
                    char.images = char.images.filter(im => im.id !== cloudEntry.imgId);
                    applied++;
                }
                continue;
            }

            const binary = await adapter.downloadBinary(cloudEntry.path);
            if (!binary) continue;

            const cloudHash = await computeBinaryHash(binary);
            const existingByIdIdx = char.images.findIndex(im => im.id === cloudEntry.imgId);

            if (existingByIdIdx >= 0) {
                const dataUrl = await arrayBufferToDataUrl(binary);
                const old = char.images[existingByIdIdx];
                char.images[existingByIdIdx] = { id: cloudEntry.imgId, src: dataUrl, name: old?.name || '', thumbnail: null };
                applied++;
            } else {
                const existingByHash = localHashes.get(cloudHash);
                if (existingByHash) {
                    const dataUrl = await arrayBufferToDataUrl(binary);
                    const existingIdx = char.images.findIndex(im => im.id === existingByHash.id);
                    if (existingIdx >= 0) {
                        char.images[existingIdx] = { id: cloudEntry.imgId, src: dataUrl, name: char.images[existingIdx]?.name || '', thumbnail: null };
                    } else {
                        char.images.push({ id: cloudEntry.imgId, src: dataUrl, name: '', thumbnail: null });
                    }
                    localHashes.delete(cloudHash);
                    localHashes.set(cloudHash, { id: cloudEntry.imgId });
                    applied++;
                } else {
                    const dataUrl = await arrayBufferToDataUrl(binary);
                    char.images.push({ id: cloudEntry.imgId, src: dataUrl, name: '', thumbnail: null });
                    localHashes.set(cloudHash, { id: cloudEntry.imgId });
                    applied++;
                }
            }
        } catch (e) {
            console.warn(`[sync] Gallery entry ${cloudEntry.imgId} for char ${charId} failed:`, e);
        }
    }

    await db.put('characters', char);
    return { applied, conflicts: galleryConflicts };
}

export async function removeGalleryEntryFromChar(charId, imgId) {
    const char = await getLocalCharacterWithImages(charId);
    if (char?.images) {
        char.images = char.images.filter(im => im.id !== imgId);
        await db.put('characters', char);
    }
}
