import { ref, computed } from 'vue';

const COLLAPSE_THRESHOLD = 120;
export const COLLAPSED_WIDTH = 64;

export function useSidebarResizer(storageKey, defaultWidth, direction = 'left', min = 200, max = 600) {
    const savedCollapsed = localStorage.getItem(storageKey + '_collapsed') === '1';
    const savedWidth = parseInt(localStorage.getItem(storageKey)) || defaultWidth;
    // Start at COLLAPSED_WIDTH if previously collapsed so sidebar shows correct initial size
    const width = ref(savedCollapsed ? COLLAPSED_WIDTH : savedWidth);
    const collapsed = computed(() => width.value < COLLAPSE_THRESHOLD);

    const startResize = (e) => {
        e.preventDefault();
        const startX = e.clientX;
        const startWidth = width.value;
        const originalCursor = document.body.style.cursor;
        document.body.style.cursor = 'col-resize';

        const onMouseMove = (moveEvent) => {
            const dx = moveEvent.clientX - startX;
            let newWidth = direction === 'left' ? startWidth + dx : startWidth - dx;
            // During drag: clamp to hard edges only, collapsed state is derived automatically
            if (newWidth < COLLAPSED_WIDTH) newWidth = COLLAPSED_WIDTH;
            if (newWidth > max) newWidth = max;
            width.value = newWidth;
        };

        const onMouseUp = () => {
            document.body.style.cursor = originalCursor;
            document.removeEventListener('mousemove', onMouseMove);
            document.removeEventListener('mouseup', onMouseUp);
            if (collapsed.value) {
                // Snap to resting collapsed width — CSS transition animates this
                width.value = COLLAPSED_WIDTH;
            } else {
                if (width.value < min) width.value = min;
                localStorage.setItem(storageKey, width.value);
            }
            localStorage.setItem(storageKey + '_collapsed', collapsed.value ? '1' : '0');
        };

        document.addEventListener('mousemove', onMouseMove);
        document.addEventListener('mouseup', onMouseUp);
    };

    return { width, collapsed, startResize };
}
