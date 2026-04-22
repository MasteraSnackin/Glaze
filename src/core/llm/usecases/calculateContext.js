import { calculateContext as calculateContextInternal } from '@/core/services/generationService.js';

/**
 * Official context-calculation use-case entrypoint.
 *
 * @param {Parameters<typeof calculateContextInternal>[0]} input
 */
export async function calculateContext(input) {
    return calculateContextInternal(input);
}
