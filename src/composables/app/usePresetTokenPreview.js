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

    const CHARACTER_BLOCKS = ['char_card', 'char_personality', 'char_persona', 'scenario', 'example_dialogue'];
    const NON_PRESET_BLOCKS = ['chat_history', 'first_message', 'authors_note', 'summary', 'user_persona'];

    const resolveBlockContent = (block, { includeHistory = false, includeNonPreset = true } = {}) => {
        if (!block) return '';
        const blockId = normalizeBlockId(block.id);

        if (blockId === 'chat_history') {
            if (!includeHistory) return '';
            if (!chatHistory?.value || chatHistory.value.length === 0) return '';
            return chatHistory.value.filter(m => !m.isHidden && !m.isTyping).map(m => `${m.role === 'user' ? (m.persona?.name || 'User') : (activeChatChar?.value?.name || 'Char')}: ${m.text}`).join('\n');
        }
        if (blockId === 'first_message') return '';

        if (blockId === 'authors_note') {
            if (!includeNonPreset) return '';
            return activeChatChar?.value?.authors_note || '';
        }
        if (blockId === 'summary') {
            if (!includeNonPreset) return '';
            return activeChatChar?.value?.summary || '';
        }
        if (CHARACTER_BLOCKS.includes(blockId)) {
            if (!includeNonPreset) return '';
            if (blockId === 'char_card') return activeChatChar?.value?.description || activeChatChar?.value?.desc || '';
            if (blockId === 'char_personality' || blockId === 'char_persona') return activeChatChar?.value?.personality || '';
            if (blockId === 'scenario') return activeChatChar?.value?.scenario || '';
            if (blockId === 'example_dialogue') return activeChatChar?.value?.mes_example || '';
        }

        if (blockId === 'guided_generation') return block.content || '[System Note: {{guidance}}]';
        if (blockId === 'user_persona') {
            if (!includeNonPreset) return '';
            return effectivePersona?.value?.prompt || '';
        }

        return block.content || '';
    };

    const isChatSpecific = (block) => {
        const id = normalizeBlockId(block.id);
        return ['chat_history', 'guided_generation', 'authors_note', 'summary', 'char_card', 'scenario', 'char_personality', 'char_persona', 'example_dialogue'].includes(id);
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

    function getPresetTokens(preset, _log = false) {
        if (!preset) return 0;
        let totalPresetTokens = 0;
        const blockDetails = [];
        if (preset.blocks) {
            preset.blocks.forEach(b => {
                if (!b.enabled || b.isStashed) {
                    if (_log) blockDetails.push({ id: b.id, status: 'disabled/stashed', rawLen: 0, templateLen: 0, tokens: 0 });
                    return;
                }
                const blockContent = resolveBlockContent(b, { includeNonPreset: false });
                if (!blockContent) {
                    if (_log) blockDetails.push({ id: b.id, status: 'no-content', rawLen: 0, templateLen: 0, tokens: 0 });
                    return;
                }

                let literalTemplate = blockContent;
                const sourceMacros = [
                    /\{\{description\}\}/gi,
                    /\{\{char_description\}\}/gi,
                    /\{\{scenario\}\}/gi,
                    /\{\{personality\}\}/gi,
                    /\{\{char_personality\}\}/gi,
                    /\{\{mesExamples\}\}/gi,
                    /\{\{persona\}\}/gi,
                    /\{\{summary\}\}/gi,
                    /\{\{lorebooks\}\}/gi,
                ];
                for (const re of sourceMacros) {
                    literalTemplate = literalTemplate.replace(re, '');
                }

                literalTemplate = literalTemplate
                    .replace(/{{setvar::[\s\S]*?::[\s\S]*?}}/gi, '')
                    .replace(/{{setglobalvar::[\s\S]*?::[\s\S]*?}}/gi, '');

                const charId = activeChatChar?.value?.id || 'default';
                const sessionId = activeChatChar?.value?.sessionId || 'current';
                const varsKey = `gz_vars_${charId}_${sessionId}`;
                let sessionVars = {};
                try { sessionVars = JSON.parse(localStorage.getItem(varsKey)) || {}; } catch (e) {}
                literalTemplate = literalTemplate.replace(/{{getvar::([\s\S]*?)}}/gi, (match, name) => {
                    return sessionVars[name] !== undefined ? sessionVars[name] : '';
                });
                literalTemplate = literalTemplate.replace(/{{getglobalvar::([\s\S]*?)}}/gi, (match, name) => {
                    try {
                        const raw = localStorage.getItem('gz_global_vars');
                        if (!raw) return '';
                        const parsed = JSON.parse(raw);
                        return parsed[name] !== undefined ? parsed[name] : '';
                    } catch (e) { return ''; }
                });

                const charName = activeChatChar?.value ? (activeChatChar.value.macro_name || activeChatChar.value.name) : 'Character';
                const userName = effectivePersona?.value ? effectivePersona.value.name : 'User';
                literalTemplate = literalTemplate
                    .replace(/{{char}}/gi, charName)
                    .replace(/{{user}}/gi, userName);

                const tokens = estimateTokens(literalTemplate);
                if (_log) blockDetails.push({ id: b.id, status: 'counted', rawLen: blockContent.length, templateLen: literalTemplate.length, tokens });
                totalPresetTokens += tokens;
            });
        }
        if (_log) {
            console.group('[getPresetTokens]', preset.name || preset.id);
            console.log('total:', totalPresetTokens);
            console.table(blockDetails);
            console.groupEnd();
        }
        return totalPresetTokens;
    }

    const editingPresetTokens = computed(() => getPresetTokens(currentPreset.value, true));
    const displayedEditingTokens = ref(0);

    const activePresetTokens = computed(() => {
        const id = effectivePresetId.value;
        const preset = presetState.presets[id] || presetState.presets.default_shino;
        return getPresetTokens(preset, true);
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
        const blockId = normalizeBlockId(block.id);
        const content = resolveBlockContent(block, { includeHistory: blockId === 'chat_history', includeNonPreset: true });
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
