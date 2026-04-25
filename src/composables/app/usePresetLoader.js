import { watch } from 'vue';
import { initPresetState, presetState } from '@/core/states/presetState.js';
import { mandatoryBlocks } from '@/core/services/presetImportService.js';
import { logger } from '@/utils/logger.js';

export function usePresetLoader({ currentPreset }) {
    async function loadPresets() {
        await initPresetState();

        logger.debug('[GenerationView] loadPresets: Checking commands for', Object.keys(presetState.presets).length, 'presets');
        for (const key in presetState.presets) {
            const preset = presetState.presets[key];
            if (preset.reasoningEnabled === undefined) preset.reasoningEnabled = false;
            if (preset.reasoningEffort === undefined) preset.reasoningEffort = 'medium';
            if (preset.parseInlineReasoning === undefined) preset.parseInlineReasoning = false;
            if (preset.mergePrompts === undefined) preset.mergePrompts = false;
            if (preset.mergeRole === undefined) preset.mergeRole = 'system';
            if (preset.noAssistant === undefined) preset.noAssistant = false;
            if (preset.stopString === undefined) preset.stopString = '';
            if (preset.userPrefix === undefined) preset.userPrefix = '';
            if (preset.charPrefix === undefined) preset.charPrefix = '';
            if (preset.squashRole === undefined || preset.squashRole === '') preset.squashRole = 'assistant';
            if (preset.author === undefined) preset.author = '';
            if (preset.image === undefined) preset.image = '';
            if (preset.summaryPrompt === undefined) {
                preset.summaryPrompt = 'Summarize the following roleplay conversation concisely, focusing on the current situation and key events:\n\n{{history}}\n\nSummary:';
            }
            if (preset.guidedGenerationPrompt === undefined) preset.guidedGenerationPrompt = '[Generate your next reply according to these instructions: {{guidance}}]';
            if (preset.guidedImpersonationPrompt === undefined) preset.guidedImpersonationPrompt = '[Instead of replying for {{char}}, impersonate {{user}} according to these instructions: {{guidance}}]';

            ensureMandatoryBlocks(preset);
        }
    }

    function ensureMandatoryBlocks(preset) {
        const blocks = preset.blocks;
        if (!blocks) return;

        mandatoryBlocks.forEach(mb => {
            if (!blocks.find(b => b.id === mb.id)) {
                if (mb.id === 'chat_history') {
                    blocks.push({ ...mb });
                } else {
                    let insertIndex = blocks.length;
                    const myIndex = mandatoryBlocks.findIndex(m => m.id === mb.id);
                    if (myIndex > 0) {
                        const prevId = mandatoryBlocks[myIndex - 1].id;
                        const prevIdxInPreset = blocks.findIndex(b => b.id === prevId);
                        if (prevIdxInPreset !== -1) insertIndex = prevIdxInPreset + 1;
                    } else {
                        for (let i = myIndex + 1; i < mandatoryBlocks.length; i++) {
                            const nextIdx = blocks.findIndex(b => b.id === mandatoryBlocks[i].id);
                            if (nextIdx !== -1) { insertIndex = nextIdx; break; }
                        }
                    }
                    blocks.splice(insertIndex, 0, { ...mb });
                }
            }
        });

        if (!blocks.find(b => b.id === 'summary')) {
            const historyIdx = blocks.findIndex(b => b.id === 'chat_history');
            const insertIdx = historyIdx !== -1 ? historyIdx : blocks.length;
            blocks.splice(insertIdx, 0, { id: 'summary', name: 'Summary', role: 'system', content: '', enabled: true, isStatic: true, i18n: 'magic_summary', depth: 4, insertion_mode: 'relative', prefix: 'Summary: ' });
        }
        if (!blocks.find(b => b.id === 'authors_note')) {
            const historyIdx = blocks.findIndex(b => b.id === 'chat_history');
            const insertIdx = historyIdx !== -1 ? historyIdx + 1 : blocks.length;
            blocks.splice(insertIdx, 0, { id: 'authors_note', name: "Author's Note", role: 'system', content: '', enabled: true, isStatic: true, i18n: 'magic_authors_notes', insertion_mode: 'relative' });
        }
        if (!blocks.find(b => b.id === 'guided_generation')) {
            const authorsIdx = blocks.findIndex(b => b.id === 'authors_note');
            const historyIdx = blocks.findIndex(b => b.id === 'chat_history');
            const insertIdx = authorsIdx !== -1 ? authorsIdx + 1 : (historyIdx !== -1 ? historyIdx + 1 : blocks.length);
            blocks.splice(insertIdx, 0, { id: 'guided_generation', name: 'Guided Generation', role: 'system', content: '[System Note: {{guidance}}]', enabled: true, isStatic: true, i18n: 'block_guided_generation', insertion_mode: 'relative' });
        }
    }

    function setupPersistenceWatchers() {
        watch(() => currentPreset.value?.noAssistant, (val) => {
            if (val && currentPreset.value) currentPreset.value.mergePrompts = true;
        });
        watch(() => currentPreset.value?.reasoningEnabled, (val) => {
            localStorage.setItem('gz_api_request_reasoning', val);
        });
    }

    return { loadPresets, setupPersistenceWatchers };
}
