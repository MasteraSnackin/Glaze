import { ref, reactive, watch, nextTick } from 'vue';
import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { t } from '@/utils/i18n.js';
import { logger } from '@/utils/logger.js';

export function usePresetNavigation({ sheet, props }) {
    const scrollPositions = { list: 0, editor: 0, 'block-editor': 0 };

    const editingPresetId = ref(null);
    const optimisticGlobalPresetId = ref(null);
    const isEditingBlock = ref(false);
    const editingBlockId = ref(null);
    const showStash = ref(false);
    const navDirection = ref('forward');

    watch([editingPresetId, isEditingBlock], ([newE, newB], [oldE, oldB]) => {
        const getLevel = (e, b) => b ? 2 : (e ? 1 : 0);
        const newL = getLevel(newE, newB);
        const oldL = getLevel(oldE, oldB);
        navDirection.value = newL > oldL ? 'forward' : (newL < oldL ? 'back' : 'forward');
        if (newE && newE !== oldE) scrollPositions.editor = 0;
        if (newB && !oldB) scrollPositions['block-editor'] = 0;
    });

    const showAdvancedSettings = ref(false);
    const genSheetBodyRef = ref(null);

    const headerState = reactive({
        title: t('sheet_title_presets') || 'Presets',
        showBack: false,
        actions: []
    });

    function updateHeaderState() {
        headerState.title = t('sheet_title_presets') || 'Presets';
        headerState.showBack = isEditingBlock.value || !!editingPresetId.value;
        headerState.actions = [];
    }

    function goBackFromEditor() {
        if (isEditingBlock.value) {
            closeBlockEditor();
        } else if (editingPresetId.value) {
            editingPresetId.value = null;
            updateHeaderState();
        } else if (props.viewMode) {
            publishAppEvent(APP_EVENTS.nav.navigateTo, 'view-tools');
        } else {
            sheet.value?.close();
        }
    }

    function openBlockEditor(blockId) {
        logger.debug('[GenerationView] openBlockEditor', blockId);
        editingBlockId.value = blockId;
        isEditingBlock.value = true;
        nextTick(() => { updateHeaderState(); });
    }

    function closeBlockEditor() {
        logger.debug('[GenerationView] closeBlockEditor');
        isEditingBlock.value = false;
        editingBlockId.value = null;
        nextTick(() => { updateHeaderState(); });
    }

    function onTransitionBeforeLeave(el) {
        const key = el.getAttribute('data-scroll-key');
        const scroller = genSheetBodyRef.value?.closest('.sheet-view-body');
        if (key && scroller) scrollPositions[key] = scroller.scrollTop || 0;
    }

    function onTransitionBeforeEnter(el) {
        const key = el.getAttribute('data-scroll-key');
        if (key && scrollPositions[key] !== undefined) {
            const scroller = genSheetBodyRef.value?.closest('.sheet-view-body');
            if (scroller) {
                scroller.scrollTop = scrollPositions[key];
                nextTick(() => { scroller.scrollTop = scrollPositions[key]; });
            }
        }
    }

    watch(() => props.activeChatChar?.id, () => {
        editingPresetId.value = null;
    });

    return {
        scrollPositions,
        editingPresetId,
        optimisticGlobalPresetId,
        isEditingBlock,
        editingBlockId,
        showStash,
        navDirection,
        showAdvancedSettings,
        genSheetBodyRef,
        headerState,
        updateHeaderState,
        goBackFromEditor,
        openBlockEditor,
        closeBlockEditor,
        onTransitionBeforeLeave,
        onTransitionBeforeEnter
    };
}
