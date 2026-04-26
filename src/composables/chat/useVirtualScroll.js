// src/composables/useVirtualScroll.js
import { ref, computed, watch, nextTick, onBeforeUnmount, unref } from 'vue';
import { Capacitor } from '@capacitor/core';
import { shouldUseBatterySaverUI } from '@/core/config/APPSettings.js';

export function useVirtualScroll(itemsRef, containerRef, options = {}) {
    const getBuffer = () => unref(options.buffer) ?? 10;
    const estimateHeight = options.estimateHeight ?? 80; // Fallback height for unmeasured items

    // State
    const renderStart = ref(0);
    const renderEnd = ref(20); // Initial chunk size
    const paddingTop = ref(0);
    const paddingBottom = ref(0);
    const columns = ref(1);
    const isScrolling = ref(false);
    const isProgrammaticScrolling = ref(false);
    let scrollTimeout = null;
    let scrollRaf = null;

    // Cache for item heights: index -> height
    const itemHeights = new Map();

    // Set of currently visible indices (intersecting the viewport)
    const visibleIndices = new Set();
    // Set of indices actually visible on screen (ignoring rootMargin)
    const realVisibleIndices = new Set();

    let observer = null;
    let realObserver = null;
    let gridResizeObserver = null;

    // Computed slice of items to render
    // We wrap them to preserve original index
    const visibleItems = computed(() => {
        const items = itemsRef.value || [];
        const start = Math.max(0, renderStart.value);
        const end = Math.min(items.length, renderEnd.value);

        const slice = [];
        for (let i = start; i < end; i++) {
            slice.push({
                item: items[i],
                index: i,
                key: `${items[i].id || items[i].timestamp || ''}_${i}` // Ensure strictly unique keys to prevent duplication artifacts
            });
        }
        return slice;
    });

    // Calculate spacers based on heights
    const updateSpacers = () => {
        const items = itemsRef.value || [];
        const start = renderStart.value;
        const end = renderEnd.value;
        const total = items.length;
        const cols = columns.value;

        // Calculate Top Padding
        let top = 0;
        for (let i = 0; i < start; i += cols) {
            let rowHeight = 0;
            for (let j = 0; j < cols && i + j < start; j++) {
                const h = itemHeights.get(i + j) || estimateHeight;
                if (h > rowHeight) rowHeight = h;
            }
            top += rowHeight;
        }
        paddingTop.value = top;

        // Calculate Bottom Padding
        let bottom = 0;
        let rowStart = end;
        if (cols > 1) {
            rowStart = Math.ceil(end / cols) * cols;
        }
        for (let i = rowStart; i < total; i += cols) {
            let rowHeight = 0;
            for (let j = 0; j < cols && i + j < total; j++) {
                const h = itemHeights.get(i + j) || estimateHeight;
                if (h > rowHeight) rowHeight = h;
            }
            bottom += rowHeight;
        }
        paddingBottom.value = bottom;
    };

    // Update the render window based on what's visible
    const updateWindow = () => {
        if (visibleIndices.size === 0) return;

        const indices = Array.from(visibleIndices).sort((a, b) => a - b);
        const minVis = indices[0];
        const maxVis = indices[indices.length - 1];
        const total = itemsRef.value?.length || 0;

        // Expand window by buffer
        const buffer = getBuffer();
        const cols = columns.value;
        let newStart = Math.max(0, minVis - buffer);
        let newEnd = Math.min(total, maxVis + buffer + 1);

        if (cols > 1) {
            newStart = Math.floor(newStart / cols) * cols;
            newEnd = Math.ceil(newEnd / cols) * cols;
            newEnd = Math.min(total, newEnd);
        }

        // Only update if changed significantly to avoid thrashing
        if (newStart !== renderStart.value || newEnd !== renderEnd.value) {
            renderStart.value = newStart;
            renderEnd.value = newEnd;
            updateSpacers();
        }
    };

    const observeItems = () => {
        if (!containerRef.value) return;
        // Disconnect and reinitialize observers to clear stale element references
        // This prevents unbounded growth of observed elements across item updates
        if (observer) observer.disconnect();
        if (realObserver) realObserver.disconnect();

        const children = containerRef.value.querySelectorAll('[data-index]');
        if (!observer || !realObserver) return;
        children.forEach(el => {
            observer.observe(el);
            realObserver.observe(el);
        });
    };

    // Handle programmatic or fast scrolling
    const onContainerScroll = () => {
        if (!containerRef.value || isProgrammaticScrolling.value) return;

        // Set scrolling state for UI optimizations (e.g. disable pointer-events)
        if (!isScrolling.value) isScrolling.value = true;
        clearTimeout(scrollTimeout);
        scrollTimeout = setTimeout(() => {
            isScrolling.value = false;
        }, 150);

        const runScrollWork = () => {
            scrollRaf = null;

            const scrollTop = containerRef.value.scrollTop;
            const clientHeight = containerRef.value.clientHeight;

            // Define the rendered area in pixels
            const renderedTop = paddingTop.value;

            // Calculate height of currently rendered items
            let renderedContentHeight = 0;
            const start = renderStart.value;
            const end = renderEnd.value;
            const cols = columns.value;

            for (let i = start; i < end; i += cols) {
                let rowHeight = 0;
                for (let j = 0; j < cols && i + j < end; j++) {
                    const h = itemHeights.get(i + j) || estimateHeight;
                    if (h > rowHeight) rowHeight = h;
                }
                renderedContentHeight += rowHeight;
            }
            const renderedBottom = renderedTop + renderedContentHeight;

            // Buffer to detect "jump" (scrolled far outside rendered area)
            // We use a large buffer so normal scrolling is handled by IntersectionObserver
            // Increased to 2000 to match larger render buffers and prevent jitter
            const scrollBuffer = 2000;

            // Check if viewport is significantly outside the rendered bounds
            if (scrollTop < renderedTop - scrollBuffer || scrollTop + clientHeight > renderedBottom + scrollBuffer) {
                // We jumped far away. Recalculate window.

                // Find target index at scrollTop
                let currentTop = 0;
                let targetIndex = -1;
                const count = itemsRef.value.length;

                for (let i = 0; i < count; i += cols) {
                    let rowHeight = 0;
                    for (let j = 0; j < cols && i + j < count; j++) {
                        const h = itemHeights.get(i + j) || estimateHeight;
                        if (h > rowHeight) rowHeight = h;
                    }
                    if (currentTop + rowHeight > scrollTop) {
                        targetIndex = i;
                        break;
                    }
                    currentTop += rowHeight;
                }

                // If we scrolled past the end (estimation error), target the last item
                if (targetIndex === -1) targetIndex = Math.max(0, count - 1);

                // Center window around target
                const buffer = getBuffer();
                let newStart = Math.max(0, targetIndex - buffer);

                // Estimate end based on clientHeight
                let hSum = 0;
                let i = targetIndex;
                while (hSum < clientHeight + 1000 && i < count) {
                    let rowHeight = 0;
                    for (let j = 0; j < cols && i + j < count; j++) {
                        const h = itemHeights.get(i + j) || estimateHeight;
                        if (h > rowHeight) rowHeight = h;
                    }
                    hSum += rowHeight;
                    i += cols;
                }
                let newEnd = Math.min(count, i + buffer);

                if (cols > 1) {
                    newStart = Math.floor(newStart / cols) * cols;
                    newEnd = Math.ceil(newEnd / cols) * cols;
                    newEnd = Math.min(count, newEnd);
                }

                if (newStart !== renderStart.value || newEnd !== renderEnd.value) {
                    renderStart.value = newStart;
                    renderEnd.value = newEnd;
                    visibleIndices.clear(); // Clear stale indices to prevent window expansion ghosting
                    realVisibleIndices.clear();
                    updateSpacers();
                    nextTick(observeItems);
                }
            } else if (!shouldUseBatterySaverUI()) {
                // Periodic visibility health check during normal scroll
                // This ensures realVisibleIndices doesn't get stuck if Observer missed a fast transition
                const children = containerRef.value.querySelectorAll('[data-index]');
                const containerRect = containerRef.value.getBoundingClientRect();
                const style = window.getComputedStyle(containerRef.value);
                const paddingBottom = parseFloat(style.paddingBottom) || 0;
                const visibleBottom = containerRect.bottom - paddingBottom;
                const visibleTop = containerRect.top;

                children.forEach(el => {
                    const index = parseInt(el.dataset.index);
                    if (isNaN(index)) return;
                    const rect = el.getBoundingClientRect();

                    // If the top is above visible bottom AND bottom is below visible top
                    if (rect.top < visibleBottom - 20 && rect.bottom > visibleTop + 20) {
                        realVisibleIndices.add(index);
                    } else {
                        realVisibleIndices.delete(index);
                    }
                });
            }
        };

        if (shouldUseBatterySaverUI()) {
            if (scrollRaf) return;
            scrollRaf = requestAnimationFrame(runScrollWork);
            return;
        }

        runScrollWork();
    };

    const getScrollAnchor = () => {
        if (!containerRef.value) return null;

        const children = containerRef.value.querySelectorAll('[data-index]');
        if (!children || children.length === 0) {
            return { index: (itemsRef.value?.length || 0) - 1, offset: 0 };
        }

        const containerTop = containerRef.value.getBoundingClientRect().top;

        for (const child of children) {
            const rect = child.getBoundingClientRect();
            if (rect.bottom > containerTop) {
                const index = parseInt(child.dataset.index);
                if (!isNaN(index)) {
                    return { index, offset: containerTop - rect.top };
                }
            }
        }
        return { index: (itemsRef.value?.length || 0) - 1, offset: 0 };
    };

    const scrollToAnchor = (anchor) => {
        return new Promise((resolve) => {
            if (!anchor || typeof anchor.index !== 'number') {
                resolve();
                return;
            }
            const count = itemsRef.value.length;
            if (count === 0) {
                resolve();
                return;
            }

            const index = Math.max(0, Math.min(anchor.index, count - 1));

            // Lock scroll handler to prevent "jump" logic from interfering
            isProgrammaticScrolling.value = true;

            const buffer = getBuffer();
            const cols = columns.value;
            let newStart = Math.max(0, index - buffer);
            let newEnd = Math.min(count, index + buffer + 1);

            if (cols > 1) {
                newStart = Math.floor(newStart / cols) * cols;
                newEnd = Math.ceil(newEnd / cols) * cols;
                newEnd = Math.min(count, newEnd);
            }

            renderStart.value = newStart;
            renderEnd.value = newEnd;

            visibleIndices.clear();
            updateSpacers();

            nextTick(() => {
                if (containerRef.value) {
                    // Measure rendered items immediately to ensure accuracy
                    const children = containerRef.value.querySelectorAll('[data-index]');
                    children.forEach(el => {
                        const idx = parseInt(el.dataset.index);
                        if (!isNaN(idx)) {
                            const h = el.getBoundingClientRect().height;
                            if (h > 0) itemHeights.set(idx, h);
                        }
                    });

                    let targetTop = paddingTop.value;
                    const cols = columns.value;
                    const alignedIndex = Math.floor(index / cols) * cols;

                    for (let i = renderStart.value; i < alignedIndex; i += cols) {
                        let rowHeight = 0;
                        for (let j = 0; j < cols && i + j < alignedIndex; j++) {
                            const h = itemHeights.get(i + j) || estimateHeight;
                            if (h > rowHeight) rowHeight = h;
                        }
                        targetTop += rowHeight;
                    }
                    targetTop += (anchor.offset || 0);

                    // Fix: Account for container padding-top (e.g. header space)
                    const style = window.getComputedStyle(containerRef.value);
                    const containerPaddingTop = parseFloat(style.paddingTop) || 0;
                    targetTop += containerPaddingTop;

                    containerRef.value.scrollTop = targetTop;
                    observeItems();

                    // Unlock after a short delay to let scroll settle
                    setTimeout(() => {
                        isProgrammaticScrolling.value = false;
                        resolve();
                    }, 50);
                } else {
                    resolve();
                }
            });
        });
    };

    // Force scroll to bottom helper
    const scrollToBottom = (behavior = 'auto') => {
        const count = itemsRef.value.length;
        if (count === 0) return;

        let effectiveBehavior = behavior;

        // Check distance to determine if we should smooth scroll
        if (containerRef.value) {
            const { scrollTop, scrollHeight, clientHeight } = containerRef.value;
            // If distance is large (> 3000px), force auto to avoid "stuck in middle" issues
            if (scrollHeight - scrollTop - clientHeight > 3000) {
                effectiveBehavior = 'auto';
            }
        }

        // Force render window to end immediately
        renderStart.value = Math.max(0, count - 20);
        renderEnd.value = count;
        visibleIndices.clear();
        updateSpacers();

        // Lock scrolling to prevent observer interference
        isProgrammaticScrolling.value = true;

        nextTick(() => {
            // Need to double nextTick to allow Vue to render the newly added items first
            nextTick(() => {
                requestAnimationFrame(() => {
                    if (containerRef.value) {
                        // Ensure layout is updated and scroll to bottom
                        const doScroll = () => {
                            if (containerRef.value) {
                                containerRef.value.scrollTop = containerRef.value.scrollHeight;
                                observeItems();

                                const timeout = effectiveBehavior === 'smooth' ? 500 : 150;
                                setTimeout(() => { isProgrammaticScrolling.value = false; }, timeout);
                            }
                        };

                        if (effectiveBehavior === 'smooth') {
                            containerRef.value.scrollTo({ top: containerRef.value.scrollHeight, behavior: 'smooth' });
                            observeItems();
                            setTimeout(() => { isProgrammaticScrolling.value = false; }, 500);
                        } else {
                            doScroll();
                            // Double check if layout shifted after scroll
                            setTimeout(doScroll, 50);
                        }
                    }
                });
            });
        });
    };

    // Initialize Observers
    const initObservers = () => {
        if (observer) observer.disconnect();

        observer = new IntersectionObserver((entries) => {
            let changed = false;
            entries.forEach(entry => {
                const index = parseInt(entry.target.dataset.index);
                if (isNaN(index)) return;

                // Update height cache
                const rect = entry.boundingClientRect;
                if (rect.height > 0) {
                    itemHeights.set(index, rect.height);
                }

                if (entry.isIntersecting) {
                    visibleIndices.add(index);
                    changed = true;
                } else {
                    visibleIndices.delete(index);
                    changed = true; // Visibility changed
                }
            });

            if (changed) {
                updateWindow();
            }
        }, {
            root: containerRef.value,
            threshold: 0.01, // Trigger as soon as 1% is visible
            rootMargin: '1000px' // Pre-load margin significantly increased
        });

        realObserver = new IntersectionObserver((entries) => {
            entries.forEach(entry => {
                const index = parseInt(entry.target.dataset.index);
                if (isNaN(index)) return;

                if (entry.isIntersecting) {
                    // Check if it's actually within the visible (non-padded) area
                    // We check if the element's top is below the container's visible bottom
                    const container = containerRef.value;
                    if (container) {
                        const containerRect = container.getBoundingClientRect();
                        const entryRect = entry.boundingClientRect;

                        // Get current padding bottom (reserved for keyboard/input)
                        const style = window.getComputedStyle(container);
                        const paddingBottom = parseFloat(style.paddingBottom) || 0;
                        const visibleBottom = containerRect.bottom - paddingBottom;

                        // If the top of the message is already below the visible area, it's "behind" the keyboard
                        if (entryRect.top >= visibleBottom - 20) {
                            realVisibleIndices.delete(index);
                            return;
                        }
                    }
                    realVisibleIndices.add(index);
                } else {
                    realVisibleIndices.delete(index);
                }
            });
        }, {
            root: containerRef.value,
            threshold: [0, 0.1, 0.5, 1.0] // Multi-threshold for better tracking
        });

        // Observe all rendered items
        nextTick(() => {
            observeItems();
        });

        if (options.grid) {
            updateColumns();
            gridResizeObserver = new ResizeObserver(() => updateColumns());
            gridResizeObserver.observe(containerRef.value);
        }
    };

    const updateColumns = () => {
        if (!options.grid || !containerRef.value) return;
        const style = window.getComputedStyle(containerRef.value);
        const gridCols = style.gridTemplateColumns;
        if (gridCols && gridCols !== 'none') {
            const numCols = gridCols.split(' ').length;
            if (columns.value !== numCols) {
                columns.value = numCols > 0 ? numCols : 1;
                // If columns changed, we re-evaluate everything
                updateWindow();
                updateSpacers();
            }
        }
    };

    // Watchers
    watch(itemsRef, (newItems, oldItems) => {
        const newLen = newItems ? newItems.length : 0;
        const oldLen = oldItems ? oldItems.length : 0;

        // If items added to bottom (chat scenario), auto-expand end
        if (newLen > oldLen) {
            renderEnd.value = newLen;
            // If we were at the bottom, keep us at the bottom
            // (ChatView handles scroll, we just ensure it's rendered)
            const wasAtBottom = containerRef.value && (containerRef.value.scrollHeight - containerRef.value.scrollTop - containerRef.value.clientHeight < 100);
            if (wasAtBottom) {
                // Use slight delay to allow dom updates
                setTimeout(() => {
                    scrollToBottom('auto');
                }, 50);
            }
        }
        updateSpacers();
        nextTick(observeItems);
    });

    // Handle deep changes (like text streaming) updating heights
    // We use a ResizeObserver on the container to detect layout shifts if needed,
    // but for specific items, we rely on re-observation or manual trigger.
    // Since ChatView updates text, the DOM element size changes.
    // IntersectionObserver updates rect on intersection, but not on resize if already visible.
    // We can add a ResizeObserver for visible items if strict precision is needed.

    watch(visibleItems, () => {
        nextTick(observeItems);
    });

    // Public method to force refresh (e.g. after chat switch)
    const refresh = () => {
        itemHeights.clear();
        visibleIndices.clear();
        renderStart.value = Math.max(0, (itemsRef.value?.length || 0) - 20); // Start at bottom for chat
        renderEnd.value = itemsRef.value?.length || 0;
        updateSpacers();
        nextTick(() => {
            initObservers();
            // Force update spacers after render
            setTimeout(updateSpacers, 100);
        });
    };

    // Lifecycle
    watch(containerRef, (el, oldEl) => {
        if (oldEl) {
            oldEl.removeEventListener('scroll', onContainerScroll);
        }
        if (el) {
            initObservers();
            el.addEventListener('scroll', onContainerScroll, { passive: true });
        }
    });

    onBeforeUnmount(() => {
        if (observer) observer.disconnect();
        if (realObserver) realObserver.disconnect();
        if (gridResizeObserver) gridResizeObserver.disconnect();
        if (containerRef.value) {
            containerRef.value.removeEventListener('scroll', onContainerScroll);
        }
        if (scrollRaf) {
            cancelAnimationFrame(scrollRaf);
            scrollRaf = null;
        }
    });

    const scrollToIndex = (index, behavior = 'auto', align = 'center') => {
        return new Promise((resolve) => {
            if (typeof index !== 'number') {
                resolve();
                return;
            }
            const count = itemsRef.value.length;
            if (count === 0) {
                resolve();
                return;
            }

            index = Math.max(0, Math.min(index, count - 1));

            isProgrammaticScrolling.value = true;

            // Check if already in rendered range and within visible bounds roughly
            if (index >= renderStart.value && index < renderEnd.value && containerRef.value) {
                nextTick(() => {
                    const el = containerRef.value.querySelector(`[data-index="${index}"]`);
                    if (el) {
                        const containerRect = containerRef.value.getBoundingClientRect();
                        const elRect = el.getBoundingClientRect();
                        let targetTop = containerRef.value.scrollTop + (elRect.top - containerRect.top);

                        if (align === 'center') {
                            const style = window.getComputedStyle(containerRef.value);
                            const containerPaddingTop = parseFloat(style.paddingTop) || 0;
                            const containerPaddingBottom = parseFloat(style.paddingBottom) || 0;
                            const visibleHeight = containerRect.height - containerPaddingTop - containerPaddingBottom;
                            targetTop = targetTop - containerPaddingTop - (visibleHeight / 2) + (elRect.height / 2);
                        } else if (align === 'top') {
                            const style = window.getComputedStyle(containerRef.value);
                            const containerPaddingTop = parseFloat(style.paddingTop) || 0;
                            targetTop = targetTop - containerPaddingTop;
                            targetTop -= 10; // Extra margin
                        }

                        containerRef.value.scrollTo({ top: Math.max(0, targetTop), behavior });
                    }
                    setTimeout(() => { isProgrammaticScrolling.value = false; resolve(); }, behavior === 'smooth' ? 300 : 50);
                });
                return;
            }

            // If completely out of bounds, change render window
            const buffer = getBuffer();
            const cols = columns.value;
            let newStart = Math.max(0, index - buffer);
            let newEnd = Math.min(count, index + buffer + 1);

            if (cols > 1) {
                newStart = Math.floor(newStart / cols) * cols;
                newEnd = Math.ceil(newEnd / cols) * cols;
                newEnd = Math.min(count, newEnd);
            }

            renderStart.value = newStart;
            renderEnd.value = newEnd;

            visibleIndices.clear();
            updateSpacers();

            nextTick(() => {
                if (containerRef.value) {
                    // Measure rendered items immediately
                    const children = containerRef.value.querySelectorAll('[data-index]');
                    children.forEach(el => {
                        const idx = parseInt(el.dataset.index);
                        if (!isNaN(idx)) {
                            const h = el.getBoundingClientRect().height;
                            if (h > 0) itemHeights.set(idx, h);
                        }
                    });

                    let targetTop = paddingTop.value;
                    const cols = columns.value;
                    const alignedIndex = Math.floor(index / cols) * cols;

                    for (let i = renderStart.value; i < alignedIndex; i += cols) {
                        let rowHeight = 0;
                        for (let j = 0; j < cols && i + j < alignedIndex; j++) {
                            const h = itemHeights.get(i + j) || estimateHeight;
                            if (h > rowHeight) rowHeight = h;
                        }
                        targetTop += rowHeight;
                    }

                    const itemH = itemHeights.get(index) || estimateHeight;

                    if (align === 'center') {
                        targetTop = targetTop - (containerRef.value.clientHeight / 2) + (itemH / 2);
                        const style = window.getComputedStyle(containerRef.value);
                        const containerPaddingTop = parseFloat(style.paddingTop) || 0;
                        targetTop += containerPaddingTop;
                    } else if (align === 'top') {
                        targetTop -= 10; // Extra margin
                    }

                    containerRef.value.scrollTo({ top: Math.max(0, targetTop), behavior });
                    observeItems();

                    setTimeout(() => {
                        isProgrammaticScrolling.value = false;
                        resolve();
                    }, behavior === 'smooth' ? 300 : 50);
                } else {
                    resolve();
                }
            });
        });
    };

    const isItemVisible = (index) => realVisibleIndices.has(index);

    return {
        visibleItems,
        paddingTop,
        paddingBottom,
        refresh,
        scrollToBottom,
        isScrolling,
        isProgrammaticScrolling,
        getScrollAnchor,
        scrollToAnchor,
        scrollToIndex,
        isItemVisible
    };
}
