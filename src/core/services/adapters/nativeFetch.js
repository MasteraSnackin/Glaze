export function getNativeSafeFetch() {
    if (typeof window !== 'undefined' && window.CapacitorWebFetch) {
        return window.CapacitorWebFetch;
    }
    return fetch;
}

export async function safeUploadFetch(url, options) {
    const fetchFn = getNativeSafeFetch();
    return fetchFn(url, options);
}