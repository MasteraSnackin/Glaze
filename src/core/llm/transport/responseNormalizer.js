export function extractOpenAiMessage(data, contextLabel = 'API response structure') {
    if (!data || !data.choices || !data.choices.length || !data.choices[0] || !data.choices[0].message) {
        throw new Error(`Invalid ${contextLabel}: ${JSON.stringify(data)}`);
    }

    return {
        content: data.choices[0].message.content || '',
        reasoningContent: data.choices[0].message.reasoning_content || ''
    };
}

export function normalizeReasoningOutput({ content, requestReasoning, rawReasoning, hasInlineTags, tagStart, tagEnd, headerModel, headerInline }) {
    let finalText = content || '';
    let finalReasoning = requestReasoning ? (rawReasoning || '') : '';
    let inlineReasoning = '';

    if (hasInlineTags && content && content.includes(tagStart)) {
        const startIndex = content.indexOf(tagStart);
        const endIndex = content.indexOf(tagEnd, startIndex);
        if (endIndex !== -1) {
            inlineReasoning = content.substring(startIndex + tagStart.length, endIndex);
            finalText = content.substring(0, startIndex) + content.substring(endIndex + tagEnd.length);
        }
    }

    if (finalReasoning && inlineReasoning) {
        finalReasoning = `${headerModel}\n${finalReasoning}\n\n---\n\n${headerInline}\n${inlineReasoning}`;
    } else if (inlineReasoning) {
        finalReasoning = inlineReasoning;
    }

    return {
        text: finalText,
        reasoning: finalReasoning || null
    };
}
