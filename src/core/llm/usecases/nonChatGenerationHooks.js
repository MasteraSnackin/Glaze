import { runGenerationHook } from '@/core/extensions/extensionRegistry.js';

export async function runNonChatPromptBuildHooks({
    requestType,
    debugKey,
    history,
    prompt,
    apiConfigOverride,
    effectiveConfig,
    template,
    finalPrompt,
    extra = {}
}) {
    await runGenerationHook('beforePromptBuild', {
        requestType,
        debugKey,
        history,
        prompt,
        apiConfigOverride,
        effectiveConfig,
        template,
        finalPrompt,
        ...extra
    });

    return runGenerationHook('afterPromptBuild', {
        requestType,
        debugKey,
        history,
        prompt,
        apiConfigOverride,
        effectiveConfig,
        template,
        finalPrompt,
        ...extra
    });
}

export async function runNonChatRequestHooks({
    requestType,
    debugKey,
    providerId,
    apiUrl,
    apiKey,
    model,
    buildPayload,
    payloadInput,
    controller,
    stream = false,
    extra = {}
}) {
    const requestAssembly = await runGenerationHook('beforeRequestAssembly', {
        requestType,
        debugKey,
        providerId,
        apiUrl,
        apiKey,
        model,
        payloadInput,
        controller,
        stream,
        ...extra
    });

    const {
        providerId: assembledProviderId = providerId,
        apiUrl: assembledApiUrl = apiUrl,
        apiKey: assembledApiKey = apiKey,
        model: assembledModel = model,
        payloadInput: assembledPayloadInput = payloadInput,
        controller: assembledController = controller,
        stream: assembledStream = stream,
        ...assembledExtra
    } = requestAssembly || {};

    let { previewBody: assembledPreviewBody, requestBody: assembledRequestBody } = buildPayload({
        ...assembledPayloadInput,
        providerId: assembledProviderId,
        model: assembledModel
    });

    const requestEnvelope = await runGenerationHook('beforeRequestSend', {
        requestType,
        debugKey,
        providerId: assembledProviderId,
        apiUrl: assembledApiUrl,
        apiKey: assembledApiKey,
        model: assembledModel,
        previewBody: assembledPreviewBody,
        requestBody: assembledRequestBody,
        payloadInput: assembledPayloadInput,
        controller: assembledController,
        stream: assembledStream,
        ...extra,
        ...assembledExtra
    });

    return {
        providerId: assembledProviderId,
        apiUrl: assembledApiUrl,
        apiKey: assembledApiKey,
        model: assembledModel,
        previewBody: assembledPreviewBody,
        requestBody: assembledRequestBody,
        controller: assembledController,
        stream: assembledStream,
        ...(requestEnvelope || {})
    };
}

export async function runNonChatCommitHook({
    requestType,
    debugKey,
    result,
    extra = {}
}) {
    await runGenerationHook('afterGenerationCommit', {
        requestType,
        debugKey,
        result,
        ...extra
    });
}
