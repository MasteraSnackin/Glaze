import { generateChat } from '@/core/llm/usecases/generateChat.js';
import { getEffectivePreset } from '@/core/states/presetState.js';

export async function executeImpersonationUseCase({
    char,
    guidanceText,
    controller,
    services
}) {
    const {
        notifyGenerationStarted,
        notifyGenerationEnded
    } = services.app;

    const {
        setGenerationState,
        clearGenerationState,
        nextGenerationId,
        buildGenerationHistory,
        cleanText
    } = services.lifecycle;

    const {
        inputValue,
        isImpersonating,
        isGenerating,
        currentMessages,
        activeChatChar,
        showBottomSheet,
        closeBottomSheet,
        openApiView,
        t
    } = services.state;

    const charId = char.id;

    let preset = null;
    try {
        const chatId = charId && char?.sessionId ? `${charId}_${char.sessionId}` : null;
        preset = getEffectivePreset(charId, chatId);
    } catch (e) { }

    const promptText = preset ? (preset.impersonationPrompt || '') : '';

    if (!promptText) {
        showBottomSheet({
            bigInfo: {
                icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;"><path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.04.24.24.41.48.41h3.84c.24 0 .43-.17.47-.41l.36-2.54c.59-.24 1.13-.57 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"/></svg>',
                description: t('impersonation_prompt_missing') || 'Impersonation prompt is empty',
                buttonText: t('btn_configure') || 'Configure',
                onButtonClick: () => {
                    closeBottomSheet();
                    openApiView();
                }
            }
        });
        return;
    }

    inputValue.value = '';

    isImpersonating.value = true;
    isGenerating.value = true;
    const genId = nextGenerationId();
    setGenerationState(charId, { genId, controller, type: 'impersonation' });

    const history = buildGenerationHistory(currentMessages);

    notifyGenerationStarted({ charId, sessionId: char.sessionId, genId, type: 'impersonation' });

    return generateChat({
        text: promptText,
        char,
        history,
        guidanceText,
        type: 'impersonation',
        debugKey: `impersonation:${charId}:${char.sessionId || 'default'}:${genId}`,
        controller,
        callbacks: {
            onUpdate: (chunk) => { inputValue.value += chunk || ''; },
            onComplete: (response) => {
                inputValue.value = cleanText(response);
                isImpersonating.value = false;
                isGenerating.value = false;
                clearGenerationState(charId);
                notifyGenerationEnded({ charId, sessionId: char.sessionId, genId, type: 'impersonation' });
            },
            onError: (err) => {
                console.error(err);
                isImpersonating.value = false;
                isGenerating.value = false;
                clearGenerationState(charId);
                notifyGenerationEnded({ charId, sessionId: char.sessionId, genId, type: 'impersonation' });
            }
        }
    });
}
