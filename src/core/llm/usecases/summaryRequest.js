export async function executeSummaryRequest({
    history,
    prompt,
    controller,
    apiConfigOverride = null,
    deps
}) {
    const {
        getEffectiveApiConfig,
        buildSummaryRequestPayload,
        executeRequest
    } = deps;

    const effectiveConfig = {
        ...getEffectiveApiConfig(),
        ...(apiConfigOverride || {})
    };
    const { providerId, apiKey, apiUrl, model, temp } = effectiveConfig;

    if (!apiUrl || !model) {
        throw new Error('API Not Configured');
    }

    const defaultPrompt = 'Summarize the following roleplay conversation concisely, focusing on the current situation and key events:\n\n{{history}}';
    const template = prompt || defaultPrompt;

    let finalPrompt = template.replace('{{history}}', history);
    if (!template.includes('{{history}}')) {
        finalPrompt = `${template}\n\n${history}`;
    }

    let result = '';

    const { requestBody } = buildSummaryRequestPayload({
        providerId,
        model,
        prompt: finalPrompt,
        temperature: temp
    });

    await executeRequest({
        providerId,
        apiUrl,
        apiKey,
        requestBody,
        controller,
        callbacks: {
            onComplete: (text) => { result = text; }
        }
    });

    return result;
}
