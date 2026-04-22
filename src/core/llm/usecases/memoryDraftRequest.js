export async function executeMemoryDraftRequest({
    history,
    prompt,
    controller,
    apiConfigOverride = null,
    deps
}) {
    const {
        getEffectiveApiConfig,
        buildMemoryDraftRequestPayload,
        executeRequest,
        setLastPrompt
    } = deps;

    const effectiveConfig = {
        ...getEffectiveApiConfig(),
        ...(apiConfigOverride || {})
    };
    const { providerId, apiKey, apiUrl, model, temp } = effectiveConfig;

    const explicitOverrideMaxTokens = Number(apiConfigOverride?.maxTokens);
    const hasExplicitOverride = Number.isFinite(explicitOverrideMaxTokens) && explicitOverrideMaxTokens > 0;
    const configuredMaxTokens = Number(effectiveConfig.maxTokens);
    const memoryDraftMaxTokens = hasExplicitOverride
        ? Math.max(200, Math.round(explicitOverrideMaxTokens))
        : (Number.isFinite(configuredMaxTokens) && configuredMaxTokens > 0
            ? Math.max(1200, Math.round(configuredMaxTokens))
            : 2000);

    if (!apiUrl || !model) {
        throw new Error('API Not Configured');
    }

    const defaultPrompt = [
        'Create exactly one concise long-term memory entry from the following roleplay segment.',
        'Preserve the original language of the source segment. Do not translate it.',
        'Use only facts that are explicitly supported by the segment.',
        'Do not infer completed outcomes, registrations, approvals, or decisions unless the text clearly states them.',
        'Focus on durable facts, developments, or relationship changes that should persist beyond immediate context.',
        'Do not copy the dialogue verbatim.',
        'Return only the memory entry text with no preface, label, or explanation.',
        '',
        '{{history}}'
    ].join('\n');
    const template = prompt || defaultPrompt;

    let finalPrompt = template.replace('{{history}}', history);
    if (!template.includes('{{history}}')) {
        finalPrompt = `${template}\n\n${history}`;
    }

    let result = '';
    let requestError = null;
    const { previewBody, requestBody } = buildMemoryDraftRequestPayload({
        providerId,
        model,
        prompt: finalPrompt,
        temperature: temp,
        maxTokens: memoryDraftMaxTokens
    });

    setLastPrompt(JSON.parse(JSON.stringify(previewBody)));

    await executeRequest({
        providerId,
        apiUrl,
        apiKey,
        requestBody,
        stream: false,
        controller,
        requestType: 'memory_draft',
        callbacks: {
            onUpdate: (chunk, reasoningChunk, effectiveText) => {
                if (effectiveText) result = effectiveText;
                else if (chunk) result += chunk;
            },
            onComplete: (text) => { if (text) result = text; },
            onError: (err) => { requestError = err; }
        }
    });

    if (requestError) throw requestError;

    return result;
}
