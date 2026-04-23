const GENERATION_HOOK_DEFINITIONS = Object.freeze({
    beforePromptBuild: Object.freeze({
        mode: 'readonly',
        description: 'Observe raw chat prompt inputs before prompt build runs.'
    }),
    afterPromptBuild: Object.freeze({
        mode: 'mutating',
        description: 'Adjust built chat prompt data before late enrichment and dispatch.'
    }),
    beforeRequestAssembly: Object.freeze({
        mode: 'mutating',
        description: 'Adjust request assembly inputs before provider payload construction.'
    }),
    beforeRequestSend: Object.freeze({
        mode: 'mutating',
        description: 'Adjust preview/request payload right before transport dispatch.'
    }),
    afterResponseNormalize: Object.freeze({
        mode: 'mutating',
        description: 'Adjust normalized response text or reasoning before app consumers receive it.'
    }),
    afterGenerationCommit: Object.freeze({
        mode: 'readonly',
        description: 'Observe committed generation results after persistence/UI updates.'
    })
});

export const GENERATION_EXTENSION_POINTS = Object.freeze(Object.keys(GENERATION_HOOK_DEFINITIONS));

const hookRegistry = new Map(GENERATION_EXTENSION_POINTS.map((hookName) => [hookName, []]));

let nextHandlerId = 1;

function assertKnownHook(hookName) {
    if (!GENERATION_HOOK_DEFINITIONS[hookName]) {
        throw new Error(`[extensionRegistry] Unknown generation hook: ${hookName}`);
    }
}

function clonePayload(payload) {
    if (payload == null) return payload;
    if (typeof structuredClone === 'function') {
        try {
            return structuredClone(payload);
        } catch (error) {
            console.warn('[extensionRegistry] structuredClone failed, falling back to original payload for readonly hook snapshot', error);
        }
    }

    try {
        return JSON.parse(JSON.stringify(payload));
    } catch (error) {
        console.warn('[extensionRegistry] JSON clone failed, falling back to original payload for readonly hook snapshot', error);
        return payload;
    }
}

function deepFreeze(value, seen = new WeakSet()) {
    if (!value || typeof value !== 'object' || seen.has(value)) {
        return value;
    }

    seen.add(value);
    for (const key of Object.keys(value)) {
        deepFreeze(value[key], seen);
    }
    return Object.freeze(value);
}

function freezePayloadSnapshot(payload) {
    return deepFreeze(clonePayload(payload));
}

function sortHookEntries(entries) {
    entries.sort((a, b) => {
        if (a.priority !== b.priority) {
            return a.priority - b.priority;
        }
        return a.id - b.id;
    });
}

export function getGenerationHookDefinitions() {
    return GENERATION_HOOK_DEFINITIONS;
}

export function listRegisteredGenerationHooks() {
    return GENERATION_EXTENSION_POINTS.map((hookName) => ({
        hookName,
        mode: GENERATION_HOOK_DEFINITIONS[hookName].mode,
        handlers: (hookRegistry.get(hookName) || []).map((entry) => ({
            name: entry.name,
            priority: entry.priority
        }))
    }));
}

export function registerGenerationHook(hookName, handler, options = {}) {
    assertKnownHook(hookName);

    if (typeof handler !== 'function') {
        throw new Error(`[extensionRegistry] Hook handler for ${hookName} must be a function`);
    }

    const entry = {
        id: nextHandlerId++,
        hookName,
        handler,
        name: options.name || 'anonymous-extension',
        priority: Number.isFinite(options.priority) ? options.priority : 0
    };

    const entries = hookRegistry.get(hookName);
    entries.push(entry);
    sortHookEntries(entries);

    return () => {
        const nextEntries = hookRegistry.get(hookName);
        const index = nextEntries.findIndex((candidate) => candidate.id === entry.id);
        if (index !== -1) {
            nextEntries.splice(index, 1);
        }
    };
}

export function registerAppExtension(extension) {
    if (!extension || typeof extension !== 'object') {
        throw new Error('[extensionRegistry] Extension descriptor must be an object');
    }

    const { name = 'anonymous-extension', priority = 0, hooks = {} } = extension;
    const disposers = [];

    for (const [hookName, handler] of Object.entries(hooks)) {
        disposers.push(registerGenerationHook(hookName, handler, { name, priority }));
    }

    return () => {
        for (const dispose of disposers) {
            dispose();
        }
    };
}

export async function runGenerationHook(hookName, payload) {
    assertKnownHook(hookName);

    const definition = GENERATION_HOOK_DEFINITIONS[hookName];
    const entries = hookRegistry.get(hookName) || [];

    if (!entries.length) {
        return payload;
    }

    if (definition.mode === 'readonly') {
        const readonlyPayload = freezePayloadSnapshot(payload);
        for (const entry of entries) {
            try {
                await entry.handler(readonlyPayload, {
                    hookName,
                    mode: definition.mode,
                    extensionName: entry.name
                });
            } catch (error) {
                console.error(`[extensionRegistry] Hook ${hookName} failed in ${entry.name}`, error);
            }
        }
        return payload;
    }

    let nextPayload = payload;
    for (const entry of entries) {
        try {
            const candidate = await entry.handler(nextPayload, {
                hookName,
                mode: definition.mode,
                extensionName: entry.name
            });
            if (candidate !== undefined) {
                nextPayload = candidate;
            }
        } catch (error) {
            console.error(`[extensionRegistry] Hook ${hookName} failed in ${entry.name}`, error);
        }
    }

    return nextPayload;
}
