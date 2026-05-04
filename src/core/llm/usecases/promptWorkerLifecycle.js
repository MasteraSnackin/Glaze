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

function buildDiagnosticInfo(sentAt, payloadSize) {
    const isIOS = typeof navigator !== 'undefined' && /iPad|iPhone|iPod/.test(navigator.userAgent || '');
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

export function processPromptAsync(payload) {
    const worker = getWorker();
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
