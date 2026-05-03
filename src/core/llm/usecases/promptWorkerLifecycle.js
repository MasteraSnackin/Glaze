function getWorker() {
    if (!globalThis._genWorker) {
        globalThis._genWorker = new Worker(new URL('../../../workers/generationWorker.js', import.meta.url), { type: 'module' });
        globalThis._workerQueue = new Map();
        globalThis._msgIdCounter = 0;

        globalThis._genWorker.onmessage = (e) => {
            const { id, success, data, error } = e.data;
            if (globalThis._workerQueue.has(id)) {
                if (success) globalThis._workerQueue.get(id).resolve(data);
                else globalThis._workerQueue.get(id).reject(new Error(error));
                globalThis._workerQueue.delete(id);
            }
        };

        globalThis._genWorker.onerror = (e) => {
            console.error('Generation worker crashed:', e);
            for (const [, { reject }] of globalThis._workerQueue) {
                reject(new Error('Worker crashed: ' + (e.message || 'Unknown error')));
            }
            globalThis._workerQueue.clear();
            globalThis._genWorker.terminate();
            globalThis._genWorker = null;
        };
    }
    return globalThis._genWorker;
}

export function processPromptAsync(payload) {
    const worker = getWorker();
    const WORKER_TIMEOUT = 30000;
    return new Promise((resolve, reject) => {
        const id = ++globalThis._msgIdCounter;

        const timer = setTimeout(() => {
            globalThis._workerQueue.delete(id);
            reject(new Error('Prompt building timed out (worker did not respond within 30s)'));
        }, WORKER_TIMEOUT);

        globalThis._workerQueue.set(id, {
            resolve: (data) => { clearTimeout(timer); resolve(data); },
            reject: (err) => { clearTimeout(timer); reject(err); }
        });
        worker.postMessage({ id, type: 'generateChatResponse', payload });
    });
}
