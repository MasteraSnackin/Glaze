import { ref } from 'vue';
import { presetState } from '@/core/states/presetState.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { t } from '@/utils/i18n.js';

export function useBlockManager({ currentPreset, editingBlockId, isEditingBlock, activeEditBlock, stashedBlocks, getBlockIcon, getPresetTokens, getPresetWeight, comparePresetEntries, closeBlockEditor }) {
    const dragSrcIndex = ref(-1);

    function addNewBlock() {
        showBottomSheet({
            title: t('add_block') || 'Add Block',
            items: [
                { label: t('action_create_new') || 'Create New', icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                    onClick: () => { const newBlock = { id: Date.now().toString(36) + Math.random().toString(36).substr(2), name: t('new_block') || 'New Block', role: 'system', content: '', enabled: true, insertion_mode: 'relative' }; currentPreset.value.blocks.push(newBlock); closeBottomSheet(); }
                },
                { label: t('action_copy_from_preset') || 'Copy from Preset', icon: '<svg viewBox="0 0 24 24"><path d="M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z"/></svg>',
                    onClick: () => { closeBottomSheet(); openCopyBlockPresetPicker(); }
                }
            ]
        });
    }

    function openCopyBlockPresetPicker() {
        const entries = Object.entries(presetState.presets).sort((a, b) => {
            const wA = getPresetWeight(a[0], a[1]); const wB = getPresetWeight(b[0], b[1]);
            if (wA !== wB) return wA - wB; return a[1].name.localeCompare(b[1].name);
        });
        const cardItems = entries.map(([id, preset]) => ({
            label: preset.name, sublabel: preset.author ? `by ${preset.author}` : '',
            image: preset.image || null, isFeatured: preset.isFeatured,
            icon: !preset.image ? '<svg viewBox="0 0 24 24" style="fill:currentColor;"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-5 14H7v-2h7v2zm3-4H7v-2h10v2zm0-4H7V7h10v2z"/></svg>' : null,
            onClick: () => { closeBottomSheet(); openCopyBlockPicker(id, preset); }
        }));
        showBottomSheet({ title: t('action_select_preset') || 'Select Preset', cardItems });
    }

    function openCopyBlockPicker(presetId, preset) {
        if (!preset.blocks || preset.blocks.length === 0) {
            showBottomSheet({ title: preset.name, items: [{ label: t('label_no_blocks') || 'No blocks available', onClick: () => closeBottomSheet() }] }); return;
        }
        const items = preset.blocks.filter(b => !b.isStashed).map(block => ({
            label: block.i18n ? t(block.i18n) : block.name, icon: '<svg viewBox="0 0 24 24">' + getBlockIcon(block) + '</svg>',
            onClick: () => { const clone = JSON.parse(JSON.stringify(block)); clone.id = Date.now().toString(36) + Math.random().toString(36).substr(2, 6); clone.name = (block.i18n ? t(block.i18n) : block.name) + ' (copy)'; clone.isStatic = false; clone.i18n = undefined; currentPreset.value.blocks.push(clone); closeBottomSheet(); }
        }));
        showBottomSheet({ title: preset.name + ' \u2014 ' + (t('label_blocks') || 'Blocks'), items });
    }

    function stashActiveBlock() {
        if (activeEditBlock.value) { activeEditBlock.value.isStashed = true; activeEditBlock.value.enabled = false; closeBlockEditor(); }
    }

    function unstashBlock(blockId) {
        const block = currentPreset.value.blocks.find(b => b.id === blockId);
        if (block) { block.isStashed = false; block.enabled = true; }
    }

    function openStashSheet() {
        if (stashedBlocks.value.length === 0) return;
        const items = stashedBlocks.value.map(block => ({
            label: block.i18n ? t(block.i18n) : block.name, icon: getBlockIcon(block), onClick: null,
            actions: [
                { icon: '<svg viewBox="0 0 24 24"><path d="M20.55 5.22l-1.39-1.68C18.88 3.21 18.47 3 18 3H6c-.47 0-.88.21-1.15.55L3.46 5.22C3.17 5.57 3 6.01 3 6.5V19c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V6.5c0-.49-.17-.93-.45-1.28zM5.12 5l.82-1h12.11l.83 1H5.12zM12 17.5L6.5 12H10v-4h4v4h3.5L12 17.5z"/></svg>', color: 'var(--vk-blue)',
                    onClick: (e) => { e.stopPropagation(); unstashBlock(block.id); if (stashedBlocks.value.length > 0) openStashSheet(); else closeBottomSheet(); }
                },
                { icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>', color: '#ff4444',
                    onClick: (e) => { e.stopPropagation(); confirmDeleteStashedBlock(block.id); }
                }
            ]
        }));
        showBottomSheet({ title: t('stash') || 'Stash', items });
    }

    function deleteActiveBlock() {
        if (activeEditBlock.value && activeEditBlock.value.isStatic) { alert(t('msg_cannot_delete_static') || 'Cannot delete static block'); return; }
        if (editingBlockId.value) {
            showBottomSheet({
                title: t('confirm_delete_block') || 'Delete block?',
                items: [
                    { label: t('btn_delete') || 'Delete', icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>', iconColor: '#ff4444', isDestructive: true,
                        onClick: () => { const idx = currentPreset.value.blocks.findIndex(b => b.id === editingBlockId.value); if (idx !== -1) currentPreset.value.blocks.splice(idx, 1); closeBottomSheet(); closeBlockEditor(); }
                    },
                    { label: t('btn_cancel') || 'Cancel', icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>', onClick: closeBottomSheet }
                ]
            });
        }
    }

    function confirmDeleteStashedBlock(blockId) {
        const block = currentPreset.value.blocks.find(b => b.id === blockId); if (!block) return;
        showBottomSheet({
            title: `${t('confirm_delete_block') || 'Delete block?'} "${block.name}"`,
            items: [
                { label: t('btn_delete') || 'Delete', icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>', iconColor: '#ff4444', isDestructive: true,
                    onClick: () => { const idx = currentPreset.value.blocks.findIndex(b => b.id === blockId); if (idx !== -1) currentPreset.value.blocks.splice(idx, 1); closeBottomSheet(); }
                },
                { label: t('btn_cancel') || 'Cancel', onClick: () => closeBottomSheet() }
            ]
        });
    }

    function onDragStart(event, blockId) {
        const index = currentPreset.value.blocks.findIndex(b => b.id === blockId); if (index === -1) return;
        dragSrcIndex.value = index; event.dataTransfer.effectAllowed = 'move'; event.dataTransfer.dropEffect = 'move';
        const img = new Image(); img.src = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7'; event.dataTransfer.setDragImage(img, 0, 0);
        event.target.classList.add('dragging');
    }

    function onDragEnter(event, blockId) {
        const index = currentPreset.value.blocks.findIndex(b => b.id === blockId); if (index === -1) return;
        if (dragSrcIndex.value !== -1 && dragSrcIndex.value !== index) { const blocks = currentPreset.value.blocks; const item = blocks.splice(dragSrcIndex.value, 1)[0]; blocks.splice(index, 0, item); dragSrcIndex.value = index; }
    }

    function onDragEnd(event) { event.target.classList.remove('dragging'); dragSrcIndex.value = -1; }

    function onTouchStart(event, blockId) {
        const index = currentPreset.value.blocks.findIndex(b => b.id === blockId); if (index === -1) return;
        dragSrcIndex.value = index; const block = event.target.closest('.prompt-block'); if (block) block.classList.add('dragging'); document.body.style.overflow = 'hidden';
    }

    function onTouchMove(event) {
        if (dragSrcIndex.value === -1) return; event.preventDefault();
        const touch = event.touches[0]; const target = document.elementFromPoint(touch.clientX, touch.clientY); const block = target?.closest('.prompt-block');
        if (block && block.dataset.id !== undefined) {
            const targetId = block.dataset.id; const targetIndex = currentPreset.value.blocks.findIndex(b => b.id === targetId);
            if (targetIndex !== -1 && targetIndex !== dragSrcIndex.value) { const blocks = currentPreset.value.blocks; const item = blocks.splice(dragSrcIndex.value, 1)[0]; blocks.splice(targetIndex, 0, item); dragSrcIndex.value = targetIndex; }
        }
    }

    function onTouchEnd(event) {
        const block = event.target.closest('.prompt-block'); if (block) block.classList.remove('dragging');
        document.querySelectorAll('.prompt-block.dragging').forEach(el => el.classList.remove('dragging')); dragSrcIndex.value = -1; document.body.style.overflow = '';
    }

    return {
        dragSrcIndex,
        addNewBlock, openCopyBlockPresetPicker, openCopyBlockPicker,
        stashActiveBlock, unstashBlock, openStashSheet,
        deleteActiveBlock, confirmDeleteStashedBlock,
        onDragStart, onDragEnter, onDragEnd, onTouchStart, onTouchMove, onTouchEnd
    };
}
