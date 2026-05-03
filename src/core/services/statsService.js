import { db } from '@/utils/db.js';

const STATS_MIGRATED_KEY = 'gz_stats_migrated';

// Generic helper to get a stat
const getStat = (key) => parseInt(localStorage.getItem(key) || '0', 10);
// Generic helper to set a stat
const setStat = (key, val) => localStorage.setItem(key, val);
// Generic helper to add to a stat
const addStat = (key, amount) => setStat(key, getStat(key) + amount);

/**
 * Returns the current stats for the entire app.
 */
export const getGlobalStats = () => {
    return {
        messages: getStat('gz_stat_global_messages'),
        tokens: getStat('gz_stat_global_tokens'),
        characters: getStat('gz_stat_global_characters'),
        regenerations: getStat('gz_stat_global_regenerations'),
        deleted: getStat('gz_stat_global_deleted'),
        timeSpent: getStat('gz_time_app'),
        firstMessage: localStorage.getItem('gz_stat_global_first_msg') || '-'
    };
};

/**
 * Returns the current stats for a specific character.
 */
export const getCharStats = (charId) => {
    if (!charId) return null;
    return {
        messages: getStat(`gz_stat_char_${charId}_messages`),
        tokens: getStat(`gz_stat_char_${charId}_tokens`),
        characters: getStat(`gz_stat_char_${charId}_characters`),
        regenerations: getStat(`gz_stat_char_${charId}_regenerations`),
        deleted: getStat(`gz_deleted_char_${charId}`), // Keep existing key for compatibility
        timeSpent: getStat(`gz_time_char_${charId}`), // Keep existing key for compatibility
        firstMessage: localStorage.getItem(`gz_stat_char_${charId}_first_msg`) || '-'
    };
};

/**
 * Returns the current stats for a specific chat session of a character.
 */
export const getChatStats = (charId, sessionId) => {
    if (!charId || !sessionId) return null;
    return {
        messages: getStat(`gz_stat_chat_${charId}_${sessionId}_messages`),
        tokens: getStat(`gz_stat_chat_${charId}_${sessionId}_tokens`),
        characters: getStat(`gz_stat_chat_${charId}_${sessionId}_characters`),
        regenerations: getStat(`gz_stat_chat_${charId}_${sessionId}_regenerations`),
        deleted: getStat(`gz_deleted_chat_${charId}_${sessionId}`), // Keep existing key for compatibility
        timeSpent: getStat(`gz_time_chat_${charId}_${sessionId}`), // Keep existing key for compatibility
        firstMessage: localStorage.getItem(`gz_stat_chat_${charId}_${sessionId}_first_msg`) || '-'
    };
};

/**
 * Adds a new message's stats to the persistent counters.
 */
export const addMessageStats = (charId, sessionId, tokens, chars, timestamp) => {
    if (!charId || !sessionId) return;

    // Messages
    addStat('gz_stat_global_messages', 1);
    addStat(`gz_stat_char_${charId}_messages`, 1);
    addStat(`gz_stat_chat_${charId}_${sessionId}_messages`, 1);

    // Tokens
    addStat('gz_stat_global_tokens', tokens);
    addStat(`gz_stat_char_${charId}_tokens`, tokens);
    addStat(`gz_stat_chat_${charId}_${sessionId}_tokens`, tokens);

    // Characters
    addStat('gz_stat_global_characters', chars);
    addStat(`gz_stat_char_${charId}_characters`, chars);
    addStat(`gz_stat_chat_${charId}_${sessionId}_characters`, chars);

    // Update first message timestamps if not set
    if (!localStorage.getItem('gz_stat_global_first_msg') && timestamp) {
        localStorage.setItem('gz_stat_global_first_msg', timestamp.toString());
    }
    if (!localStorage.getItem(`gz_stat_char_${charId}_first_msg`) && timestamp) {
        localStorage.setItem(`gz_stat_char_${charId}_first_msg`, timestamp.toString());
    }
    if (!localStorage.getItem(`gz_stat_chat_${charId}_${sessionId}_first_msg`) && timestamp) {
        localStorage.setItem(`gz_stat_chat_${charId}_${sessionId}_first_msg`, timestamp.toString());
    }
};

/**
 * Adds stats from a regeneration/swipe.
 */
export const addRegenerationStats = (charId, sessionId, tokens, chars) => {
    if (!charId || !sessionId) return;

    // Incremental tokens/chars from the swipe
    addStat('gz_stat_global_tokens', tokens);
    addStat(`gz_stat_char_${charId}_tokens`, tokens);
    addStat(`gz_stat_chat_${charId}_${sessionId}_tokens`, tokens);

    addStat('gz_stat_global_characters', chars);
    addStat(`gz_stat_char_${charId}_characters`, chars);
    addStat(`gz_stat_chat_${charId}_${sessionId}_characters`, chars);

    // Add regeneration count
    addStat('gz_stat_global_regenerations', 1);
    addStat(`gz_stat_char_${charId}_regenerations`, 1);
    addStat(`gz_stat_chat_${charId}_${sessionId}_regenerations`, 1);
};

