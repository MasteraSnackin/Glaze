import {
    generateChatResponse
} from '@/core/services/generationService.js';

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
    services
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
        app,
        preparation,
        lifecycle,
        effects,
        postprocess
    } = services;
    const {
        notifyGenerationStarted
    } = app;
    const {
        buildAuthorsNote,
        ensurePlaceholderMessage,
        genMessageId,
        applyGenerationGuidanceState,
        createPromptMetadataSnapshots,
        buildGenerationHistory,
        updateSessionMessage
    } = preparation;
    const {
        markGenerationPersisted,
        setupGenerationState,
        setGenerationState,
        getGenerationState,
        createGenerationStreamUpdater,
        isGenerationStateCurrent,
        restoreGenerationState,
        clearPersistedGeneration,
        handleGenerationError,
        clearGenerationState,
        clearTypingStateForMessage,
        handleGenerationPromptReady,
        handleGenerationComplete,
        persistence
    } = lifecycle;
    const {
        getChatData,
        db
    } = persistence;
    const {
        smartScroll,
        formatError,
        sendMessageNotification,
        userAvatar,
        isItemVisible,
        scrollToIndex
    } = effects;
    const {
        cleanText,
        estimateTokens,
        processMessageImages,
        runMemoryAutomationAfterStableTurn,
        addMessageStats,
        addRegenerationStats,
        triggerAutoSyncCheck
    } = postprocess;

    notifyGenerationStarted({ charId: char.id, sessionId });

    isGenerating.value = true;
    let msgIndex = existingMsgIndex;
    const authorsNote = buildAuthorsNote({ charId: char.id, sessionId, anContent });

    msgIndex = await ensurePlaceholderMessage({
        msgIndex,
        text,
        guidanceText,
        guidanceType,
        charId: char.id,
        sessionId
    });

    applyGenerationGuidanceState({
        currentMessages,
        msgIndex,
        guidanceText,
        guidanceType
    });

    const msgId = currentMessages.value[msgIndex]?.id || genMessageId();
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
            rawStreamText: request.rawStreamRef.value,
            activeChatChar,
            isGenerating,
            currentMessages,
            getGenerationState,
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
                    startTime,
                    controller,
                    guidanceText,
                    guidanceType,
                    activeChatChar,
                    isGenerating,
                    currentMessages,
                    displayMessages,
                    getGenerationState,
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
