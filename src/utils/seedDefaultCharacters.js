/**
 * Seeds default characters into the database on first launch.
 * Guarded by the localStorage flag 'gz_default_chars_seeded'.
 */
import { db } from '@/utils/db.js';
import { generateAllThumbnails } from '@/utils/thumbnailUtils.js';

const SEED_FLAG = 'gz_default_chars_seeded';
const SEED_VERSION = '1'; // Bump this to re-seed on new releases

/**
 * Parses character data from a PNG file's tEXt chunk (chara / ccv3 keyword).
 * @param {ArrayBuffer} buffer
 * @returns {Object|null} Parsed character JSON or null if not found.
 */
function extractCharaFromPng(buffer) {
    const dataView = new DataView(buffer);
    const uint8 = new Uint8Array(buffer);
    const decoder = new TextDecoder('utf-8');

    // Validate PNG signature
    if (uint8[0] !== 137 || uint8[1] !== 80 || uint8[2] !== 78 || uint8[3] !== 71) return null;

    let offset = 8;
    while (offset < buffer.byteLength) {
        const length = dataView.getUint32(offset);
        offset += 4;
        const type = decoder.decode(uint8.slice(offset, offset + 4));
        offset += 4;

        if (type === 'tEXt') {
            const chunk = uint8.slice(offset, offset + length);
            let nullIdx = chunk.indexOf(0);
            if (nullIdx !== -1) {
                const keyword = decoder.decode(chunk.slice(0, nullIdx));
                if (keyword === 'chara' || keyword === 'ccv3') {
                    try {
                        const b64 = decoder.decode(chunk.slice(nullIdx + 1));
                        const bin = atob(b64);
                        const bytes = new Uint8Array(bin.length);
                        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
                        return JSON.parse(new TextDecoder('utf-8').decode(bytes));
                    } catch (e) {
                        console.error('[seed] Failed to decode chara chunk:', e);
                        return null;
                    }
                }
            }
        }
        offset += length + 4; // data + CRC
    }
    return null;
}

/**
 * Normalises a raw V2/V3 card JSON into a flat character object (mirrors characterIO.js).
 */
function normalise(json) {
    let data;
    if ((json.spec === 'chara_card_v2' || json.spec === 'chara_card_v3') && json.data) {
        data = json.data;
    } else if (json.name) {
        data = json;
    } else {
        return null;
    }
    if (!data.name) data.name = 'Unknown';
    if (!data.avatar || data.avatar === 'none') data.avatar = null;
    if (!Array.isArray(data.images)) data.images = [];
    return data;
}

const DEFAULT_CHARS = [
    {
        // Path relative to the app's public root (served as a static asset)
        pngUrl: '/Walter_Simmons_Private_Investigator.png',
    }
];

export async function seedDefaultCharacters() {
    if (localStorage.getItem(SEED_FLAG) === SEED_VERSION) return;

    try {
        const existing = await db.getAll('characters');
        // Only seed if the library is completely empty (fresh install)
        if (existing && existing.length > 0) {
            localStorage.setItem(SEED_FLAG, SEED_VERSION);
            return;
        }
    } catch (e) {
        console.warn('[seed] Could not check existing characters:', e);
        return;
    }

    for (const entry of DEFAULT_CHARS) {
        try {
            const response = await fetch(entry.pngUrl);
            if (!response.ok) throw new Error(`HTTP ${response.status}`);
            const buffer = await response.arrayBuffer();

            const rawJson = extractCharaFromPng(buffer);
            if (!rawJson) throw new Error('No chara chunk found in PNG');

            const charData = normalise(rawJson);
            if (!charData) throw new Error('Could not normalise character data');

            // Store the full-size avatar as a data URL
            const blob = new Blob([buffer], { type: 'image/png' });
            const avatarDataUrl = await new Promise((resolve, reject) => {
                const reader = new FileReader();
                reader.onload = () => resolve(reader.result);
                reader.onerror = reject;
                reader.readAsDataURL(blob);
            });
            charData.avatar = avatarDataUrl;

            // Generate compressed thumbnails
            try {
                const thumbs = await generateAllThumbnails(avatarDataUrl);
                charData.thumbnail = thumbs.thumbnail;
                charData.mini_thumbnail = thumbs.mini_thumbnail;
            } catch (e) {
                console.warn('[seed] Thumbnail generation failed:', e);
            }

            await db.saveCharacter(charData);
            console.log(`[seed] Default character "${charData.name}" seeded successfully.`);
        } catch (e) {
            console.error(`[seed] Failed to seed character from ${entry.pngUrl}:`, e);
        }
    }

    localStorage.setItem(SEED_FLAG, SEED_VERSION);
}
