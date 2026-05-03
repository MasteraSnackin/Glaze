import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { presetState, setPresetConnection } from '@/core/states/presetState.js';

export function usePresetConnections({ optimisticGlobalPresetId, props }) {
    function getPresetConnectionType(presetId) {
        const charId = props.activeChatChar?.id;
        const chatId = charId && props.activeChatChar?.sessionId ? `${charId}_${props.activeChatChar.sessionId}` : null;
        if (chatId && presetState.connections.chat[chatId] === presetId) return 'chat';
        if (charId && presetState.connections.character[charId] === presetId) return 'character';
        if (optimisticGlobalPresetId.value === presetId) return 'global';
        if (!optimisticGlobalPresetId.value && presetState.globalPresetId === presetId) return 'global';
        return null;
    }

    function openPresetConnections(presetId, event) {
        event.stopPropagation();
        const preset = presetState.presets[presetId];
        if (preset) {
            publishAppEvent(APP_EVENTS.nav.openConnections, { type: 'preset', id: presetId, name: preset.name });
        }
    }

    function activatePreset(presetId) {
        optimisticGlobalPresetId.value = presetId;
        setTimeout(() => {
            setPresetConnection('global', null, presetId);
            optimisticGlobalPresetId.value = null;
        }, 10);
    }

    return { getPresetConnectionType, openPresetConnections, activatePreset };
}
