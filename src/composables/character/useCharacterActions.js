import { triggerCharacterImport, extractCharacterBook, exportCharacterAsV2Json, exportCharacterAsV2Png, exportCharacterAsCharX } from '@/utils/characterIO.js';
import { importCharacter } from '@/core/states/catalogState.js';
import { datacatExtract, datacatExtractionStatus, datacatGetCharacter } from '@/core/services/catalog/datacatProvider.js';
import { db, markSyncDeletedEntry } from '@/utils/db.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { publishAppEvent } from '@/core/events/eventHub.js';
import { t } from '@/utils/i18n.js';

export function useCharacterActions({ characters, loadCharacters }) {
    let pollInterval = null;
    let activeMenuCharId = null;

    const setActiveMenuCharId = (id) => {
        activeMenuCharId = id;
    };

    const clearActiveMenuCharId = () => {
        activeMenuCharId = null;
    };

    const startJanitorExtraction = async (url) => {
        closeBottomSheet();
        setTimeout(() => {
            showBottomSheet({
                noDropdown: true,
                title: t('catalog_extracting'),
                bigInfo: {
                    icon: `<svg viewBox="0 0 24 24" style="fill:var(--vk-blue);width:100%;height:100%"><path d="M12 4V1L8 5l4 4V6c3.31 0 6 2.69 6 6 0 1.01-.25 1.97-.7 2.8l1.46 1.46C19.54 15.03 20 13.57 20 12c0-4.42-3.58-8-8-8zm0 14c-3.31 0-6-2.69-6-6 0-1.01.25-1.97.7-2.8L5.24 7.74C4.46 8.97 4 10.43 4 12c0 4.42 3.58 8 8 8v3l4-4-4-4v3z"/></svg>`,
                    description: t('catalog_extract_progress'),
                    buttonText: t('btn_cancel'),
                    onButtonClick: () => {
                        if (pollInterval) clearInterval(pollInterval);
                        closeBottomSheet();
                    }
                }
            });
        }, 300);

        try {
            await datacatExtract(url, true);
            let attempts = 0;
            const MAX = 60;
            
            pollInterval = setInterval(async () => {
                attempts++;
                if (attempts > MAX) {
                    clearInterval(pollInterval);
                    closeBottomSheet();
                    return;
                }
                try {
                    const status = await datacatExtractionStatus();
                    const uuidMatch = url.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
                    const searchStr = uuidMatch ? uuidMatch[0] : url;
                    
                    const done = status.history?.find(h => h.url?.includes(searchStr));
                    if (done && done.characterId) {
                        clearInterval(pollInterval);
                        pollInterval = null;
                        
                        const result = await datacatGetCharacter(done.characterId);
                        const charData = result.charData;
                        if (!charData.id) charData.id = Date.now().toString();
                        
                        await importCharacter(charData, result.avatarUrl);
                        closeBottomSheet();
                        
                        setTimeout(() => {
                            const index = characters.value.findIndex(c => c.id === charData.id);
                            if (index !== -1) {
                                publishAppEvent(APP_EVENTS.nav.openCharacterEditor, { index });
                            }
                        }, 500);
                    }
                } catch (e) { }
            }, 3000);
        } catch(e) {
            closeBottomSheet();
            setTimeout(() => {
                showBottomSheet({
                    noDropdown: true,
                    title: t('title_error'),
                    bigInfo: {
                        icon: `<svg viewBox="0 0 24 24" style="fill:#ff4444;width:100%;height:100%"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>`,
                        description: e.message,
                        buttonText: t('btn_ok'),
                        onButtonClick: closeBottomSheet
                    }
                });
            }, 300);
        }
    };

    const onAddCharacter = () => {
        showBottomSheet({
            title: t('sheet_title_char_options'),
            items: [
                {
                    label: t('action_create_new'),
                    hint: t('hint_create_new'),
                    icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                    onClick: () => {
                        closeBottomSheet();
                        publishAppEvent(APP_EVENTS.nav.openCharacterEditor, { index: -1 });
                    }
                },
                {
                    label: t('action_import'),
                    hint: t('hint_import_file'),
                    icon: '<svg viewBox="0 0 24 24"><path d="M4 15h2v3h12v-3h2v3c0 1.1-.9 2-2 2H6c-1.1 0-2-.9-2-2v-3zm4.41-6.59L11 5.83V17h2V5.83l2.59 2.58L17 7l-5-5-5 5 1.41 1.41z"/></svg>',
                    onClick: () => {
                        closeBottomSheet();
                        triggerCharacterImport(async (charData) => {
                            if (charData) {
                                try {
                                    if (!charData.id) {
                                        charData.id = Date.now().toString();
                                    }
                                    await extractCharacterBook(charData);
                                    await db.saveCharacter(charData, -1);
                                    await loadCharacters();
                                } catch (e) {
                                    console.error("Failed to save character", e);
                                    alert("Failed to save character: " + e.message);
                                }
                            }
                        });
                    }
                },
                {
                    label: t('action_import_janitor'),
                    hint: t('hint_import_janitor'),
                    icon: '<svg viewBox="0 0 24 24"><path d="M3.9 12c0-1.71 1.39-3.1 3.1-3.1h4V7H7c-2.76 0-5 2.24-5 5s2.24 5 5 5h4v-1.9H7c-1.71 0-3.1-1.39-3.1-3.1zM8 13h8v-2H8v2zm9-6h-4v1.9h4c1.71 0 3.1 1.39 3.1 3.1s-1.39 3.1-3.1 3.1h-4V17h4c2.76 0 5-2.24 5-5s-2.24-5-5-5z"/></svg>',
                    onClick: () => {
                        closeBottomSheet();
                        setTimeout(() => {
                            showBottomSheet({
                                title: t('action_import_janitor'),
                                input: {
                                    placeholder: t('placeholder_janitor_url'),
                                    confirmLabel: t('btn_ok'),
                                    onConfirm: (url) => {
                                        startJanitorExtraction(url);
                                    }
                                }
                            });
                        }, 300);
                    }
                }
            ]
        });
    };

    const onEditCharacter = (char) => {
        const index = characters.value.indexOf(char);
        if (index !== -1) {
            publishAppEvent(APP_EVENTS.nav.openCharacterEditor, { index });
        }
    };

    const openActions = (char) => {
        const isFav = char.fav === true;
        const favLabel = isFav ? t('action_remove_fav') : t('action_add_fav');
        const favIcon = isFav 
            ? '<svg viewBox="0 0 24 24"><path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/><line x1="4" y1="4" x2="20" y2="20" stroke="#ff4444" stroke-width="2" /></svg>'
            : '<svg viewBox="0 0 24 24"><path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/></svg>';
        const favColor = isFav ? '#ff4444' : 'var(--text-gray)';

        showBottomSheet({
            title: char.name,
            onClose: clearActiveMenuCharId,
            items: [
                {
                    label: t('action_edit'),
                    icon: '<svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>',
                    onClick: () => {
                        closeBottomSheet();
                        onEditCharacter(char);
                    }
                },
                {
                    label: t('action_export_st'),
                    icon: '<svg viewBox="0 0 24 24"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>',
                    onClick: () => {
                        closeBottomSheet();
                        setTimeout(() => {
                            showBottomSheet({
                                title: t('action_export_st') + ': ' + char.name,
                                items: [
                                    {
                                        label: t('label_export_png'),
                                        icon: '<svg viewBox="0 0 24 24"><path d="M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c0 1.1.9 2-2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z"/></svg>',
                                        onClick: () => {
                                            exportCharacterAsV2Png(char);
                                            closeBottomSheet();
                                        }
                                    },
                                    {
                                        label: t('label_export_json'),
                                        icon: '<svg viewBox="0 0 24 24"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>',
                                        onClick: () => {
                                            exportCharacterAsV2Json(char);
                                            closeBottomSheet();
                                        }
                                    },
                                    {
                                        label: t('label_export_charx', 'CharX (with gallery)'),
                                        icon: '<svg viewBox="0 0 24 24"><path d="M20 6h-8l-2-2H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm-6 10H6v-2h8v2zm4-4H6v-2h12v2z"/></svg>',
                                        onClick: () => {
                                            exportCharacterAsCharX(char);
                                            closeBottomSheet();
                                        }
                                    }
                                ]
                            });
                        }, 300);
                    }
                },
                {
                    label: favLabel,
                    icon: favIcon,
                    iconColor: favColor,
                    onClick: async () => {
                        char.fav = !char.fav;
                        await db.saveCharacter(char, -1);
                        closeBottomSheet();
                    }
                },
                {
                    label: t('action_delete'),
                    icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                    iconColor: '#ff4444',
                    isDestructive: true,
                    onClick: () => {
                        closeBottomSheet();
                        showBottomSheet({
                            title: t('confirm_delete_character'),
                            items: [
                                {
                                    label: t('btn_yes'),
                                    icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                                    iconColor: '#ff4444',
                                    isDestructive: true,
                                    onClick: async () => {
                                        if (char.id) {
                                            await db.deleteCharacter(char.id);
                                            await markSyncDeletedEntry('character', char.id);
                                            await loadCharacters();
                                        }
                                        closeBottomSheet();
                                    }
                                },
                                {
                                    label: t('btn_no'),
                                    icon: '<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>',
                                    onClick: () => closeBottomSheet()
                                }
                            ]
                        });
                    }
                }
            ]
        });
    };

    return {
        onAddCharacter,
        onEditCharacter,
        openActions,
        setActiveMenuCharId,
        clearActiveMenuCharId
    };
}
