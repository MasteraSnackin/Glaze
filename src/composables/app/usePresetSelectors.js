import { computed } from 'vue';
import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { presetState, DEFAULT_PRESETS } from '@/core/states/presetState.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { Browser } from '@capacitor/browser';
import { t } from '@/utils/i18n.js';

export function usePresetSelectors({ currentPreset, currentPresetId, editingPresetId, activeChatChar, getPresetTokens, getPresetWeight, comparePresetEntries, updateHeaderState, openAddPresetSheet }) {
    function getPresetCreatedAt(id, preset) {
        if (!preset) return 0;
        if (typeof preset.createdAt === 'number' && Number.isFinite(preset.createdAt)) return preset.createdAt;
        const derived = Number.parseInt(String(id), 36);
        return Number.isFinite(derived) ? derived : 0;
    }

    const sortedPresetEntries = computed(() => {
        return Object.entries(presetState.presets).sort(comparePresetEntries);
    });

    function openPresetSelector() {
        const cardItems = [];
        const charId = activeChatChar?.value?.id;
        const chatId = charId && activeChatChar?.value?.sessionId ? `${charId}_${activeChatChar.value.sessionId}` : null;
        const entries = sortedPresetEntries.value;

        entries.forEach(([id, preset]) => {
            const tokens = getPresetTokens(preset);
            const isGlobal = presetState.globalPresetId === id;
            const isChar = charId && presetState.connections.character[charId] === id;
            const isChat = chatId && presetState.connections.chat[chatId] === id;
            const isActive = currentPresetId.value === id;

            const subtitleParts = [];
            if (preset.author) subtitleParts.push(`by ${preset.author}`);
            if (preset.descriptionKey) subtitleParts.push(t(preset.descriptionKey));
            if (isActive) subtitleParts.push(t('preset_selected') || 'Selected');
            if (isChat) subtitleParts.push(t('preset_this_chat') || 'This Chat');
            if (isChar) subtitleParts.push(t('preset_this_char') || 'This Character');
            if (isGlobal) subtitleParts.push(t('preset_global_default') || 'Global Default');

            cardItems.push({
                label: preset.name,
                sublabel: subtitleParts.join(' \u2022 ') || (t('preset_saved') || 'Saved Preset'),
                badge: `${tokens}`,
                isFeatured: preset.isFeatured,
                image: preset.image || null,
                icon: !preset.image ? '<svg viewBox="0 0 24 24" style="fill:currentColor;"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-5 14H7v-2h7v2zm3-4H7v-2h10v2zm0-4H7V7h10v2z"/></svg>' : null,
                onClick: () => { editingPresetId.value = id; closeBottomSheet(); updateHeaderState(); }
            });
        });

        cardItems.push({
            label: t('btn_add') || 'Add / Import',
            sublabel: t('preset_create_import_desc') || 'Create or import a new preset',
            icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:24px;height:24px;"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
            onClick: () => { closeBottomSheet(); openAddPresetSheet(); }
        });

        showBottomSheet({ title: t('sheet_title_presets') || 'Presets', cardItems });
    }

    function openPresetConnectionManager() {
        const preset = currentPreset.value;
        if (preset) publishAppEvent(APP_EVENTS.nav.openConnections, { type: 'preset', id: preset.id, name: preset.name });
    }

    function openMergeRoleSelector() {
        const preset = currentPreset.value;
        if (!preset) return;
        const roles = ['system', 'user', 'assistant'];
        showBottomSheet({
            title: t('label_merge_role') || 'Merge Role',
            items: roles.map(r => ({
                label: r.charAt(0).toUpperCase() + r.slice(1),
                icon: preset.mergeRole === r ? '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>' : null,
                onClick: () => { preset.mergeRole = r; closeBottomSheet(); }
            }))
        });
    }

    function openSquashRoleSelector() {
        const preset = currentPreset.value;
        if (!preset) return;
        const options = ['assistant', 'system', 'user'];
        showBottomSheet({
            title: t('label_squash_role') || 'Squash Role',
            items: options.map(r => ({
                label: r.charAt(0).toUpperCase() + r.slice(1),
                icon: preset.squashRole === r ? '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>' : null,
                onClick: () => { preset.squashRole = r; closeBottomSheet(); }
            }))
        });
    }

    function openReasoningEffortSelector() {
        const preset = currentPreset.value;
        if (!preset) return;
        const options = [
            { value: 'auto', label: t('reasoning_effort_auto') || 'Auto' },
            { value: 'low', label: t('reasoning_effort_low') || 'Low' },
            { value: 'medium', label: t('reasoning_effort_medium') || 'Medium' },
            { value: 'high', label: t('reasoning_effort_high') || 'High' }
        ];
        showBottomSheet({
            title: t('label_reasoning_effort') || 'Reasoning Effort',
            items: options.map(opt => ({
                label: opt.label,
                icon: preset.reasoningEffort === opt.value ? '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>' : null,
                onClick: () => { preset.reasoningEffort = opt.value; closeBottomSheet(); }
            }))
        });
    }

    function openPresetOptionsMenu({ cloneCurrentPreset, triggerExportST, renameCurrentPreset, editCurrentAuthor, triggerImageUpload, confirmDeletePreset, confirmResetPreset }) {
        const isDefault = !!DEFAULT_PRESETS[currentPresetId.value];
        const items = [];

        let authorLinkResolved = currentPreset.value.authorLink;
        if (!authorLinkResolved) {
            const authorName = (currentPreset.value.author || '').toLowerCase();
            if (authorName === 'microcot') authorLinkResolved = 'https://t.me/sillytavern1';
            else if (authorName === 'fawn1e' || authorName === 'fawnie') authorLinkResolved = 'https://t.me/dearfawwn';
        }

        if (authorLinkResolved) {
            items.push({
                label: t('author_link') || 'Author link',
                icon: '<svg viewBox="0 0 24 24"><path d="M3.9 12c0-1.71 1.39-3.1 3.1-3.1h4V7H7c-2.76 0-5 2.24-5 5s2.24 5 5 5h4v-1.9H7c-1.71 0-3.1-1.39-3.1-3.1zM8 13h8v-2H8v2zm9-6h-4v1.9h4c1.71 0 3.1 1.39 3.1 3.1s-1.39 3.1-3.1 3.1h-4V17h4c2.76 0 5-2.24 5-5s-2.24-5-5-5z"/></svg>',
                onClick: async () => { closeBottomSheet(); await Browser.open({ url: authorLinkResolved }); }
            });
        }

        items.push(
            { label: t('action_clone') || 'Clone Preset', icon: '<svg viewBox="0 0 24 24"><path d="M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z"/></svg>', onClick: () => { closeBottomSheet(); cloneCurrentPreset(); } },
            { label: t('action_export_st') || 'Export as ST Preset', icon: '<svg viewBox="0 0 24 24"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"/></svg>', onClick: () => { closeBottomSheet(); triggerExportST(); } }
        );

        if (!isDefault) {
            items.push(
                { label: t('action_edit_name') || 'Change Name', icon: '<svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>', onClick: () => renameCurrentPreset() },
                { label: t('change_author') || 'Change Author', icon: '<svg viewBox="0 0 24 24"><path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"/></svg>', onClick: () => editCurrentAuthor() },
                { label: t('change_image') || 'Change Image', icon: '<svg viewBox="0 0 24 24"><path d="M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z"/></svg>', onClick: () => { closeBottomSheet(); triggerImageUpload(); } }
            );
        } else {
            items.push({
                label: t('action_reset') || 'Reset to Default',
                icon: '<svg viewBox="0 0 24 24"><path d="M12 5V1L7 6l5 5V7c3.31 0 6 2.69 6 6s-2.69 6-6 6-6-2.69-6-6H4c0 4.42 3.58 8 8 8s8-3.58 8-8-3.58-8-8-8z"/></svg>',
                onClick: () => { closeBottomSheet(); confirmResetPreset(currentPresetId.value); }
            });
        }

        if (!isDefault) {
            items.push({
                label: t('btn_delete') || 'Delete Preset',
                icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                iconColor: '#ff4444', isDestructive: true,
                onClick: () => confirmDeletePreset(currentPreset.value.id)
            });
        }

        showBottomSheet({ title: t('preset_options') || 'Preset Options', items });
    }

    return {
        getPresetCreatedAt, sortedPresetEntries,
        openPresetSelector, openPresetConnectionManager,
        openMergeRoleSelector, openSquashRoleSelector, openReasoningEffortSelector,
        openPresetOptionsMenu
    };
}
