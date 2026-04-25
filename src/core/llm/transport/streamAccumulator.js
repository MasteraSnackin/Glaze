function decodeHtmlEntities(text) {
    return text
        .replace(/&amp;/g, '&')
        .replace(/&gt;/g, '>')
        .replace(/&lt;/g, '<')
        .replace(/&quot;/g, '"')
        .replace(/&apos;/g, "'");
}

function extractInlineReasoning(rawText, tagStart, tagEnd, hasInlineTags) {
    if (!hasInlineTags || !rawText.includes(tagStart)) {
        return { text: rawText, inlineReasoning: '' };
    }

    const startIndex = rawText.indexOf(tagStart);
    const endIndex = rawText.indexOf(tagEnd, startIndex);

    if (endIndex !== -1) {
        return {
            text: rawText.substring(0, startIndex) + rawText.substring(endIndex + tagEnd.length),
            inlineReasoning: rawText.substring(startIndex + tagStart.length, endIndex)
        };
    }

    return {
        text: rawText.substring(0, startIndex),
        inlineReasoning: rawText.substring(startIndex + tagStart.length)
    };
}

function combineReasoningSections(modelReasoning, inlineReasoning, headerModel, headerInline) {
    if (modelReasoning && inlineReasoning) {
        return `${headerModel}\n${modelReasoning}\n\n---\n\n${headerInline}\n${inlineReasoning}`;
    }

    return inlineReasoning || modelReasoning;
}

export function createStreamAccumulator({
    tagStart,
    tagEnd,
    hasInlineTags,
    headerModel,
    headerInline
}) {
    let fullText = '';
    let rawAccumulated = '';
    let accumulatedReasoning = '';
    let previousEffectiveText = '';
    let latestEffectiveReasoning = null;

    return {
        consumeDelta({ content = '', reasoning = '' }) {
            fullText += content;
            rawAccumulated += content;
            if (reasoning) accumulatedReasoning += reasoning;

            const extracted = extractInlineReasoning(rawAccumulated, tagStart, tagEnd, hasInlineTags);
            let effectiveText = decodeHtmlEntities(extracted.text.replace(/^\s+/, ''));
            const effectiveReasoning = combineReasoningSections(
                accumulatedReasoning,
                extracted.inlineReasoning,
                headerModel,
                headerInline
            );

            // Buffer text ending in an incomplete HTML entity, flush it in the next delta.
            const incompleteEntity = effectiveText.match(/&[a-zA-Z0-9#]*$/);
            if (incompleteEntity) {
                effectiveText = effectiveText.substring(0, incompleteEntity.index);
            }

            let textDelta = null;
            if (effectiveText.startsWith(previousEffectiveText)) {
                textDelta = effectiveText.substring(previousEffectiveText.length);
            }
            previousEffectiveText = effectiveText;
            latestEffectiveReasoning = effectiveReasoning || null;

            return {
                effectiveText,
                effectiveReasoning,
                textDelta
            };
        },

        finalize() {
            const extracted = extractInlineReasoning(fullText, tagStart, tagEnd, hasInlineTags);
            const finalReasoning = combineReasoningSections(
                accumulatedReasoning,
                extracted.inlineReasoning,
                headerModel,
                headerInline
            ) || null;
            const allReasoning = !extracted.text.trim() && !!accumulatedReasoning.trim();
            return {
                text: extracted.text,
                reasoning: finalReasoning,
                allReasoning
            };
        },

        getPartial() {
            return {
                text: previousEffectiveText || fullText,
                reasoning: latestEffectiveReasoning ?? (accumulatedReasoning || null)
            };
        }
    };
}
