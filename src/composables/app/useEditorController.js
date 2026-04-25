import { ref, computed, nextTick } from 'vue';
import { db, markSyncDeletedEntry } from '@/utils/db.js';
import { addPersona, updatePersona, deletePersona, allPersonas } from '@/core/states/personaState.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';

const t = (key) => translations[currentLang.value]?.[key] || key;

export const characterEditorConfig = [
    {
        title: 'section_basic_info',
        fields: [
            { key: 'name', label: 'label_name', type: 'text' },
            { key: 'macro_name', label: 'label_char_macro_name', type: 'text', placeholder: 'placeholder_char_macro_name' },
            { key: 'description', label: 'label_description', type: 'textarea', rows: 3, expandable: true },
            { key: 'creator_notes', label: 'label_creator_notes', type: 'textarea', rows: 2 },
            { key: 'tags', label: 'label_tags', type: 'tags' }
        ]
    },
    {
        title: 'section_personality',
        fields: [
            { key: 'personality', label: 'label_personality', type: 'textarea', rows: 4, expandable: true },
            { key: 'scenario', label: 'label_scenario', type: 'textarea', rows: 3, expandable: true }
        ]
    },
    {
        title: 'section_dialogue',
        fields: [
            { key: 'first_mes', label: 'label_first_mes', type: 'greeting_list', rows: 4 },
            { key: 'mes_example', label: 'label_mes_example', type: 'textarea', rows: 6, expandable: true }
        ]
    }
];

export const personaEditorConfig = [
    {
        title: 'section_basic_info',
        fields: [
            { key: 'name', label: 'label_name', type: 'text' },
            { key: 'prompt', label: 'label_description', type: 'textarea', rows: 4, expandable: true }
        ]
    }
];

