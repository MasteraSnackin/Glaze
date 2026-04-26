import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';

export function restoreVisibleSwipeState(messages = []) {
    if (!Array.isArray(messages)) return [];

    return messages.map(msg => {
        if (!msg || !Array.isArray(msg.swipesMeta)) return msg;
        if (msg.isTyping) return msg;

        const swipeIndex = msg.swipeId || 0;
        const swipeMeta = msg.swipesMeta[swipeIndex];
        if (!swipeMeta) return msg;

        let nextMsg = msg;

        if (msg.reasoning == null && swipeMeta.reasoning != null) { // eslint-disable-line eqeqeq
            nextMsg = { ...nextMsg, reasoning: swipeMeta.reasoning };
        }
        if (nextMsg.genTime == null && swipeMeta.genTime != null) { // eslint-disable-line eqeqeq
            nextMsg = { ...nextMsg, genTime: swipeMeta.genTime };
        }
        if ((nextMsg.tokens == null || nextMsg.tokens === 0) && swipeMeta.tokens != null) { // eslint-disable-line eqeqeq
            nextMsg = { ...nextMsg, tokens: swipeMeta.tokens };
        }

        return nextMsg;
    });
}

export function useChatMessageDisplay(activeChatChar, allPersonas) {
    function getAvatar(msg) {
        if (msg.role === 'user') {
            if (msg.persona?.id) {
                const p = allPersonas?.value?.find(p => p.id === msg.persona.id);
                if (p?.avatar) return p.avatar;
            }
            return msg.persona?.avatar || null;
        }
        return activeChatChar.value?.avatar || null;
    }

    function getAvatarLetter(msg) {
        if (msg.role === 'user') return (msg.persona?.name?.[0] || "U").toUpperCase();
        return (activeChatChar.value?.name?.[0] || "?").toUpperCase();
    }

    function getAvatarColor(msg) {
        if (msg.role === 'user') return 'var(--vk-blue)';
        return activeChatChar.value?.color || '#ccc';
    }

    function getDisplayName(msg) {
        if (msg.role === 'user') return msg.persona?.name || "User";
        return activeChatChar.value?.name || "Character";
    }

    function openAvatar(msg) {
        const src = getAvatar(msg);
        if (src) {
            const name = getDisplayName(msg);
            const description = "";
            publishAppEvent(APP_EVENTS.nav.triggerOpenImage, { src, name, description, onCloseCallback: null });
        }
    }

    return {
        getAvatar,
        getAvatarLetter,
        getAvatarColor,
        getDisplayName,
        openAvatar
    };
}
