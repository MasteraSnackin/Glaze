const isIOS = typeof navigator !== 'undefined' && /iPad|iPhone|iPod/.test(navigator.userAgent || '');
const PING_TIMEOUT = 2000;

function createModuleWorker() {
    return new Worker(
        new URL('../../../workers/generationWorker.js', import.meta.url),
        { type: 'module' }
    );
}

async function createIosFallbackWorker() {
    const workerUrl = new URL('../../../workers/generationWorker.js', import.meta.url);
    try {
        const response = await fetch(workerUrl.href);
        let code = await response.text();
        code = code.replace(/export\s*\{[^}]*\}/g, '');
        code = code.replace(/export\s+(default\s+)?/g, '');
        const blob = new Blob([code], { type: 'application/javascript' });
        return new Worker(URL.createObjectURL(blob));
    } catch (e) {
        console.error('[Worker] Failed to create iOS Blob worker:', e);
        return null;
    }
}

function pingWorker(worker) {
    return new Promise((resolve) => {
        const id = '_ping_' + Date.now();
        const timer = setTimeout(() => resolve(false), PING_TIMEOUT);
        const handler = (e) => {
            if (e.data?.id === id) {
                clearTimeout(timer);
                worker.removeEventListener('message', handler);
                resolve(true);
            }
        };
        worker.addEventListener('message', handler);
        worker.postMessage({ id, type: 'ping' });
    });
}

function attachHandlers(worker) {
    worker.onmessage = (e) => {
        const { id, success, data, error } = e.data;
        if (globalThis._workerQueue.has(id)) {
            if (success) globalThis._workerQueue.get(id).resolve(data);
            else globalThis._workerQueue.get(id).reject(new Error(error));
            globalThis._workerQueue.delete(id);
        }
    };

    worker.onerror = (e) => {
        console.error('Generation worker crashed:', e);
        for (const [, { reject }] of globalThis._workerQueue) {
            reject(new Error('Worker crashed: ' + (e.message || 'Unknown error')));
        }
        globalThis._workerQueue.clear();
        worker.terminate();
        globalThis._genWorker = null;
        globalThis._genWorkerInit = null;
    };
}

async function initWorker() {
    if (!isIOS) {
        const worker = createModuleWorker();
        attachHandlers(worker);
        return worker;
    }

    const moduleWorker = createModuleWorker();
    attachHandlers(moduleWorker);

    const alive = await pingWorker(moduleWorker);
    if (alive) {
        console.log('[Worker] Module worker responding on iOS');
        return moduleWorker;
    }

    console.warn('[Worker] Module worker unresponsive on iOS, trying Blob fallback');
    moduleWorker.terminate();

    const fallbackWorker = await createIosFallbackWorker();
    if (fallbackWorker) {
        attachHandlers(fallbackWorker);

        const fallbackAlive = await pingWorker(fallbackWorker);
        if (fallbackAlive) {
            console.log('[Worker] Blob fallback worker responding on iOS');
            return fallbackWorker;
        }

        console.error('[Worker] Blob fallback also unresponsive');
        fallbackWorker.terminate();
    }

    throw new Error('Failed to initialize generation worker on iOS');
}

async function getWorker() {
    if (globalThis._genWorker) return globalThis._genWorker;

    if (!globalThis._genWorkerInit) {
        globalThis._genWorkerInit = initWorker().then(worker => {
            globalThis._genWorker = worker;
            globalThis._workerQueue = globalThis._workerQueue || new Map();
            globalThis._msgIdCounter = globalThis._msgIdCounter || 0;
            return worker;
        }).catch(err => {
            globalThis._genWorkerInit = null;
            throw err;
        });
    }

    return globalThis._genWorkerInit;
}

function buildDiagnosticInfo(sentAt, payloadSize) {
    const parts = [
        '--- Prompt Worker Timeout Diagnostic ---',
        `Time: ${new Date().toISOString()}`,
        `Message sent at: ${sentAt ? new Date(sentAt).toISOString() : 'N/A'}`,
        `Elapsed: ${sentAt ? Date.now() - sentAt : 'N/A'}ms`,
        `Payload size: ${(payloadSize / 1024).toFixed(1)}KB`,
        `Worker exists: ${!!globalThis._genWorker}`,
        `Queue size: ${globalThis._workerQueue?.size || 0}`,
        `Main thread UA: ${typeof navigator !== 'undefined' ? navigator.userAgent : 'N/A'}`,
        `Main thread platform: ${typeof navigator !== 'undefined' ? navigator.platform : 'N/A'}`,
        `Main thread isIOS: ${isIOS}`,
        `Device memory: ${navigator?.deviceMemory || 'N/A'}GB`,
        `Hardware concurrency: ${navigator?.hardwareConcurrency || 'N/A'}`,
        '--- End Diagnostic ---'
    ];
    return parts.join('\n');
}

export async function processPromptAsync(payload) {
    const worker = await getWorker();
    const WORKER_TIMEOUT = 30000;
    const sentAt = Date.now();
    payload._sentAt = sentAt;
    const payloadSize = JSON.stringify(payload).length;

    return new Promise((resolve, reject) => {
        const id = ++globalThis._msgIdCounter;

        const timer = setTimeout(() => {
            globalThis._workerQueue.delete(id);
            const diagInfo = buildDiagnosticInfo(sentAt, payloadSize);
            const err = new Error('Prompt building timed out (worker did not respond within 30s)\n\n' + diagInfo);
            err._diagnostic = diagInfo;
            reject(err);
        }, WORKER_TIMEOUT);

        globalThis._workerQueue.set(id, {
            resolve: (data) => { clearTimeout(timer); resolve(data); },
            reject: (err) => { clearTimeout(timer); reject(err); }
        });
        worker.postMessage({ id, type: 'generateChatResponse', payload });
    });
}
