import { generateMemoryDraft as generateMemoryDraftInternal } from '@/core/services/generationService.js';

/**
 * Official memory-draft generation use-case entrypoint.
 *
 * @param {Parameters<typeof generateMemoryDraftInternal>[0]} input
 */
export async function generateMemoryDraft(input) {
    return generateMemoryDraftInternal(input);
}
