import {
    generateChatResponse
} from '@/core/services/generationService.js';
import { prepareChatPromptRequest, runPreparedChatPrompt } from '@/core/llm/usecases/chatPreparation.js';

/**
 * Official chat-generation use-case entrypoint.
 *
 * This is intentionally a thin wrapper for now so callers can stop depending
 * on `generationService.js` directly before the underlying orchestration is
 * extracted into dedicated pipeline steps.
 *
 * @param {Parameters<typeof generateChatResponse>[0]} input
 */
export async function generateChat(input) {
    return generateChatResponse(input);
}

/**
 * Executes the UI-owned chat generation lifecycle once the session context is
 * already resolved. This keeps Vue state in the view layer while moving the
 * request orchestration body behind the official use-case boundary.
 */
export async function executeChatGenerationUseCase({
    char,
    text,
    existingMsgIndex = -1,
    guidanceText = null,
    guidanceType = 'GENERATION',
    onAbort = null,
    resolvedContext,
    request,
    state,
    deps
}) {
    const { sessionId, summary, anContent } = resolvedContext;
    const { genId, controller, startTime, ownerKey, requestToken } = request;
    const {
        activeChatChar,
        isGenerating,
        currentMessages,
        displayMessages
    } = state;
    const {
        publishAppEvent,
        APP_EVENTS,
        buildGenerationAuthorsNote,
        getEffectivePreset,
        ensureGenerationPlaceholderMessage,
        createBaseMessageMeta,
        genMsgId,
        getChatData,
        db,
        scrollToBottom,
        applyGenerationGuidanceState,
        createPromptMetadataSnapshots,
        markGenerationPersisted,
        setupGenerationState,
        setGenerationState,
        getGenerationState,
        smartScroll,
        createGenerationStreamUpdater,
        isGenerationStateCurrent,
        restoreGenerationState,
        clearPersistedGeneration,
        updateSessionMessage,
        handleGenerationError,
        clearGenerationState,
        clearTypingStateForMessage,
        formatError,
        sendMessageNotification,
        buildGenerationHistory,
        handleGenerationPromptReady,
        handleGenerationComplete,
        cleanText,
        estimateTokens,
        processMessageImages,
        userAvatar,
        isItemVisible,
        scrollToIndex,
        runMemoryAutomationAfterStableTurn,
        addMessageStats,
        addRegenerationStats,
        triggerAutoSyncCheck
    } = deps;

    publishAppEvent(APP_EVENTS.domain.generation.started, { charId: char.id, sessionId });

    isGenerating.value = true;
    let msgIndex = existingMsgIndex;
    const authorsNote = buildGenerationAuthorsNote({
        getEffectivePreset,
        charId: char.id,
        sessionId,
        anContent
    });

    msgIndex = await ensureGenerationPlaceholderMessage({
        msgIndex,
        text,
        guidanceText,
        guidanceType,
        currentMessages,
        createBaseMessageMeta,
        genMsgId,
        charId: char.id,
        sessionId,
        getChatData,
        db,
        scrollToBottom
    });

    applyGenerationGuidanceState({
        currentMessages,
        msgIndex,
        guidanceText,
        guidanceType
    });

    const msgId = currentMessages.value[msgIndex]?.id || genMsgId();
    const { snapshotPromptMeta, restorePromptMetaOnMessages } = createPromptMetadataSnapshots();

    markGenerationPersisted(char.id, sessionId);

    setupGenerationState({
        char,
        sessionId,
        msgId,
        genId,
        ownerKey,
        requestToken,
        controller,
        startTime,
        currentMessages,
        activeChatChar,
        setGenerationState,
        getGenerationState,
        smartScroll
    });

    const { onUpdate, clearBackgroundUpdateTimer } = createGenerationStreamUpdater({
        char,
        sessionId,
        msgId,
        genId,
        getGenerationState,
        isGenerationStateCurrent,
        getChatData,
        db,
        onRawText: (effectiveText, chunk) => {
            request.rawStreamRef.value = effectiveText || (request.rawStreamRef.value + (chunk || ''));
        }
    });

    const restoreState = async (isError = false) => {
        await restoreGenerationState({
            currentMessages,
            getChatData,
            db,
            getGenerationState,
            clearPersistedGeneration,
            char,
            sessionId,
            msgId,
            isError,
            onAbort,
            restorePromptMetaOnMessages,
            clearBackgroundUpdateTimer,
            updateSessionMessage
        });
    };

    getGenerationState(char.id).restoreState = restoreState;

    const onError = async (error) => {
        await handleGenerationError({
            error,
            char,
            sessionId,
            msgId,
            genId,
            requestToken,
            rawStreamText: request.rawStreamRef.value,
            activeChatChar,
            isGenerating,
            currentMessages,
            getGenerationState,
            isGenerationStateCurrent,
            clearGenerationState,
            restoreState,
            clearBackgroundUpdateTimer,
            clearTypingStateForMessage,
            getChatData,
            db,
            formatError,
            sendMessageNotification
        });
    };

    const history = buildGenerationHistory(currentMessages);

    return generateChatResponse({
        text,
        char,
        history,
        authorsNote,
        summary,
        guidanceText,
        type: 'normal',
        controller,
        callbacks: {
            onPromptReady: async ({ loreEntries, memoryEntries }) => {
                await handleGenerationPromptReady({
                    loreEntries,
                    memoryEntries,
                    currentMessages,
                    msgIndex,
                    char,
                    sessionId,
                    getChatData,
                    db,
                    snapshotPromptMeta
                });
            },
            onUpdate,
            onComplete: async (response, finalReasoning, meta) => {
                await handleGenerationComplete({
                    response,
                    finalReasoning,
                    meta,
                    char,
                    sessionId,
                    msgId,
                    genId,
                    requestToken,
                    startTime,
                    controller,
                    guidanceText,
                    guidanceType,
                    activeChatChar,
                    isGenerating,
                    currentMessages,
                    displayMessages,
                    getGenerationState,
                    isGenerationStateCurrent,
                    clearGenerationState,
                    clearPersistedGeneration,
                    clearBackgroundUpdateTimer,
                    clearTypingStateForMessage,
                    getChatData,
                    db,
                    cleanText,
                    estimateTokens,
                    updateSessionMessage,
                    processMessageImages,
                    userAvatar,
                    isItemVisible,
                    scrollToIndex,
                    smartScroll,
                    sendMessageNotification,
                    runMemoryAutomationAfterStableTurn,
                    addMessageStats,
                    addRegenerationStats,
                    triggerAutoSyncCheck
                });
            },
            onError
        }
    });
}
