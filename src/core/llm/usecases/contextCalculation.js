export async function executeChatContextCalculation({
    char,
    history,
    authorsNote,
    summary,
    deps
}) {
    const {
        getEffectiveApiConfig,
        loadActivePreset,
        getPromptWorkerOptions,
        loadSessionVars,
        loadGlobalRegexes,
        getSafeContextLimit,
        trimHistoryForContextWindow,
        getMemoryReserveEstimate,
        buildPromptWorkerPayload,
        processPromptAsync,
        buildPromptMemoryInjection,
        vectorSearchLorebooks,
        mergeLateVectorLoreEntries,
        estimateVectorLoreTokens,
        buildContextCalculationResult
    } = deps;

    const apiConfig = getEffectiveApiConfig();
    const activePreset = loadActivePreset(char, char?.sessionId);
    const promptOptions = getPromptWorkerOptions(char, activePreset);
    const { sessionVars } = loadSessionVars(char);
    const globalRegexes = loadGlobalRegexes();

    try {
        const safeContextLimit = getSafeContextLimit(apiConfig.contextSize, apiConfig.maxTokens);
        const safeHistory = trimHistoryForContextWindow(history, safeContextLimit);

        const memoryReserve = await getMemoryReserveEstimate(char, safeContextLimit);

        const payload = buildPromptWorkerPayload({
            char,
            history: safeHistory,
            summary,
            activePreset,
            promptOptions,
            authorsNote,
            globalRegexes,
            sessionVars,
            apiConfig,
            memoryReserve
        });

        const result = await processPromptAsync(payload);
        const memoryInjection = await buildPromptMemoryInjection({
            char,
            history: safeHistory,
            summary,
            safeContext: safeContextLimit,
            result
        });

        let vectorLoreTokens = 0;
        try {
            const vectorResults = await vectorSearchLorebooks(safeHistory || history, '', char, char?.sessionId);
            if (vectorResults.length > 0) {
                const { vectorEntries } = mergeLateVectorLoreEntries(result, vectorResults);
                vectorLoreTokens = estimateVectorLoreTokens(vectorEntries);
            }
        } catch (e) {
            console.warn('[calculateContext] Vector search failed:', e);
        }

        return buildContextCalculationResult(result, {
            vectorLoreTokens,
            memoryTokens: memoryInjection.tokens || 0,
            memoryReserve
        });
    } catch (e) {
        console.error('Calculate context worker error', e);
        return {
            cutoffIndex: 0,
            contextBreakdown: null
        };
    }
}
