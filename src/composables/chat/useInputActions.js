import { ref, nextTick } from 'vue';
import { hideKeyboard } from '@/core/services/keyboardHandler.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { publishAppEvent } from '@/core/events/eventHub.js';

export function useInputActions(props, emit, _chatInputRef, _isComposing, _updatePreview) {
    const attachedImage = ref(null);
    const imageInput = ref(null);
    const isGuidanceMode = ref(false);
    const guidanceType = ref('send');
    const guidanceText = ref('');
    const guidanceInput = ref(null);
    const isGuidanceFocused = ref(false);
    const isMainFocused = ref(false);

    const closeGuidance = () => {
        if (guidanceText.value.trim() !== '') {
            if (!confirm('Discard changes?')) return;
        }
        isGuidanceMode.value = false;
        guidanceText.value = '';
    };

    const toggleGuidanceMode = () => {
        if (isGuidanceMode.value && guidanceType.value === 'send') {
            closeGuidance();
        } else {
            isGuidanceMode.value = true;
            guidanceType.value = 'send';
            nextTick(() => { if (guidanceInput.value) guidanceInput.value.focus(); });
        }
    };

    const triggerImageUpload = () => {
        if (imageInput.value) imageInput.value.click();
    };

    const onImageSelected = (event) => {
        const file = event.target.files[0];
        if (file) {
            const reader = new FileReader();
            reader.onload = (e) => {
                attachedImage.value = e.target.result;
            };
            reader.readAsDataURL(file);
        }
        if (imageInput.value) imageInput.value.value = '';
    };

    const clearImage = () => {
        attachedImage.value = null;
    };

    const closeGuidanceSilent = () => {
        guidanceText.value = '';
        isGuidanceMode.value = false;
    };

    const handleSend = () => {
        if (props.isGenerating) {
            emit('send');
        } else if ((props.modelValue && props.modelValue.trim()) || attachedImage.value) {
            emit('send', attachedImage.value, guidanceText.value);
            attachedImage.value = null;
            closeGuidanceSilent();
        } else {
            if (!isGuidanceMode.value || guidanceType.value !== 'impersonate') {
                isGuidanceMode.value = true;
                guidanceType.value = 'impersonate';
                nextTick(() => { if (guidanceInput.value) guidanceInput.value.focus(); });
            } else {
                emit('magic-impersonate', guidanceText.value);
                closeGuidanceSilent();
            }
        }
    };

    const openFullScreenEditor = async () => {
        const isKeyboardOpen = document.body.classList.contains('keyboard-open');
        if (isKeyboardOpen) {
            await hideKeyboard();
        }
        publishAppEvent(APP_EVENTS.nav.openFsRequest, {
            value: props.modelValue,
            onSave: (newVal) => {
                emit('update:modelValue', newVal);
            }
        });
    };

    const onFocus = () => {
        isMainFocused.value = true;
    };

    const onBlur = () => {
        isMainFocused.value = false;
    };

    const onGuidanceFocus = () => {
        isGuidanceFocused.value = true;
    };

    const onGuidanceBlur = () => {
        isGuidanceFocused.value = false;
    };

    return {
        attachedImage,
        imageInput,
        isGuidanceMode,
        guidanceType,
        guidanceText,
        guidanceInput,
        isGuidanceFocused,
        isMainFocused,
        closeGuidance,
        toggleGuidanceMode,
        triggerImageUpload,
        onImageSelected,
        clearImage,
        handleSend,
        openFullScreenEditor,
        onFocus,
        onBlur,
        onGuidanceFocus,
        onGuidanceBlur,
    };
}

export function useMagicDrawer() {
    const isMagicMenuVisible = ref(false);
    const magicDrawerRef = ref(null);
    const isKeyboardOpen = ref(document.body.classList.contains('keyboard-open'));
    const isSwitchingToDrawer = ref(false);
    const inputWrapper = ref(null);
    const kbListeners = [];

    const toggleMagicMenu = async () => {
        if (isMagicMenuVisible.value) {
            isMagicMenuVisible.value = false;
        } else {
            if (isKeyboardOpen.value || document.body.classList.contains('keyboard-open')) {
                isSwitchingToDrawer.value = true;
                await hideKeyboard();
            } else {
                isMagicMenuVisible.value = true;
            }
        }
    };

    const closeMagicMenu = (e) => {
        if (e && e.target && e.target.closest && e.target.closest('.modal-overlay')) {
            return;
        }
        if (e && e.target && e.target.closest) {
            if (e.target.closest('#btn-magic')) return;
            if (e.target.closest('.chat-input-wrapper')) return;
            if (e.target.closest('.magic-drawer')) return;
        }
        isMagicMenuVisible.value = false;
    };

    return {
        isMagicMenuVisible,
        magicDrawerRef,
        isKeyboardOpen,
        isSwitchingToDrawer,
        inputWrapper,
        kbListeners,
        toggleMagicMenu,
        closeMagicMenu,
    };
}
