import { db } from '@/utils/db.js';
import { createNewSession as dbCreateSession, deleteSession as dbDeleteSession } from '@/utils/sessions.js';
import { triggerChatImport } from '@/core/services/chatImporter.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { t, pluralize } from '@/utils/i18n.js';
import { formatDate } from '@/utils/dateFormatter.js';

export function useSessionSheet({ emit }) {
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
                        closeBottomSheet();
                        setTimeout(() => openSessionsSheet(char), 300);
                    }
                },
                {
                    label: t('btn_no'),
                    icon: '<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>',
                    onClick: () => {
                        closeBottomSheet();
                        setTimeout(() => openSessionsSheet(char), 300);
                    }
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
                        await dbCreateSession(char.id);
                        emit('open-chat', char);
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
                                            await dbCreateSession(char.id);
                                            emit('open-chat', char);
                                        }
                                    },
                                    {
                                        label: t('action_import'),
                                        icon: '<svg viewBox="0 0 24 24"><path d="M4 15h2v3h12v-3h2v3c0 1.1-.9 2-2 2H6c-1.1 0-2-.9-2-2v-3zm4.41-6.59L11 5.83V17h2V5.83l2.59 2.58L17 7l-5-5-5 5 1.41 1.41z"/></svg>',
                                        onClick: () => {
                                            closeBottomSheet();
                                            triggerChatImport(char.id, null, () => {
                                                emit('open-chat', char);
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
        
        const ids = Object.keys(sessions).map(Number).sort((a,b) => {
            const lastA = sessions[a][sessions[a].length-1]?.timestamp || 0;
            const lastB = sessions[b][sessions[b].length-1]?.timestamp || 0;
            return lastB - lastA;
        });

        const cardItems = ids.map(sid => {
            const msgs = sessions[sid] || [];
            const lastMsg = msgs[msgs.length - 1];
            const preview = lastMsg ? (lastMsg.text.length > 40 ? lastMsg.text.substring(0, 40) + '...' : lastMsg.text) : t('empty_session');
            const dateFormatted = lastMsg ? formatDate(lastMsg.timestamp, 'short') : '';
            
            return {
                label: t('session_name', { id: sid }),
                sublabel: preview,
                badge: `${msgs.length} ${pluralize(msgs.length, 'count_messages')}${dateFormatted ? ' · ' + dateFormatted : ''}`,
                onClick: () => {
                    closeBottomSheet();
                    const charWithSession = { ...char, sessionId: sid };
                    emit('open-chat', charWithSession);
                },
                actions: [
                    {
                        icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                        color: '#ff4444',
                        onClick: () => {
                            openDeleteSessionConfirm(char, sid);
                        }
                    }
                ]
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
                                        await dbCreateSession(char.id);
                                        emit('open-chat', char);
                                    }
                                },
                                {
                                    label: t('action_import'),
                                    icon: '<svg viewBox="0 0 24 24"><path d="M4 15h2v3h12v-3h2v3c0 1.1-.9 2-2 2H6c-1.1 0-2-.9-2-2v-3zm4.41-6.59L11 5.83V17h2V5.83l2.59 2.58L17 7l-5-5-5 5 1.41 1.41z"/></svg>',
                                    onClick: () => {
                                        closeBottomSheet();
                                        triggerChatImport(char.id, null, () => {
                                            emit('open-chat', char);
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
        openDeleteSessionConfirm
    };
}
