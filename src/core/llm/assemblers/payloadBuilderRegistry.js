import { REQUEST_KINDS } from '@/core/llm/contracts/providerContracts.js';

function stripEmbeddedMedia(text) {
    if (!text || text.length < 256) return text;
    let cleaned = text.replace(/<img\s[^>]*src\s*=\s*["']data:image\/[^"']{256,}["'][^>]*\/?>/gi, '');
    cleaned = cleaned.replace(/data:image\/[a-z+]+;base64,[A-Za-z0-9+/=\n\r]{256,}/gi, '');
    return cleaned;
}

function sanitizeChatMessages(messages = []) {
    return messages.map(message => {
        const cleanMsg = {
            role: message.role,
            content: stripEmbeddedMedia(message.content)
        };

        if (message.image) {
            cleanMsg.content = [
                { type: 'text', text: message.content || '' },
                { type: 'image_url', image_url: { url: message.image } }
            ];
        }

        if (message.name) cleanMsg.name = message.name;
        return cleanMsg;
    });
}

function buildOpenAiCompatiblePayload(intent) {
    switch (intent.kind) {
        case REQUEST_KINDS.CHAT: {
            const previewBody = {
                model: intent.model,
                messages: intent.messages,
                stream: intent.stream
            };

            if (!intent.omitTemperature) {
                previewBody.temperature = intent.temperature;
            }

            if (!intent.omitTopP) {
                previewBody.top_p = intent.topP;
            }

            const shouldSendReasoning = !intent.omitReasoning && intent.requestReasoning;
            if (shouldSendReasoning && !intent.omitReasoningEffort && intent.reasoningEffort && intent.reasoningEffort !== 'auto') {
                previewBody.reasoning_effort = intent.reasoningEffort;
            }

            if (intent.maxTokens > 0) {
                previewBody.max_tokens = intent.maxTokens;
            }

            if (intent.stopString) {
                previewBody.stop = [intent.stopString];
            }

            return {
                previewBody,
                requestBody: {
                    ...previewBody,
                    messages: sanitizeChatMessages(intent.messages)
                }
            };
        }

        case REQUEST_KINDS.SUMMARY: {
            const requestBody = {
                model: intent.model,
                messages: [{ role: 'user', content: intent.prompt }],
                temperature: intent.temperature
            };
            return { previewBody: requestBody, requestBody };
        }

        case REQUEST_KINDS.MEMORY_DRAFT: {
            const requestBody = {
                model: intent.model,
                messages: [{ role: 'user', content: intent.prompt }],
                temperature: intent.temperature,
                max_tokens: intent.maxTokens,
                stream: false
            };
            return { previewBody: requestBody, requestBody };
        }

        default:
            throw new Error(`Unsupported request intent kind: ${intent.kind}`);
    }
}

const payloadBuilders = new Map([
    ['openai_compatible', buildOpenAiCompatiblePayload]
]);

export function buildProviderPayload(providerId, intent) {
    const builder = payloadBuilders.get(providerId) || payloadBuilders.get('openai_compatible');
    return builder(intent);
}
