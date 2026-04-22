export const builtInMemoryPrompts = [
    {
        key: 'detailed_beats',
        label: 'Detailed beats (recommended)',
        prompt: [
            'Analyze the following roleplay segment and create a comprehensive memory entry.',
            'Preserve the original language of the source segment. Do not translate it.',
            'Exclude all [OOC] (out-of-character) conversation — it is not useful for memory.',
            '',
            'Create a detailed beat-by-beat summary in narrative prose. Include:',
            '- Timeline: Date/time context if mentioned',
            '- Story Beats: All important plot events, decisions, and developments in order',
            '- Key Interactions: Significant character exchanges, dialogue highlights, and relationship developments',
            '- Notable Details: Important objects, settings, revelations, memorable quotes',
            '- Outcome: Results, resolutions, emotional states, and consequences for future continuity',
            '',
            'Capture all nuance without repeating verbatim. Use concrete nouns (e.g., "rice cooker" not "appliance").',
            'Write in past tense, third person. Focus on cause → intention → reaction → consequence.',
            '',
            'For keywords: generate 15-30 concrete, scene-specific retrieval tags:',
            '- Use proper nouns (locations: "Chinatown", "Ritz-Carlton bar")',
            '- Use specific objects ("CPAP machine", "chocolate chip cookies")',
            '- Use distinctive actions ("cookie baking", "piano apology")',
            '- Use unique phrases from the scene ("pack for forever", specific nicknames)',
            '- DO NOT use abstract themes ("intimacy", "trust", "vulnerability")',
            '- DO NOT use character names ({{char}}, {{user}})',
            '- DO NOT combine multiple concepts into one keyword',
            '',
            'Return plain text in this exact format:',
            'Memory: <detailed beat-by-beat summary following the structure above>',
            'Keys: <15-30 comma-separated concrete keywords as specified>',
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
