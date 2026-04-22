import { generateSummary as generateSummaryInternal } from '@/core/services/generationService.js';

/**
 * Official summary-generation use-case entrypoint.
 *
 * @param {Parameters<typeof generateSummaryInternal>[0]} input
 */
export async function generateSummary(input) {
    return generateSummaryInternal(input);
}
