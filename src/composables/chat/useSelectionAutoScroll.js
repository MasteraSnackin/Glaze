import { onMounted, onBeforeUnmount } from 'vue';

const EDGE_ZONE = 50;
const SCROLL_SPEED = 8;
const SCROLL_INTERVAL = 16;

export function useSelectionAutoScroll(containerRef, isProgrammaticScrolling) {
    let scrollTimer = null;
    let isActive = false;

    function startScroll(direction) {
        stopScroll();
        if (isProgrammaticScrolling?.value !== undefined) {
            isProgrammaticScrolling.value = true;
        }
        scrollTimer = setInterval(() => {
            const el = containerRef.value;
            if (!el) return;
            el.scrollTop += direction * SCROLL_SPEED;
        }, SCROLL_INTERVAL);
    }

    function stopScroll() {
        if (scrollTimer) {
            clearInterval(scrollTimer);
            scrollTimer = null;
        }
        if (isProgrammaticScrolling?.value !== undefined) {
            isProgrammaticScrolling.value = false;
        }
    }

    function onTouchMove(e) {
        if (!isActive) return;

        const touch = e.touches?.[0];
        if (!touch) return;

        const el = containerRef.value;
        if (!el) return;

        const rect = el.getBoundingClientRect();
        const relY = touch.clientY - rect.top;
        const height = rect.height;

        if (relY < EDGE_ZONE) {
            const factor = 1 - relY / EDGE_ZONE;
            startScroll(-SCROLL_SPEED * factor);
        } else if (relY > height - EDGE_ZONE) {
            const factor = 1 - (height - relY) / EDGE_ZONE;
            startScroll(SCROLL_SPEED * factor);
        } else {
            stopScroll();
        }
    }

    function onTouchEnd() {
        isActive = false;
        stopScroll();
    }

    function onSelectionChange() {
        const sel = window.getSelection();
        if (sel && sel.toString().trim().length > 0) {
            isActive = true;
        } else {
            isActive = false;
            stopScroll();
        }
    }

    onMounted(() => {
        document.addEventListener('selectionchange', onSelectionChange, { passive: true });
        document.addEventListener('touchend', onTouchEnd, { passive: true });
        document.addEventListener('touchcancel', onTouchEnd, { passive: true });
        const el = containerRef.value;
        if (el) {
            el.addEventListener('touchmove', onTouchMove, { passive: true });
        }
    });

    onBeforeUnmount(() => {
        stopScroll();
        document.removeEventListener('selectionchange', onSelectionChange);
        document.removeEventListener('touchend', onTouchEnd);
        document.removeEventListener('touchcancel', onTouchEnd);
        const el = containerRef.value;
        if (el) {
            el.removeEventListener('touchmove', onTouchMove);
        }
    });
}
