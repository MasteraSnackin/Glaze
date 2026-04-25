import { GENERATION_EXTENSION_POINTS } from '@/core/extensions/extensionRegistry.js';

const STEP_ORDER = Object.freeze([
    'vectorSearch',
    'memoryInjection',
    'lateVectorLoreInjection',
    'contextLimitGuard',
    'promptReady',
    'requestExecution'
]);

const FORBIDDEN_REORDERINGS = Object.freeze([
    { before: 'memoryInjection', after: 'vectorSearch', reason: 'Vector lore entries must be resolved before memory injection so that token budget accounts for both' },
    { before: 'lateVectorLoreInjection', after: 'memoryInjection', reason: 'Memory injection must happen before late vector lore so that memory tokens are included in static token count for context limit check' },
    { before: 'contextLimitGuard', after: 'lateVectorLoreInjection', reason: 'Context limit guard must run after all static injections to produce accurate token accounting' },
    { before: 'requestExecution', after: 'contextLimitGuard', reason: 'Request must not execute if context limit is exceeded' }
]);

const EXTENSION_POINTS = GENERATION_EXTENSION_POINTS;

export class PipelineContext {
    constructor(input) {
        this.text = input.text;
        this.char = input.char;
        this.history = input.history;
        this.safeHistory = input.safeHistory;
        this.summary = input.summary;
        this.authorsNote = input.authorsNote;
        this.guidanceText = input.guidanceText;
        this.guidanceType = input.guidanceType;

        this.apiConfig = input.apiConfig;
        this.activePreset = input.activePreset;
        this.sessionVars = input.sessionVars;

        this.contextSize = input.contextSize;
        this.maxTokens = input.maxTokens;
        this.safeContext = input.contextSize - input.maxTokens;

        this.result = input.result;
        this.messages = input.result?.messages || [];
        this.loreEntries = input.result?.loreEntries || [];
        this.memoryEntries = [];
        this.memoryTokens = 0;
        this.memoryReserve = input.memoryReserve || 0;
        this.vectorLoreTokens = 0;
        this.contextBreakdown = null;

        this.controller = input.controller;
        this.callbacks = input.callbacks || {};

        this.stepLog = [];
        this._aborted = false;
    }

    get isAborted() {
        return this._aborted || this.controller?.signal?.aborted;
    }

    abort() {
        this._aborted = true;
    }

    logStep(stepName, data = {}) {
        this.stepLog.push({
            step: stepName,
            timestamp: Date.now(),
            ...data
        });
    }
}

export function validateStepOrder(steps) {
    const indexMap = new Map(steps.map((s, i) => [s, i]));
    for (const rule of FORBIDDEN_REORDERINGS) {
        const beforeIdx = indexMap.get(rule.before);
        const afterIdx = indexMap.get(rule.after);
        if (beforeIdx !== undefined && afterIdx !== undefined && beforeIdx < afterIdx) {
            throw new Error(`Pipeline ordering violation: "${rule.before}" runs before "${rule.after}" — ${rule.reason}`);
        }
    }
}

export { STEP_ORDER, FORBIDDEN_REORDERINGS, EXTENSION_POINTS };
