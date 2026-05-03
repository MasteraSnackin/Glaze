import {
    generateChatResponse
} from '@/core/services/generationService.js';
import { runGenerationHook } from '@/core/extensions/extensionRegistry.js';

export { createChatGenerationServices } from '@/core/llm/usecases/chatGenerationServiceFactory.js';

export async function generateChat(input) {
    return generateChatResponse(input);
}

export async function executeChatGenerationUseCase({
    char,
    text,
    existingMsgIndex = -1,
    guidanceText = null,
    guidanceType = 'GENERATION',
    onAbort = null,
    resolvedContext,
    request,
    services
}) {
    const { sessionId, summary, anContent } = resolvedContext;
    const { genId, controller, startTime, ownerKey, requestToken } = request;
    const {
        state,
        app,
        preparation,
        lifecycle,
        effects,
        postprocess
    } = services;
    const {
        activeChatChar,
        isGenerating,
        currentMessages,
        displayMessages
    } = state;
    const {
        notifyGenerationStarted,
        notifyGenerationEnded,
        notifyChatUpdated
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

    notifyGenerationStarted({ charId: char.id, sessionId, genId, type: 'chat' });

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

    const currentMessagesVal = currentMessages.value || currentMessages;
    const msgId = currentMessagesVal[msgIndex]?.id || genMessageId();
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
        persistence,
        onRawText: (effectiveText, chunk) => {
            request.rawStreamRef.value = effectiveText || (request.rawStreamRef.value + (chunk || ''));
        }
    });

    const restoreState = async (isError = false) => {
        await restoreGenerationState({
            currentMessages,
            persistence,
            getGenerationState,
            clearPersistedGeneration,
            char,
            sessionId,
            msgId,
            isError,
            expectedGenId: genId,
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
            clearPersistedGeneration,
            restoreState,
            clearBackgroundUpdateTimer,
            clearTypingStateForMessage,
            persistence,
            app: {
                notifyGenerationEnded
            },
            formatError,
            sendMessageNotification
        });
    };

    const history = buildGenerationHistory(currentMessages);
    const debugKey = `chat:${char.id}:${sessionId}:${genId}`;

    return generateChatResponse({
        text,
        char,
        history,
        authorsNote,
        summary,
        guidanceText,
        type: 'normal',
        debugKey,
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
                    persistence,
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
                    persistence,
                    app: {
                        notifyGenerationEnded,
                        notifyChatUpdated
                    },
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

                await runGenerationHook('afterGenerationCommit', {
                    requestType: 'chat',
                    debugKey,
                    char,
                    charId: char.id,
                    sessionId,
                    msgId,
                    genId,
                    response,
                    finalReasoning,
                    meta,
                    guidanceText,
                    guidanceType
                });
            },
            onError
        }
    });
}
