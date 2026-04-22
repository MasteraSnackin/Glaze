import { getEffectivePreset } from '@/core/states/presetState.js';
import { getChatData } from '@/utils/sessions.js';
import { db } from '@/utils/db.js';
import { createBaseMessageMeta } from '@/core/services/memoryBooksService.js';
import { estimateTokens } from '@/utils/tokenizer.js';
import { cleanText } from '@/utils/textFormatter.js';
import { formatError } from '@/utils/errors.js';
import { processMessageImages } from '@/core/services/imageGenService.js';
import { sendMessageNotification } from '@/core/services/notificationService.js';
import { addMessageStats, addRegenerationStats } from '@/core/services/statsService.js';
import { triggerAutoSyncCheck } from '@/composables/chat/useAutoSync.js';
import { useGenerationRegistry } from '@/composables/chat/useGenerationRegistry.js';
import { useTypingStateCleanup } from '@/composables/chat/useTypingStateCleanup.js';
import { handleGenerationComplete } from '@/composables/chat/useGenerationCompleteHandler.js';
import { handleGenerationError } from '@/composables/chat/useGenerationErrorHandler.js';
import { handleGenerationPromptReady } from '@/composables/chat/useGenerationPromptReady.js';
import { applyGenerationGuidanceState, setupGenerationState } from '@/composables/chat/useGenerationStateSetup.js';
import { createGenerationStreamUpdater } from '@/composables/chat/useGenerationStreamUpdate.js';
import { restoreGenerationState } from '@/composables/chat/useGenerationStateRestore.js';
import { createPromptMetadataSnapshots } from '@/composables/chat/usePromptMetadataSnapshots.js';
import {
    buildGenerationAuthorsNote,
    ensureGenerationPlaceholderMessage,
    buildGenerationHistory
} from '@/composables/chat/useGenerationPreparation.js';
import { createGenerationAppAdapters } from '@/core/llm/usecases/chatGenerationAppAdapters.js';

export function createChatGenerationServices({
    activeChatChar,
    isGenerating,
    currentMessages,
    displayMessages,
    smartScroll,
    scrollToBottom,
    isItemVisible,
    scrollToIndex,
    genMsgId,
    updateSessionMessage,
    runMemoryAutomationAfterStableTurn
}) {
    const registry = useGenerationRegistry();
    const { clearTypingStateForMessage } = useTypingStateCleanup({ currentMessages, getChatData, db });
    const app = createGenerationAppAdapters();
    const persistence = { getChatData, db };

    return {
        state: {
            activeChatChar,
            isGenerating,
            currentMessages,
            displayMessages
        },
        app,
        registry,
        preparation: {
            buildAuthorsNote: ({ charId, sessionId, anContent }) => buildGenerationAuthorsNote({
                getEffectivePreset,
                charId,
                sessionId,
                anContent
            }),
            ensurePlaceholderMessage: ({ msgIndex, text, guidanceText, guidanceType, charId, sessionId }) => ensureGenerationPlaceholderMessage({
                msgIndex,
                text,
                guidanceText,
                guidanceType,
                currentMessages,
                createBaseMessageMeta,
                genMsgId,
                charId,
                sessionId,
                getChatData,
                db,
                scrollToBottom
            }),
            genMessageId: genMsgId,
            applyGenerationGuidanceState,
            createPromptMetadataSnapshots,
            buildGenerationHistory,
            updateSessionMessage
        },
        lifecycle: {
            markGenerationPersisted: registry.markGenerationPersisted,
            setupGenerationState,
            setGenerationState: registry.setGenerationState,
            getGenerationState: registry.getGenerationState,
            createGenerationStreamUpdater,
            isGenerationStateCurrent: registry.isGenerationStateCurrent,
            restoreGenerationState,
            clearPersistedGeneration: registry.clearPersistedGeneration,
            handleGenerationError,
            clearGenerationState: registry.clearGenerationState,
            clearTypingStateForMessage,
            handleGenerationPromptReady,
            handleGenerationComplete,
            persistence
        },
        effects: {
            smartScroll,
            formatError,
            sendMessageNotification,
            get userAvatar() { return activeChatChar.value?.avatar || null; },
            isItemVisible,
            scrollToIndex
        },
        postprocess: {
            cleanText,
            estimateTokens,
            processMessageImages,
            runMemoryAutomationAfterStableTurn,
            addMessageStats,
            addRegenerationStats,
            triggerAutoSyncCheck
        }
    };
}
