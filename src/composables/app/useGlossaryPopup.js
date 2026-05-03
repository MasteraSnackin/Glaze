import { ref, reactive, computed } from 'vue';
import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';

export function useGlossaryPopup({ isDesktop }) {
    const isGlossaryWindowOpen = ref(false);
    const isDesktopGlossary = computed(() => isDesktop.value && isGlossaryWindowOpen.value);
    const glossaryPopupTitle = ref('');
    const glossaryCanGoBack = ref(false);
    const glossaryInitialTerm = ref(null);

    const glossaryPos = reactive({ x: 0, y: 0 });
    const glossaryStyle = computed(() => {
        if (glossaryPos.x === 0 && glossaryPos.y === 0) return {};
        return {
            top: `${glossaryPos.y}px`,
            left: `${glossaryPos.x}px`,
            bottom: 'auto',
            right: 'auto',
            transform: 'none',
            margin: 0
        };
    });

    let isDraggingGlossary = false;
    let glossaryDragStartX = 0;
    let glossaryDragStartY = 0;
    let glossaryInitialX = 0;
    let glossaryInitialY = 0;

    function onGlossaryHeaderUpdate(detail) {
        if (detail?.title !== undefined) glossaryPopupTitle.value = detail.title;
        if (detail?.canGoBack !== undefined) glossaryCanGoBack.value = detail.canGoBack;
    }

    function onGlossaryBack() {
        publishAppEvent(APP_EVENTS.ui.glossary.back);
    }

    function startGlossaryDrag(e) {
        if (e.target.closest('button')) return;
        isDraggingGlossary = true;
        glossaryDragStartX = e.clientX;
        glossaryDragStartY = e.clientY;

        const popup = document.querySelector('.desktop-glossary-popup');
        if (!popup) return;
        const rect = popup.getBoundingClientRect();
        if (glossaryPos.x === 0 && glossaryPos.y === 0) {
            glossaryPos.x = rect.left;
            glossaryPos.y = rect.top;
        }
        glossaryInitialX = glossaryPos.x;
        glossaryInitialY = glossaryPos.y;

        window.addEventListener('mousemove', onGlossaryDrag);
        window.addEventListener('mouseup', stopGlossaryDrag);
    }

    function onGlossaryDrag(e) {
        if (!isDraggingGlossary) return;
        const dx = e.clientX - glossaryDragStartX;
        const dy = e.clientY - glossaryDragStartY;
        glossaryPos.x = Math.max(0, Math.min(window.innerWidth - 100, glossaryInitialX + dx));
        glossaryPos.y = Math.max(0, Math.min(window.innerHeight - 50, glossaryInitialY + dy));
    }

    function stopGlossaryDrag() {
        isDraggingGlossary = false;
        window.removeEventListener('mousemove', onGlossaryDrag);
        window.removeEventListener('mouseup', stopGlossaryDrag);
    }

    function handleGlossaryToggle() {
        if (isDesktop.value) {
            isGlossaryWindowOpen.value = !isGlossaryWindowOpen.value;
        }
    }

    function handleGlossaryOpen(e) {
        if (isDesktop.value) {
            const wasClosed = !isGlossaryWindowOpen.value;

            if (wasClosed && e?.detail?.term) {
                glossaryInitialTerm.value = e.detail.term;
            }

            isGlossaryWindowOpen.value = true;
        }
    }

    return {
        isGlossaryWindowOpen,
        isDesktopGlossary,
        glossaryPopupTitle,
        glossaryCanGoBack,
        glossaryInitialTerm,
        glossaryStyle,
        onGlossaryHeaderUpdate,
        onGlossaryBack,
        startGlossaryDrag,
        stopGlossaryDrag,
        handleGlossaryToggle,
        handleGlossaryOpen
    };
}