/**
 * Increments deletion counters. Does NOT subtract from messages/tokens 
 * to preserve lifetime generation stats even if chats are deleted.
 */
export const addDeletedStats = (charId, sessionId, count) => {
    if (!charId || !sessionId) return;

    addStat('gz_stat_global_deleted', count);
    addStat(`gz_deleted_char_${charId}`, count);
    addStat(`gz_deleted_chat_${charId}_${sessionId}`, count);
};

/**
 * Scans the database once to hydrate stats for existing chats.
 */
export const migrateStatsIfNeeded = async () => {
    if (localStorage.getItem(STATS_MIGRATED_KEY) === '1') return;

    console.log('[statsService] Migrating database stats to persistent counters...');

    let globalFirstMsg = Infinity;
    let globalDeleted = 0;

    // Gather global deleted from legacy localStorage keys since it already exists
    for (let i = 0; i < localStorage.length; i++) {
        const key = localStorage.key(i);
        if (key && key.startsWith('gz_deleted_char_')) {
            globalDeleted += parseInt(localStorage.getItem(key) || '0', 10);
        }
    }
    setStat('gz_stat_global_deleted', globalDeleted);

    const allChatsMap = await db.getChats();
    for (const [charId, chatData] of Object.entries(allChatsMap)) {
        if (!chatData || !chatData.sessions) continue;

        let charFirstMsg = Infinity;

        for (const [sessionId, session] of Object.entries(chatData.sessions)) {
            if (!session) continue;

            let sessionFirstMsg = Infinity;

            // Loop messages
            for (const msg of session) {
                if (!msg) continue;

                const tokens = msg.tokens || 0;
                const chars = msg.text?.length || 0;
                const regens = Math.max(0, (msg.swipes?.length || 1) - 1);
                const ts = msg.timestamp || Infinity;

                if (ts < sessionFirstMsg) sessionFirstMsg = ts;
                if (ts < charFirstMsg) charFirstMsg = ts;
                if (ts < globalFirstMsg) globalFirstMsg = ts;

                // Messages
                addStat('gz_stat_global_messages', 1);
                addStat(`gz_stat_char_${charId}_messages`, 1);
                addStat(`gz_stat_chat_${charId}_${sessionId}_messages`, 1);

                // Tokens
                addStat('gz_stat_global_tokens', tokens);
                addStat(`gz_stat_char_${charId}_tokens`, tokens);
                addStat(`gz_stat_chat_${charId}_${sessionId}_tokens`, tokens);

                // Characters
                addStat('gz_stat_global_characters', chars);
                addStat(`gz_stat_char_${charId}_characters`, chars);
                addStat(`gz_stat_chat_${charId}_${sessionId}_characters`, chars);

                // Regenerations
                addStat('gz_stat_global_regenerations', regens);
                addStat(`gz_stat_char_${charId}_regenerations`, regens);
                addStat(`gz_stat_chat_${charId}_${sessionId}_regenerations`, regens);

                // Backfill tokens/chars from previous swipes just in case we want thorough historical regeneration accuracy
                // In earlier versions, `msg.tokens` only accounted for current swipe.
                if (msg.swipes && msg.swipes.length > 1) {
                    for (let i = 0; i < msg.swipes.length; i++) {
                        if (i === msg.swipeId) continue; // already counted above
                        const sText = msg.swipes[i] || '';
                        // Approximation: historical tokens not saved per swipe, assume 4 chars = 1 token
                        const sChars = sText.length;
                        const sTokens = Math.ceil(sChars / 4);

                        addStat('gz_stat_global_tokens', sTokens);
                        addStat(`gz_stat_char_${charId}_tokens`, sTokens);
                        addStat(`gz_stat_chat_${charId}_${sessionId}_tokens`, sTokens);

                        addStat('gz_stat_global_characters', sChars);
                        addStat(`gz_stat_char_${charId}_characters`, sChars);
                        addStat(`gz_stat_chat_${charId}_${sessionId}_characters`, sChars);
                    }
                }
            }

            if (sessionFirstMsg !== Infinity) localStorage.setItem(`gz_stat_chat_${charId}_${sessionId}_first_msg`, sessionFirstMsg.toString());
        }

        if (charFirstMsg !== Infinity) localStorage.setItem(`gz_stat_char_${charId}_first_msg`, charFirstMsg.toString());
    }

    if (globalFirstMsg !== Infinity) localStorage.setItem('gz_stat_global_first_msg', globalFirstMsg.toString());

    localStorage.setItem(STATS_MIGRATED_KEY, '1');
    console.log('[statsService] Stats migration completed successfully.');
};
