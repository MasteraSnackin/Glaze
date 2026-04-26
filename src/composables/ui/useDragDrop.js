import { ref } from 'vue';

/**
 * Universal drag and drop sort-on-drop mechanic.
 * 
 * @param {Object} options
 * @param {import('vue').Ref<Array>} [options.listRef] - Array ref to mutate natively on drop.
 * @param {Function} [options.getIndex] - Function resolving an argument (like ID) to the array index.
 * @param {Function} [options.onSwap] - Callback fired after swap (fromIdx, toIdx).
 * @param {string} [options.itemSelector='.dragging-item'] - CSS selector for the draggable container.
 */
export function useDragDrop(options = {}) {
    const { listRef, onSwap, itemSelector = '.dragging-item' } = options;
    const dragIndex = ref(-1);
    const dropTargetIndex = ref(-1);

    function resolveIndex(arg) {
        if (typeof arg === 'number') return arg;
        if (typeof arg === 'string' && options.getIndex) return options.getIndex(arg);
        return -1;
    }

    function onDragStart(event, arg) {
        const index = resolveIndex(arg);
        if (index === -1) return;
        dragIndex.value = index;
        if (event.dataTransfer) {
            event.dataTransfer.effectAllowed = 'move';
            event.dataTransfer.dropEffect = 'move';
            // Allow native ghost image to generate before setting dragging class
            setTimeout(() => {
                const el = event.target.closest ? event.target.closest(itemSelector) : event.target;
                if (el) el.classList.add('dragging');
            }, 0);
        }
    }

    function onDragEnter(event, arg) {
        if (dragIndex.value === -1) return;
        const index = resolveIndex(arg);
        if (index !== -1) {
            dropTargetIndex.value = index;
        }
    }

    function onDrop(event, arg) {
        if (dragIndex.value === -1) return;
        event.preventDefault();
        const targetIndex = resolveIndex(arg);

        if (targetIndex !== -1 && targetIndex !== dragIndex.value) {
            executeSwap(dragIndex.value, targetIndex);
        }
        clearDrag(event);
    }

    function onDragEnd(event) {
        clearDrag(event);
    }

    function onTouchStart(event, arg) {
        const index = resolveIndex(arg);
        if (index === -1) return;
        dragIndex.value = index;
        const card = event.target.closest(itemSelector);
        if (card) card.classList.add('dragging');
        document.body.style.overflow = 'hidden';
    }

    function onTouchMove(event) {
        if (dragIndex.value === -1) return;
        event.preventDefault();
        const touch = event.touches[0];
        const target = document.elementFromPoint(touch.clientX, touch.clientY);
        const card = target?.closest(itemSelector);

        if (card) {
            if (card.dataset.id !== undefined && options.getIndex) {
                const hoverIndex = options.getIndex(card.dataset.id);
                if (hoverIndex !== -1) dropTargetIndex.value = hoverIndex;
            } else if (card.dataset.index !== undefined) {
                const hoverIndex = parseInt(card.dataset.index, 10);
                if (!isNaN(hoverIndex) && hoverIndex !== -1) dropTargetIndex.value = hoverIndex;
            }
        }
    }

    function onTouchEnd(event) {
        if (dragIndex.value !== -1 && dropTargetIndex.value !== -1 && dragIndex.value !== dropTargetIndex.value) {
            executeSwap(dragIndex.value, dropTargetIndex.value);
        }
        document.body.style.overflow = '';
        clearDrag(event);
    }

    function executeSwap(from, to) {
        if (listRef && listRef.value) {
            const list = listRef.value;
            const item = list[from];
            list.splice(from, 1);
            list.splice(to, 0, item);
        }
        if (onSwap) onSwap(from, to);
    }

    function clearDrag(event) {
        dragIndex.value = -1;
        dropTargetIndex.value = -1;

        if (event && event.target && event.target.closest) {
            const card = event.target.closest(itemSelector);
            if (card) card.classList.remove('dragging');
        }
        // Fallback cleanup
        document.querySelectorAll(itemSelector + '.dragging').forEach(el => el.classList.remove('dragging'));
    }

    return {
        dragIndex,
        dropTargetIndex,
        onDragStart,
        onDragEnter,
        onDrop,
        onDragEnd,
        onTouchStart,
        onTouchMove,
        onTouchEnd
    };
}
