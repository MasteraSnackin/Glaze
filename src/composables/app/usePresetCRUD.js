import { presetState, setPresetConnection, DEFAULT_PRESETS, flushPresetSave } from '@/core/states/presetState.js';
import { detectPresetFormat, convertLatexPreset, convertSTPreset, exportSTPreset, finalizeImportedPreset, mandatoryBlocks } from '@/core/services/presetImportService.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { saveFile } from '@/core/services/fileSaver.js';
import { Browser } from '@capacitor/browser';
import { t } from '@/utils/i18n.js';

const R_START = '\u003Cthink\u003E';
const R_END = '\u003C/think\u003E';

export function usePresetCRUD({ currentPreset, currentPresetId, editingPresetId, updateHeaderState }) {
    function createNewPreset() {
        showBottomSheet({
            title: t('new_preset') || 'New Preset',
            input: {
                placeholder: t('placeholder_preset_name') || 'Enter preset name',
                value: '',
                confirmLabel: t('btn_create') || 'Create',
                onConfirm: (name) => {
                    const id = Date.now().toString(36);
                    presetState.presets[id] = {
                        id, createdAt: Date.now(), name, blocks: [], author: '', image: '',
                        impersonationPrompt: '', reasoningEnabled: false, reasoningEffort: 'medium',
                        parseInlineReasoning: false, reasoningStart: R_START, reasoningEnd: R_END,
                        mergePrompts: false, mergeRole: 'system', noAssistant: false,
                        stopString: '', userPrefix: '', charPrefix: '', squashRole: 'assistant',
                        summaryPrompt: 'Summarize the following roleplay conversation concisely, focusing on the current situation and key events:\n\n{{history}}\n\nSummary:',
                        guidedGenerationPrompt: '[Generate your next reply according to these instructions: {{guidance}}]',
                        guidedImpersonationPrompt: '[Instead of replying for {{char}}, impersonate {{user}} according to these instructions: {{guidance}}]'
                    };
                    presetState.presets[id].blocks = [
                        { id: 'sys1', name: 'Main System', role: 'system', content: 'You are a helpful AI assistant.', enabled: true },
                        ...mandatoryBlocks.filter(b => b.id !== 'chat_history' && b.id !== 'guided_generation').map(b => ({ ...b })),
                        { id: 'summary', name: 'Summary', role: 'system', content: '', enabled: true, isStatic: true, i18n: 'magic_summary', depth: 4, insertion_mode: 'relative', prefix: 'Summary: ' },
                        { id: 'authors_note', name: "Author's Note", role: 'system', content: '', enabled: true, isStatic: true, i18n: 'magic_authors_notes', insertion_mode: 'relative' },
                        { ...mandatoryBlocks.find(b => b.id === 'chat_history') },
                        { ...mandatoryBlocks.find(b => b.id === 'guided_generation') },
                    ];
                    presetState.presetOrder.push(id);
                    setPresetConnection('global', null, id);
                    editingPresetId.value = id;
                    closeBottomSheet();
                    updateHeaderState();
                }
            }
        });
    }

    function cloneCurrentPreset() {
        const source = currentPreset.value;
        const newId = Date.now().toString(36) + Math.random().toString(36).substr(2, 4);
        const clone = JSON.parse(JSON.stringify(source));
        clone.id = newId;
        clone.name = (source.name || 'Preset') + ' (copy)';
        clone.isFeatured = false;
        if (clone.blocks) {
            clone.blocks.forEach(b => {
                if (!b.isStatic && !mandatoryBlocks.find(mb => mb.id === b.id)) {
                    b.id = Date.now().toString(36) + Math.random().toString(36).substr(2, 6);
                }
            });
        }
        presetState.presets[newId] = clone;
        presetState.presetOrder.push(newId);
        setPresetConnection('global', null, newId);
        editingPresetId.value = newId;
        updateHeaderState();
    }

    function renameCurrentPreset() {
        showBottomSheet({
            title: t('action_edit_name') || 'Change Name',
            input: { placeholder: t('placeholder_preset_name') || 'Enter preset name', value: currentPreset.value.name, confirmLabel: t('btn_save') || 'Save', onConfirm: (newName) => { if (newName) currentPreset.value.name = newName; closeBottomSheet(); } }
        });
    }

    function editCurrentAuthor() {
        showBottomSheet({
            title: t('change_author') || 'Change Author',
            input: { placeholder: t('placeholder_author_name') || 'Enter author name', value: currentPreset.value.author, confirmLabel: t('btn_save') || 'Save', onConfirm: (newAuthor) => { currentPreset.value.author = newAuthor; closeBottomSheet(); } }
        });
    }

    async function triggerExportST() {
        try {
            const exportedData = exportSTPreset(currentPreset.value);
            const fileName = (currentPreset.value.name || 'Preset').replace(/[^a-z0-9\u0430-\u044F\u0451]/gi, '_').toLowerCase();
            await saveFile(`${fileName}.json`, JSON.stringify(exportedData, null, 4), 'application/json', 'presets');
        } catch (e) {
            console.error("Export ST Preset failed", e);
            alert("Export failed: " + e.message);
        }
    }

    function confirmDeletePreset(id) {
        const presetName = presetState.presets[id]?.name;
        showBottomSheet({
            title: `${t('confirm_delete_preset')} "${presetName}"?`,
            noDropdown: true,
            items: [
                {
                    label: t('btn_yes') || 'Yes', icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>', iconColor: '#ff4444', isDestructive: true,
                    onClick: () => {
                        if (DEFAULT_PRESETS[id]) { closeBottomSheet(); return; }
                        delete presetState.presets[id];
                        presetState.presetOrder = presetState.presetOrder.filter(i => i !== id);
                        Object.keys(presetState.connections.character).forEach(k => { if (presetState.connections.character[k] === id) delete presetState.connections.character[k]; });
                        Object.keys(presetState.connections.chat).forEach(k => { if (presetState.connections.chat[k] === id) delete presetState.connections.chat[k]; });
                        if (presetState.globalPresetId === id) setPresetConnection('global', null, null);
                        closeBottomSheet();
                        if (editingPresetId.value === id) { editingPresetId.value = null; updateHeaderState(); }
                        flushPresetSave();
                    }
                },
                { label: t('btn_no') || 'No', icon: '<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>', onClick: () => closeBottomSheet() }
            ]
        });
    }

    function confirmResetPreset(id) {
        const presetName = presetState.presets[id]?.name;
        showBottomSheet({
            title: `${t('confirm_reset_preset') || 'Reset to default:'} "${presetName}"?`,
            noDropdown: true,
            items: [
                {
                    label: t('btn_yes') || 'Yes', icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>', iconColor: 'var(--vk-blue)',
                    onClick: () => { if (!DEFAULT_PRESETS[id]) return; presetState.presets[id] = JSON.parse(JSON.stringify(DEFAULT_PRESETS[id])); closeBottomSheet(); }
                },
                { label: t('btn_no') || 'No', icon: '<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>', onClick: () => closeBottomSheet() }
            ]
        });
    }

    function triggerImport() {
        document.getElementById('preset-file-input').click();
    }

    function onFileSelected(event) {
        const file = event.target.files[0];
        if (!file) return;
        const reader = new FileReader();
        reader.onerror = () => {
            alert('Failed to read file. Please try again.');
            event.target.value = '';
        };
        reader.onload = (e) => {
            try {
                const text = e.target.result;
                if (typeof text !== 'string' || !text.trim()) {
                    alert('File is empty or could not be read.');
                    event.target.value = '';
                    return;
                }
                const json = JSON.parse(text);
                const format = detectPresetFormat(json);
                let preset;
                if (format === 'latex') preset = convertLatexPreset(json, file.name.replace(/\.json$/i, ''));
                else if (format === 'sillytavern') preset = convertSTPreset(json, file.name.replace(/\.json$/i, ''));
                else if (format === 'glaze') preset = json;
                else { alert("Unknown preset format. Expected SillyTavern, LaTeX, or Glaze JSON."); return; }
                preset = finalizeImportedPreset(preset);
                presetState.presets[preset.id] = preset;
                if (!presetState.presetOrder.includes(preset.id)) {
                    presetState.presetOrder.push(preset.id);
                }
                editingPresetId.value = preset.id;
                updateHeaderState();
            } catch (err) {
                if (err instanceof SyntaxError) {
                    alert('Invalid JSON file: the file is not valid JSON.');
                } else {
                    alert('Failed to import preset: ' + (err.message || 'Unknown error'));
                }
            }
            event.target.value = '';
        };
        reader.readAsText(file);
    }

    function openAddPresetSheet() {
        showBottomSheet({
            title: t('sheet_title_presets') || 'Presets',
            items: [
                { label: t('action_create_new') || 'Create New', icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>', onClick: () => { closeBottomSheet(); createNewPreset(); } },
                { label: t('action_import') || 'Import from file', icon: '<svg viewBox="0 0 24 24"><path d="M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96zM14 13v4h-4v-4H7l5-5 5 5h-3z"/></svg>', onClick: () => { closeBottomSheet(); triggerImport(); } }
            ]
        });
    }

    return {
        createNewPreset, cloneCurrentPreset, renameCurrentPreset, editCurrentAuthor,
        triggerExportST, confirmDeletePreset, confirmResetPreset,
        triggerImport, onFileSelected, openAddPresetSheet
    };
}
