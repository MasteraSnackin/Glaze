import { ref, computed } from 'vue';

export function useSheetGestures({ isVisible, isExpanded, isSidebarMode, fitContent, emit, close }) {
    const isDragging = ref(false);
    const startY = ref(0);
    const currentDragY = ref(0);
    // Velocity tracking for snappy swipes
    const lastY = ref(0);
    const lastTime = ref(0);
    const velocityY = ref(0);

    const sheetStyle = computed(() => {
        if (isSidebarMode.value) {
            return {
                height: '100%',
                transform: 'none',
                borderRadius: '0',
                boxShadow: 'none',
                maxWidth: 'none',
                border: 'none',
                background: 'transparent'
            };
        }
        if (!isVisible.value) {
            if (fitContent.value) {
                return {
                    transform: 'translate3d(0, 100%, 0)',
                    height: 'auto',
                    paddingBottom: '0px',
                    '--sheet-translate': '0px'
                };
            }
            return {
                transform: 'translate3d(0, 100vh, 0)',
                height: '100vh',
                paddingBottom: isExpanded.value ? '0vh' : '15vh',
                '--sheet-translate': isExpanded.value ? '0vh' : '15vh'
            };
        }

        if (fitContent.value) {
            const t = isDragging.value ? currentDragY.value : 0;
            return {
                transform: `translate3d(0, ${t}px, 0)`,
                height: 'auto',
                paddingBottom: '0px',
                '--sheet-translate': `${t}px`
            };
        }

        const baseTranslateVh = isExpanded.value ? 0 : 15;
        const dragDeltaVh = (currentDragY.value / window.innerHeight) * 100;
        const targetTranslateVh = baseTranslateVh + dragDeltaVh;

        if (isDragging.value && targetTranslateVh < 0) {
            // Stretching: height grows, translateY stays 0 so bottom stays at 100%
            return {
                height: `calc(100vh + ${Math.abs(targetTranslateVh)}vh)`,
                transform: 'translate3d(0, 0, 0)',
                paddingBottom: '0px',
                '--sheet-translate': '0vh'
            };
        } else {
            // Normal movement
            const t = isDragging.value ? targetTranslateVh : baseTranslateVh;
            return {
                height: '100vh',
                transform: `translate3d(0, ${t}vh, 0)`,
                paddingBottom: `${t}vh`,
                '--sheet-translate': `${t}vh`
            };
        }
    });

    // Tap on pill: collapsed → expanded, expanded → collapsed
    function toggle() {
        if (fitContent.value || isSidebarMode.value) {
            if (!isSidebarMode.value) close();
            return;
        }
        isExpanded.value = !isExpanded.value;
        emit('update:expanded', isExpanded.value);
    }

    function onHandleTouchStart(e) {
        if (isSidebarMode.value) return;
        if (e.target.closest('.header-btn') || e.target.closest('.clickable-no-drag') || e.target.closest('.sub-tab-btn')) return;
        isDragging.value = true;
        startY.value = e.touches[0].clientY;
        lastY.value = startY.value;
        lastTime.value = Date.now();
        velocityY.value = 0;
        currentDragY.value = 0;
    }

    function onHandleTouchMove(e) {
        if (!isDragging.value || isSidebarMode.value) return;
        const now = Date.now();
        const clientY = e.touches[0].clientY;
        const dt = now - lastTime.value;
        if (dt > 0) {
            velocityY.value = (clientY - lastY.value) / dt; // px/ms
        }
        lastY.value = clientY;
        lastTime.value = now;

        const delta = clientY - startY.value;
        // When expanded, drag up adds resistance; drag down slides freely
        if ((isExpanded.value || fitContent.value) && delta < 0) {
            currentDragY.value = delta * 0.15; // rubber-band resistance upward
        } else {
            currentDragY.value = delta;
        }
    }

    function onHandleTouchEnd() {
        if (!isDragging.value || isSidebarMode.value) return;
        isDragging.value = false;

        const dy = currentDragY.value;
        const vel = velocityY.value; // px/ms, positive = downward
        // Use velocity for snappy swipes (> 0.4 px/ms) or position threshold
        const fastDown = vel > 0.4;
        const fastUp = vel < -0.4;

        if (fastDown || dy > 80) {
            // Swipe down
            if (isExpanded.value) {
                isExpanded.value = false;
                emit('update:expanded', false);
            } else {
                close();
            }
        } else if ((fastUp || dy < -40) && !isExpanded.value && !fitContent.value) {
            // Swipe up → expand
            isExpanded.value = true;
            emit('update:expanded', true);
        }
        currentDragY.value = 0;
        velocityY.value = 0;
    }

    return {
        isDragging,
        sheetStyle,
        toggle,
        onHandleTouchStart,
        onHandleTouchMove,
        onHandleTouchEnd
    };
}
