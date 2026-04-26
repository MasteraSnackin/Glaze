import { db } from '@/utils/db.js';
import { createNewSession as dbCreateSession, deleteSession as dbDeleteSession, renameSession as dbRenameSession } from '@/utils/sessions.js';
import { triggerChatImport, exportSillyTavernChat, exportGlazeChat } from '@/core/services/chatImporter.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { t, pluralize } from '@/utils/i18n.js';
import { formatDate } from '@/utils/dateFormatter.js';

/**
 * @param {object} options
 * @param {function} options.openChat - called with { charId, sessionId } when user picks a session
 * @param {function} [options.onAfterAction] - called after rename/delete completes (e.g. to reload list)
 */
export function useSessionSheet({ openChat, onAfterAction } = {}) {

    function openDeleteSessionConfirm(char, sessionId) {
        showBottomSheet({
            title: t('confirm_delete_session'),
            items: [
                {
                    label: t('btn_yes'),
                    icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                    iconColor: '#ff4444',
                    isDestructive: true,
                    onClick: async () => {
                        await dbDeleteSession(char.id, sessionId);
                        onAfterAction?.();
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

    function openSessionActions(char, sessionId, sessionName) {
        // Show actions sheet directly (replaces current sheet without closing animation)
        showBottomSheet({
            title: `${char.name} (#${sessionId})`,
            items: [
                {
                    label: t('action_rename'),
                    icon: '<svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>',
                    onClick: () => {
                        showBottomSheet({
                            title: t('action_rename'),
                            input: {
                                placeholder: t('placeholder_enter_name'),
                                value: sessionName || `Session #${sessionId}`,
                                confirmLabel: t('btn_save'),
                                onConfirm: async (val) => {
                                    if (val) {
                                        await dbRenameSession(char.id, sessionId, val);
                                        onAfterAction?.();
                                        closeBottomSheet();
                                    }
                                }
                            }
                        });
                    }
                },
                {
                    label: t('action_export_glaze') || 'Export Chat (Glaze)',
                    icon: '<svg viewBox="0 0 24 24"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-7 14-5-5h3V8h4v4h3l-5 5z"/></svg>',
                    onClick: () => {
                        exportGlazeChat({ id: char.id, name: char.name, sessionId });
                        closeBottomSheet();
                    }
                },
                {
                    label: t('action_export_chat') || 'Export Chat (JSONL)',
                    icon: '<svg viewBox="0 0 24 24"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"/></svg>',
                    onClick: () => {
                        exportSillyTavernChat({ id: char.id, name: char.name, sessionId });
                        closeBottomSheet();
                    }
                },
                {
                    label: t('action_delete_session'),
                    icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                    iconColor: '#ff4444',
                    isDestructive: true,
                    onClick: () => openDeleteSessionConfirm(char, sessionId)
                }
            ]
        });
    }

    const openSessionsSheet = async (char) => {
        const rawData = await db.get(`gz_chat_${char.id}`);

        if (!rawData || !rawData.sessions || Object.keys(rawData.sessions).length === 0) {
            showBottomSheet({
                title: t('history_title'),
                bigInfo: {
                    icon: '<svg viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2z"/></svg>',
                    description: t('no_sessions'),
                    buttonText: t('action_create_new'),
                    onButtonClick: async () => {
                        closeBottomSheet();
                        const sessionId = await dbCreateSession(char.id);
                        openChat({ charId: char.id, sessionId });
                    }
                },
                headerAction: {
                    icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                    onClick: () => {
                        closeBottomSheet();
                        setTimeout(() => {
                            showBottomSheet({
                                title: t('history_title'),
                                items: [
                                    {
                                        label: t('action_create_new'),
                                        icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                                        onClick: async () => {
                                            closeBottomSheet();
                                            const sessionId = await dbCreateSession(char.id);
                                            openChat({ charId: char.id, sessionId });
                                        }
                                    },
                                    {
                                        label: t('action_import'),
                                        icon: '<svg viewBox="0 0 24 24"><path d="M4 15h2v3h12v-3h2v3c0 1.1-.9 2-2 2H6c-1.1 0-2-.9-2-2v-3zm4.41-6.59L11 5.83V17h2V5.83l2.59 2.58L17 7l-5-5-5 5 1.41 1.41z"/></svg>',
                                        onClick: () => {
                                            closeBottomSheet();
                                            triggerChatImport(char.id, null, ({ sessionId } = {}) => {
                                                openChat({ charId: char.id, sessionId });
                                            });
                                        }
                                    }
                                ]
                            });
                        }, 300);
                    }
                }
            });
            return;
        }

        const sessions = rawData.sessions;
        const currentSessionId = rawData.currentId;

        const ids = Object.keys(sessions).map(Number).sort((a, b) => {
            const lastA = sessions[a][sessions[a].length - 1]?.timestamp || 0;
            const lastB = sessions[b][sessions[b].length - 1]?.timestamp || 0;
            return lastB - lastA;
        });

        const cardItems = ids.map(sid => {
            const msgs = sessions[sid] || [];
            const lastMsg = msgs[msgs.length - 1];
            const preview = lastMsg ? (lastMsg.text.length > 40 ? lastMsg.text.substring(0, 40) + '...' : lastMsg.text) : t('empty_session');
            const dateFormatted = lastMsg ? formatDate(lastMsg.timestamp, 'short') : '';

            return {
                label: rawData.sessionNames?.[sid] || t('session_name', { id: sid }),
                sublabel: preview,
                badge: `${msgs.length} ${pluralize(msgs.length, 'count_messages')}${dateFormatted ? ' · ' + dateFormatted : ''}`,
                isActive: sid === currentSessionId,
                onClick: () => {
                    closeBottomSheet();
                    openChat({ charId: char.id, sessionId: sid });
                },
                onLongPress: () => {
                    openSessionActions(char, sid, rawData.sessionNames?.[sid]);
                }
            };
        });

        showBottomSheet({
            title: t('history_title'),
            cardItems: cardItems,
            headerAction: {
                icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    setTimeout(() => {
                        showBottomSheet({
                            title: t('history_title'),
                            items: [
                                {
                                    label: t('action_create_new'),
                                    icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                                    onClick: async () => {
                                        closeBottomSheet();
                                        const sessionId = await dbCreateSession(char.id);
                                        openChat({ charId: char.id, sessionId });
                                    }
                                },
                                {
                                    label: t('action_import'),
                                    icon: '<svg viewBox="0 0 24 24"><path d="M4 15h2v3h12v-3h2v3c0 1.1-.9 2-2 2H6c-1.1 0-2-.9-2-2v-3zm4.41-6.59L11 5.83V17h2V5.83l2.59 2.58L17 7l-5-5-5 5 1.41 1.41z"/></svg>',
                                    onClick: () => {
                                        closeBottomSheet();
                                        triggerChatImport(char.id, null, ({ sessionId } = {}) => {
                                            openChat({ charId: char.id, sessionId });
                                        });
                                    }
                                }
                            ]
                        });
                    }, 300);
                }
            }
        });
    };

    return {
        openSessionsSheet,
        openSessionActions,
        openDeleteSessionConfirm
    };
}
