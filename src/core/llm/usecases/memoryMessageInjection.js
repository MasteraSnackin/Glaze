function injectMemoryIntoSummaryMacro(messages, memoryInjection) {
    if (!memoryInjection?.macroContent) return messages;

    const summaryIndex = messages.findIndex(msg => Array.isArray(msg?.sources) && msg.sources.some(source => source?.source === 'summary'));
    if (summaryIndex === -1) return null;

    const summaryMessage = messages[summaryIndex];
    const existingContent = String(summaryMessage?.content || '').trim();
    const appendedContent = existingContent
        ? `${existingContent}\n\n${memoryInjection.macroContent}`
        : memoryInjection.macroContent;

    const nextSources = Array.isArray(summaryMessage?.sources) ? [...summaryMessage.sources] : [];
    const memorySource = nextSources.find(source => source?.source === 'memory');
    if (memorySource) memorySource.tokens += memoryInjection.tokens || 0;
    else if ((memoryInjection.tokens || 0) > 0) nextSources.push({ source: 'memory', tokens: memoryInjection.tokens || 0 });

    const nextAllSources = Array.isArray(summaryMessage?._allSources) ? [...summaryMessage._allSources] : [];
    if ((memoryInjection.tokens || 0) > 0) nextAllSources.push({ source: 'memory', tokens: memoryInjection.tokens || 0 });

    return [
        ...messages.slice(0, summaryIndex),
        {
            ...summaryMessage,
            content: appendedContent,
            sources: nextSources,
            _allSources: nextAllSources
        },
        ...messages.slice(summaryIndex + 1)
    ];
}

export function injectMemoryMessages(messages, memoryInjection, settings = {}) {
    if (!memoryInjection?.messages?.length) return messages;

    const injectionTarget = settings.injectionTarget === 'summary_macro' ? 'summary_macro' : 'summary_block';
    if (injectionTarget === 'summary_macro') {
        const macroInjected = injectMemoryIntoSummaryMacro(messages, memoryInjection);
        if (macroInjected) {
            return macroInjected;
        }
    }

    const firstHistoryIndex = messages.findIndex(m => m.isHistory);
    if (firstHistoryIndex === -1) {
        return [...messages, ...memoryInjection.messages];
    }
    return [
        ...messages.slice(0, firstHistoryIndex),
        ...memoryInjection.messages,
        ...messages.slice(firstHistoryIndex)
    ];
}
