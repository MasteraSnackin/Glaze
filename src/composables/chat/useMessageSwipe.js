import { ref, computed, nextTick } from 'vue';
import { disableSwipeRegeneration, shouldUseBatterySaverUI } from '@/core/config/APPSettings.js';
import { getAllGreetings } from '@/utils/sessions.js';

export function useMessageSwipe(props, emit) {
    const isGuidedSwipeOpen = ref(false);
    const guidedSwipeText = ref('');
    const guidedSwipeInput = ref(null);

    const useLiteNativeRenderer = computed(() => shouldUseBatterySaverUI());
    const swipeTransitionName = computed(() => useLiteNativeRenderer.value ? 'transition-none' : (props.message.swipeDirection || 'slide-next'));
    const fadeTransitionName = computed(() => useLiteNativeRenderer.value ? 'transition-none' : 'fade');

    const toggleGuidedSwipe = () => {
        isGuidedSwipeOpen.value = !isGuidedSwipeOpen.value;
        if (isGuidedSwipeOpen.value) {
            nextTick(() => { if (guidedSwipeInput.value) guidedSwipeInput.value.focus(); });
        } else {
            guidedSwipeText.value = '';
        }
    };

    const submitGuidedSwipe = () => {
        emit('regenerate', 'guided', guidedSwipeText.value);
        isGuidedSwipeOpen.value = false;
        guidedSwipeText.value = '';
    };

    const isGuidanceEditing = ref(false);
    const guidanceEditText = ref('');

    const currentGuidance = computed(() => {
        if (props.message.role === 'char') {
            const meta = props.message.swipesMeta?.[props.message.swipeId || 0];
            if (meta && meta.guidanceText && meta.guidanceType === 'SWIPE') {
                return {
                    text: meta.guidanceText,
                    type: 'SWIPE'
                };
            }
            if (props.message.isTyping && props.message.guidanceText && props.message.guidanceType === 'SWIPE') {
                return {
                    text: props.message.guidanceText,
                    type: 'SWIPE'
                };
            }
            return null;
        }

        if (props.message.role === 'user' && props.message.guidanceText) {
            return {
                text: props.message.guidanceText,
                type: props.message.guidanceType || 'GENERATION'
            };
        }
        return null;
    });

    const startGuidanceEdit = () => {
        guidanceEditText.value = currentGuidance.value?.text || '';
        isGuidanceEditing.value = true;
    };

    const cancelGuidanceEdit = () => {
        isGuidanceEditing.value = false;
    };

    const saveGuidanceEdit = () => {
        emit('save-guidance', guidanceEditText.value.trim() || null);
        isGuidanceEditing.value = false;
    };

    // --- Touch / Swipe / Long-Press ---
    let swipeStartX = 0;
    let swipeStartY = 0;
    let isSwipeScrolling = false;
    let currentSwipeElement = null;
    let longPressTimer = null;
    let isLongPressTriggered = false;

    let hadSelectionOnStart = false;

    function handleTouchStart(e) {
        hadSelectionOnStart = false;
        const sel = window.getSelection();
        if (sel && sel.toString().trim().length > 0) {
            hadSelectionOnStart = true;
        }

        if (props.isSelectionMode) return;
        if (props.message.role !== 'char' || props.message.isEditing || props.isGenerating) {
            if (props.message.isEditing || props.isGenerating) return;
        } else {
            swipeStartX = e.touches[0].clientX;
            swipeStartY = e.touches[0].clientY;
            isSwipeScrolling = false;
            
            const section = e.currentTarget;
            const body = section.querySelector('.msg-body');
            if (body) {
                body.style.transition = 'none';
                currentSwipeElement = body;
            }
        }

        isLongPressTriggered = false;
        longPressTimer = setTimeout(() => {
            isLongPressTriggered = true;
            emit('toggle-selection');
            if (currentSwipeElement) {
                currentSwipeElement.style.transform = '';
                currentSwipeElement = null;
            }
        }, 500);
    }

    function handleTouchMove(e) {
        if (isLongPressTriggered) return;
        
        const dX = e.touches[0].clientX - (swipeStartX || e.touches[0].clientX);
        const dY = e.touches[0].clientY - (swipeStartY || e.touches[0].clientY);

        if (Math.abs(dX) > 10 || Math.abs(dY) > 10) {
            if (longPressTimer) {
                clearTimeout(longPressTimer);
                longPressTimer = null;
            }
        }

        if (!currentSwipeElement || props.message.role !== 'char' || props.message.isEditing) return;
        if (isSwipeScrolling) return;

        const deltaX = e.touches[0].clientX - swipeStartX;
        const deltaY = e.touches[0].clientY - swipeStartY;

        if (Math.abs(deltaY) > Math.abs(deltaX)) {
            isSwipeScrolling = true;
            return;
        }

        if (e.cancelable) e.preventDefault();

        const isFirstMsg = props.index === 0;
        const canSwitchGreeting = isFirstMsg && getAllGreetings(props.activeChatChar).length > 1;
        
        if (deltaX < 0) {
            if (!canSwitchGreeting) {
                if (!props.isLast && (props.message.swipeId || 0) >= (props.message.swipes?.length || 1) - 1) return;
            }
        } else if (deltaX > 0) {
            if (!canSwitchGreeting) {
                if ((props.message.swipeId || 0) <= 0) return;
            }
        }

        currentSwipeElement.style.transform = `translateX(${deltaX}px)`;
    }

    function handleTouchEnd(e) {
        if (longPressTimer) {
            clearTimeout(longPressTimer);
            longPressTimer = null;
        }

        if (isLongPressTriggered) {
            isLongPressTriggered = false;
            return;
        }

        if (!currentSwipeElement) return;
        
        const deltaX = e.changedTouches[0].clientX - swipeStartX;
        const body = currentSwipeElement;
        currentSwipeElement = null;
        
        if (isSwipeScrolling) {
            body.style.transform = '';
            return;
        }

        const isFirstMsg = props.index === 0;
        const canSwitchGreeting = isFirstMsg && getAllGreetings(props.activeChatChar).length > 1;

        const resetStyle = () => {
            body.style.transition = 'transform 0.3s ease';
            body.style.transform = '';
        };

        const animateChange = (callback) => {
            body.style.opacity = '0';
            callback();
            nextTick(() => {
                body.style.transform = '';
                setTimeout(() => {
                    body.style.transition = 'opacity 0.2s ease';
                    body.style.opacity = '1';
                    setTimeout(() => { body.style.transition = ''; }, 200);
                }, 50);
            });
        };

        if (canSwitchGreeting) {
            if (deltaX < -100) animateChange(() => emit('change-greeting', 1));
            else if (deltaX > 100) animateChange(() => emit('change-greeting', -1));
            else resetStyle();
            return;
        }

        if (deltaX < -100) {
            if ((props.message.swipeId || 0) < (props.message.swipes?.length || 1) - 1) {
                animateChange(() => emit('swipe', 1));
            } else if (props.isLast && !disableSwipeRegeneration.value) {
                body.style.transition = 'transform 0.1s';
                body.style.transform = `translateX(-20px)`;
                setTimeout(() => { 
                    body.style.transform = ''; 
                    emit('regenerate', 'new_variant');
                }, 100);
            } else {
                resetStyle();
            }
        } else if (deltaX > 100) {
            if ((props.message.swipeId || 0) > 0) animateChange(() => emit('swipe', -1));
            else resetStyle();
        } else {
            resetStyle();
        }
    }

    const handleMessageClick = () => {
        if (!props.isSelectionMode) return;
        
        if (hadSelectionOnStart) {
            hadSelectionOnStart = false;
            window.getSelection()?.removeAllRanges();
            return;
        }
        
        emit('toggle-selection');
    };

    return {
        isGuidedSwipeOpen,
        guidedSwipeText,
        guidedSwipeInput,
        useLiteNativeRenderer,
        swipeTransitionName,
        fadeTransitionName,
        toggleGuidedSwipe,
        submitGuidedSwipe,
        isGuidanceEditing,
        guidanceEditText,
        currentGuidance,
        startGuidanceEdit,
        cancelGuidanceEdit,
        saveGuidanceEdit,
        handleTouchStart,
        handleTouchMove,
        handleTouchEnd,
        handleMessageClick,
    };
}
