import { ref, computed, watch, shallowRef } from 'vue';
import { estimateTokens } from '@/utils/tokenizer.js';
import { replaceMacros } from '@/utils/macroEngine.js';
import { normalizeBlockId } from '@/utils/presetBlockIds.js';
import { presetState } from '@/core/states/presetState.js';

export function usePresetTokenPreview({
    currentPreset,
    editingPresetId,
    editingBlockId,
    effectivePresetId,
    activeChatChar,
    chatHistory,
    effectivePersona,
    isGenerating
}) {
    const activeEditBlock = computed(() => {
        if (!editingBlockId.value) return null;
        return currentPreset.value?.blocks?.find(b => b.id === editingBlockId.value);
    });

    const resolveBlockContent = (block) => {
        if (!block) return '';
        const blockId = normalizeBlockId(block.id);

        if (blockId === 'chat_history') {
            if (!chatHistory?.value || chatHistory.value.length === 0) return '';
            return chatHistory.value.map(m => `${m.role === 'user' ? (m.persona?.name || 'User') : (activeChatChar?.value?.name || 'Char')}: ${m.text}`).join('\n');
        }

        if (blockId === 'guided_generation') return block.content || '[System Note: {{guidance}}]';
        if (blockId === 'authors_note') return activeChatChar?.value?.authors_note || '';
        if (blockId === 'summary') return activeChatChar?.value?.summary || '';

        if (blockId === 'user_persona') return effectivePersona?.value?.prompt || '';
        if (blockId === 'char_card') return activeChatChar?.value?.description || activeChatChar?.value?.desc || '';
        if (blockId === 'char_personality' || blockId === 'char_persona') return activeChatChar?.value?.personality || '';
        if (blockId === 'scenario') return activeChatChar?.value?.scenario || '';
        if (blockId === 'example_dialogue') return activeChatChar?.value?.mes_example || '';
        if (blockId === 'first_message') return activeChatChar?.value?.first_mes || '';

        return block.content || '';
    };

    const isChatSpecific = (block) => {
        const id = normalizeBlockId(block.id);
        return ['chat_history', 'guided_generation', 'authors_note', 'summary', 'char_card', 'scenario', 'char_personality', 'char_persona', 'example_dialogue', 'first_message'].includes(id);
    };

    const shouldShowTokens = (block) => {
        const id = normalizeBlockId(block.id);
        if (['worldInfoBefore', 'worldInfoAfter', 'wi_before', 'wi_after'].includes(id)) return false;
        if (isChatSpecific(block)) return !!activeChatChar?.value;
        return true;
    };

    const extendedReplaceMacros = (text) => {
        if (!text) return '';
        let res = replaceMacros(text, activeChatChar?.value, effectivePersona?.value);

        if (activeChatChar?.value) {
            res = res.replace(/{{scenario}}/gi, activeChatChar.value.scenario || '')
                     .replace(/{{personality}}/gi, activeChatChar.value.personality || '')
                     .replace(/{{description}}/gi, activeChatChar.value.description || '')
                     .replace(/{{char_description}}/gi, activeChatChar.value.description || '')
                     .replace(/{{char_personality}}/gi, activeChatChar.value.personality || '');
        }
        if (effectivePersona?.value) {
            res = res.replace(/{{persona}}/gi, effectivePersona.value.prompt || '');
        }
        return res;
    };

    function getPresetTokens(preset) {
        if (!preset) return 0;
        let content = "";
        if (preset.impersonationPrompt) {
            content += preset.impersonationPrompt + "\n";
        }
        if (preset.blocks) {
            preset.blocks.forEach(b => {
                if (b.enabled && !b.isStashed) {
                    const blockContent = resolveBlockContent(b);
                    if (blockContent) {
                        content += blockContent + "\n";
                    }
                }
            });
        }
        return estimateTokens(extendedReplaceMacros(content));
    }

    const editingPresetTokens = computed(() => getPresetTokens(currentPreset.value));
    const displayedEditingTokens = ref(0);

    const activePresetTokens = computed(() => {
        const id = effectivePresetId.value;
        const preset = presetState.presets[id] || presetState.presets.default_shino;
        return getPresetTokens(preset);
    });
    const displayedActiveTokens = ref(0);

    const globalTokens = computed(() => getPresetTokens(presetState.presets[presetState.globalPresetId] || presetState.presets.default_shino));
    const charTokens = computed(() => {
        const charId = activeChatChar?.value?.id;
        const id = charId ? presetState.connections.character[charId] : null;
        return id ? getPresetTokens(presetState.presets[id]) : 0;
    });
    const chatTokens = computed(() => {
        const charId = activeChatChar?.value?.id;
        const chatId = charId && activeChatChar?.value?.sessionId ? `${charId}_${activeChatChar.value.sessionId}` : null;
        const id = chatId ? presetState.connections.chat[chatId] : null;
        return id ? getPresetTokens(presetState.presets[id]) : 0;
    });

    function setupAnimateTokens(targetComputed, targetRef) {
        watch(targetComputed, (newVal, oldVal) => {
            if (isGenerating?.value) return;
            if (oldVal === undefined) {
                targetRef.value = newVal;
                return;
            }
            const start = targetRef.value;
            const end = newVal;
            const duration = 300;
            const startTime = performance.now();
            const animate = (currentTime) => {
                const elapsed = currentTime - startTime;
                const progress = Math.min(elapsed / duration, 1);
                const ease = 1 - Math.pow(1 - progress, 3);
                targetRef.value = Math.round(start + (end - start) * ease);
                if (progress < 1) requestAnimationFrame(animate);
            };
            requestAnimationFrame(animate);
        }, { immediate: true });
    }

    setupAnimateTokens(activePresetTokens, displayedActiveTokens);
    setupAnimateTokens(editingPresetTokens, displayedEditingTokens);

    const getBlockTokens = (blockOrContent) => {
        if (typeof blockOrContent === 'string') {
            return estimateTokens(extendedReplaceMacros(blockOrContent));
        }
        const block = blockOrContent;
        if (!block) return 0;
        const content = resolveBlockContent(block);
        if (!content) return 0;
        return estimateTokens(extendedReplaceMacros(content));
    };

    const presetTokenCache = shallowRef({});

    let _cacheTimer = null;
    function refreshTokenCache() {
        if (_cacheTimer) return;
        _cacheTimer = setTimeout(() => {
            _cacheTimer = null;
            const cache = {};
            for (const [id, preset] of Object.entries(presetState.presets)) {
                cache[id] = getPresetTokens(preset);
            }
            presetTokenCache.value = cache;
        }, 200);
    }

    watch(
        () => presetState.presets,
        () => refreshTokenCache(),
        { deep: false }
    );

    refreshTokenCache();

    return {
        activeEditBlock,
        resolveBlockContent,
        isChatSpecific,
        shouldShowTokens,
        extendedReplaceMacros,
        getPresetTokens,
        editingPresetTokens,
        displayedEditingTokens,
        activePresetTokens,
        displayedActiveTokens,
        globalTokens,
        charTokens,
        chatTokens,
        getBlockTokens,
        presetTokenCache,
        refreshTokenCache
    };
}
