export const builtInMemoryPrompts = [
    {
        key: 'detailed_beats',
        label: 'Detailed beats (recommended)',
        prompt: [
            'Analyze the following roleplay segment and create a structured memory entry.',
            'Preserve the original language. Exclude casual [OOC] conversation, BUT if OOC messages contain story rules, formatting instructions, backstory clarifications, or scene-setting directives, reflect those instructions in the memory entry under the relevant sections.',
            '',
            'Use this markdown structure (skip sections if not applicable):',
            'Timeline: Always label as "Day N" (Day 1, Day 2, Day 3, etc.) — increment the day counter each time a new in-story day begins. Write clock times HH:MM; If the scene spans multiple days, write "Day N–M HH:MM-HH:MM".',
            'Story Beats: Important plot events and developments',
            'Key Interactions: Significant character exchanges and relationship shifts',
            'Notable Details: Important objects, settings, revelations, quotes',
            'OOC Rules & Directives: Any player-established rules, formatting requirements, backstory additions, or scene-setting instructions given through OOC',
            'Outcome: Results, emotional states, consequences',
            '',
            'Write in past tense, third person. Be comprehensive but avoid verbatim repetition.',
            '',
            'For keywords: generate 15-25 concrete scene-specific tags:',
            '- Proper nouns, locations, specific objects, unique actions',
            '- NOT abstract concepts, emotions, or character names',
            '',
            'Return plain text in this exact format:',
            'Memory: <structured markdown summary following the template above>',
            'Keys: <15-25 comma-separated concrete keywords>',
            '',
            '{{history}}'
        ].join('\n')
    },
    {
        key: 'concise_narrative',
        label: 'Concise narrative',
        prompt: [
            'Analyze the following roleplay segment and create a concise memory entry.',
            'Preserve the original language. Do not translate. Exclude all [OOC] conversation.',
            '',
            'Write a compact 3-5 sentence narrative summary in past tense, third person.',
            'Focus on:',
            '- What happened (main events and decisions)',
            '- Key character interactions or developments',
            '- Important outcome or state change',
            '',
            'For keywords: provide 10-20 concrete, scene-specific keywords:',
            '- Locations, objects, proper nouns, unique actions',
            '- NOT abstract themes, emotions, or character names',
            '',
            'Return plain text in this exact format:',
            'Memory: <3-5 sentence concise narrative summary>',
            'Keys: <10-20 comma-separated concrete keywords>',
            '',
            '{{history}}'
        ].join('\n')
    },
    {
        key: 'structured_markdown',
        label: 'Structured (markdown)',
        prompt: [
            'Analyze the following roleplay segment and create a structured memory entry.',
            'Preserve the original language. Exclude all [OOC] conversation.',
            '',
            'Use this markdown structure (skip sections if not applicable):',
            '**Timeline**: Day/time this scene covers',
            '**Story Beats**: Important plot events and developments',
            '**Key Interactions**: Significant character exchanges and relationship shifts',
            '**Notable Details**: Important objects, settings, revelations, quotes',
            '**Outcome**: Results, emotional states, consequences',
            '',
            'Write in past tense, third person. Be comprehensive but avoid verbatim repetition.',
            '',
            'For keywords: generate 15-25 concrete scene-specific tags:',
            '- Proper nouns, locations, specific objects, unique actions',
            '- NOT abstract concepts, emotions, or character names',
            '',
            'Return plain text in this exact format:',
            'Memory: <structured markdown summary following the template above>',
            'Keys: <15-25 comma-separated concrete keywords>',
            '',
            '{{history}}'
        ].join('\n')
    },
    {
        key: 'minimal_factual',
        label: 'Minimal (1-2 sentences)',
        prompt: [
            'Create a minimal memory entry from the following roleplay segment.',
            'Preserve the original language. Exclude [OOC] conversation.',
            '',
            'Write 1-2 sentences capturing only the most important factual development.',
            'Focus on durable outcomes: status changes, revealed facts, decisions, or relationship shifts.',
            '',
            'For keywords: provide 5-10 most relevant concrete keywords (locations, objects, proper nouns).',
            'Do not use abstract themes or character names.',
            '',
            'Return plain text in this exact format:',
            'Memory: <1-2 sentence factual summary>',
            'Keys: <5-10 comma-separated concrete keywords>',
            '',
            '{{history}}'
        ].join('\n')
    }
];

export function getMemoryPromptOptions(settings = {}) {
    const custom = Array.isArray(settings.customPrompts) ? settings.customPrompts : [];
    return [
        ...builtInMemoryPrompts,
        ...custom.map(item => ({ key: item.id, label: item.name || 'Custom prompt', prompt: item.prompt || '' }))
    ];
}

export function resolveMemoryPrompt(settings = {}) {
    const options = getMemoryPromptOptions(settings);
    const selected = options.find(item => item.key === settings.promptPreset);
    return selected?.prompt || builtInMemoryPrompts[0].prompt;
}

export function getMemoryPromptLabel(settings = {}) {
    const options = getMemoryPromptOptions(settings);
    return options.find(item => item.key === settings.promptPreset)?.label || builtInMemoryPrompts[0].label;
}

export function getMemoryPromptLabelByKey(settings = {}, promptPreset = 'detailed_beats') {
    const options = getMemoryPromptOptions(settings);
    return options.find(item => item.key === promptPreset)?.label || builtInMemoryPrompts[0].label;
}

export function getNormalizedMemoryGenerationState(settings = {}, overrides = {}) {
    const source = settings.generationSource === 'custom' ? 'custom' : 'llm';
    return {
        source,
        model: settings.generationModel || '',
        endpoint: settings.generationEndpoint || '',
        apiKey: settings.generationApiKey || '',
        temperature: settings.generationTemperature,
        maxTokens: Number.isFinite(Number(settings.generationMaxTokens)) && Number(settings.generationMaxTokens) > 0
            ? Math.round(Number(settings.generationMaxTokens))
            : null,
        autoCreateEnabled: settings.autoCreateEnabled !== false,
        autoGenerateEnabled: settings.autoGenerateEnabled === true,
        promptPreset: getMemoryPromptOptions(settings).some(p => p.key === settings.promptPreset) ? settings.promptPreset : 'detailed_beats',
        autoCreateInterval: Number.isFinite(Number(settings.autoCreateInterval)) && Number(settings.autoCreateInterval) > 0
            ? Number(settings.autoCreateInterval)
            : 15,
        batchSize: Number.isFinite(Number(settings.batchSize)) && Number(settings.batchSize) > 0
            ? Number(settings.batchSize)
            : 3,
        useDelayedAutomation: settings.useDelayedAutomation !== false,
        maxInjectedEntries: Number.isFinite(Number(settings.maxInjectedEntries)) && Number(settings.maxInjectedEntries) > 0
            ? Number(settings.maxInjectedEntries)
            : 7,
        injectionTarget: settings.injectionTarget === 'summary_macro' ? 'summary_macro' : 'summary_block',
        ...overrides
    };
}