export function useEditorController({ currentView, currentChatSessionId, waitForComponent, chatViewRef }) {
    const editingCharacter = ref(null);
    const editingCharacterIndex = ref(-1);
    const editingPersona = ref(null);
    const editingPersonaIndex = ref(-1);
    const previousViewForEditor = ref(null);
    const previousSessionIdForEditor = ref(null);
    const shouldOpenPersonasOnReturn = ref(false);
    const isDeleting = ref(false);

    const fsEditorVisible = ref(false);
    const fsEditorValue = ref('');
    let fsEditorCallback = null;

    const isEditorView = computed(() =>
        currentView.value === 'view-character-edit' || currentView.value === 'view-persona-edit'
    );

    const headerEditingIndex = computed(() => {
        if (currentView.value === 'view-character-edit') return editingCharacterIndex.value;
        if (currentView.value === 'view-persona-edit') return editingPersonaIndex.value;
        return -1;
    });

    async function openCharacterEditor(index) {
        previousViewForEditor.value = currentView.value;
        if (currentView.value === 'view-chat') {
            previousSessionIdForEditor.value = currentChatSessionId.value;
        } else {
            previousSessionIdForEditor.value = null;
        }
        isDeleting.value = false;
        editingCharacterIndex.value = index;
        if (index === -1) {
            editingCharacter.value = null;
        } else {
            const chars = (await db.getAll('characters')) || [];
            editingCharacter.value = chars[index];
        }
        currentView.value = 'view-character-edit';
    }

    async function handleHeaderSave() {
        if (currentView.value === 'view-character-edit') {
            if (editingCharacter.value && editingCharacter.value.name && editingCharacter.value.name.trim() !== '') {
                await db.saveCharacter(editingCharacter.value, editingCharacterIndex.value);
                closeEditor();
            } else {
                showBottomSheet({
                    title: t('title_error') || 'Error',
                    bigInfo: {
                        icon: '<svg viewBox="0 0 24 24" style="fill:#ff4444;width:100%;height:100%;"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>',
                        description: t('error_name_required') || 'Name is required.',
                        buttonText: t('btn_ok') || 'OK',
                        onButtonClick: closeBottomSheet
                    }
                });
            }
        } else if (currentView.value === 'view-persona-edit') {
            if (editingPersona.value && editingPersona.value.name && editingPersona.value.name.trim() !== '') {
                if (editingPersonaIndex.value === -1) {
                    await addPersona(editingPersona.value);
                } else {
                    await updatePersona(editingPersonaIndex.value, editingPersona.value);
                }
                closeEditor();
            } else {
                showBottomSheet({
                    title: t('title_error') || 'Error',
                    bigInfo: {
                        icon: '<svg viewBox="0 0 24 24" style="fill:#ff4444;width:100%;height:100%;"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>',
                        description: t('error_name_required') || 'Name is required.',
                        buttonText: t('btn_ok') || 'OK',
                        onButtonClick: closeBottomSheet
                    }
                });
            }
        }
    }

    async function handleEditorAutoSave(val) {
        if (isDeleting.value) return;

        if (currentView.value === 'view-character-edit') {
            if (!val || !val.name || val.name.trim() === '') return;

            if (editingCharacterIndex.value === -1) {
                await db.saveCharacter(val, -1);
                const chars = (await db.getAll('characters')) || [];
                editingCharacterIndex.value = chars.length - 1;
            } else {
                await db.saveCharacter(val, editingCharacterIndex.value);
            }
        } else if (currentView.value === 'view-persona-edit') {
            if (!val.name) return;

            if (editingPersonaIndex.value === -1) {
                const newPersona = await addPersona(val);
                editingPersonaIndex.value = allPersonas.value.length - 1;
                editingPersona.value = JSON.parse(JSON.stringify(newPersona));
            } else {
                await updatePersona(editingPersonaIndex.value, val);
            }
        }
    }

    async function handleHeaderDelete() {
        const isPersona = currentView.value === 'view-persona-edit';
        const title = isPersona ? (t('confirm_delete_persona') || 'Delete persona?') : (t('confirm_delete_title') || 'Delete character?');

        showBottomSheet({
            title: title,
            items: [
                {
                    label: t('btn_delete') || 'Delete',
                    icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                    iconColor: '#ff4444',
                    isDestructive: true,
                    onClick: async () => {
                        isDeleting.value = true;
                        try {
                            if (isPersona) {
                                await deletePersona(editingPersonaIndex.value);
                            } else {
                                const char = editingCharacter.value;
                                if (char && char.id && db.deleteCharacter) {
                                    await db.deleteCharacter(char.id);
                                    await markSyncDeletedEntry('character', char.id);
                                } else {
                                    console.error('[EditorController] Character ID is missing or db.deleteCharacter not found');
                                }
                            }
                        } catch (e) {
                            console.error('[EditorController] Error deleting item:', e);
                        }
                        closeBottomSheet();

                        if (isPersona) {
                            currentView.value = 'view-menu';
                        } else {
                            currentView.value = 'view-characters';
                        }
                        previousViewForEditor.value = null;
                    }
                },
                {
                    label: t('btn_cancel') || 'Cancel',
                    icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>',
                    onClick: closeBottomSheet
                }
            ]
        });
    }

    async function closeEditor({ activeChatCharObj, currentChatSessionId, chatPreviousView, isHeaderEditorMode } = {}) {
        const closingView = currentView.value;
        const prev = previousViewForEditor.value;
        previousViewForEditor.value = null;
        const prevSessionId = previousSessionIdForEditor.value;
        previousSessionIdForEditor.value = null;
        if (isHeaderEditorMode) isHeaderEditorMode.value = false;

        if (closingView === 'view-character-edit') {
            editingCharacterIndex.value = -1;
        }
        if (closingView === 'view-persona-edit') {
            editingPersonaIndex.value = -1;
        }

        if (prev === 'view-chat') {
            const isEditingChar = closingView === 'view-character-edit';
            currentView.value = 'view-chat';

            waitForComponent(chatViewRef, async (comp) => {
                if (activeChatCharObj.value) {
                    if (isEditingChar && editingCharacter.value) {
                        activeChatCharObj.value = { ...editingCharacter.value };
                    }

                    if (prevSessionId) {
                        activeChatCharObj.value.sessionId = prevSessionId;
                    }

                    comp.openChat(activeChatCharObj.value, () => {
                        currentView.value = chatPreviousView.value || 'view-dialogs';
                    });

                    if (shouldOpenPersonasOnReturn.value) {
                        shouldOpenPersonasOnReturn.value = false;
                        await nextTick();
                        if (typeof comp.openPersonas === 'function') {
                            comp.openPersonas();
                        }
                    }
                }
            });
        } else if (prev) {
            currentView.value = prev;
        } else {
            if (closingView === 'view-persona-edit') {
                currentView.value = 'view-menu';
            } else {
                currentView.value = 'view-characters';
            }
        }
    }

    function onOpenPersonaEditor(detail) {
        previousViewForEditor.value = currentView.value;
        if (currentView.value === 'view-chat') {
            shouldOpenPersonasOnReturn.value = true;
        }
        isDeleting.value = false;
        editingPersonaIndex.value = detail.index;
        editingPersona.value = detail.persona ? JSON.parse(JSON.stringify(detail.persona)) : { name: '', description: '', avatar: '' };
        currentView.value = 'view-persona-edit';
    }

    function openFsEditor({ value, onSave }) {
        fsEditorValue.value = value;
        fsEditorCallback = onSave;
        fsEditorVisible.value = true;
    }

    function closeAndSaveFsEditor() {
        if (fsEditorCallback) fsEditorCallback(fsEditorValue.value);
        fsEditorVisible.value = false;
    }

    function autoSaveFsEditor(val) {
        if (fsEditorCallback) fsEditorCallback(val);
    }

    return {
        editingCharacter,
        editingCharacterIndex,
        editingPersona,
        editingPersonaIndex,
        previousViewForEditor,
        previousSessionIdForEditor,
        shouldOpenPersonasOnReturn,
        isDeleting,
        fsEditorVisible,
        fsEditorValue,
        isEditorView,
        headerEditingIndex,
        openCharacterEditor,
        handleHeaderSave,
        handleEditorAutoSave,
        handleHeaderDelete,
        closeEditor,
        onOpenPersonaEditor,
        openFsEditor,
        closeAndSaveFsEditor,
        autoSaveFsEditor
    };
}
