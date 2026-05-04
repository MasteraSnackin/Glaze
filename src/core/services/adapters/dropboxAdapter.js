import { db } from '@/utils/db.js';
import { safeUploadFetch } from './nativeFetch.js';
import { getTokens, saveTokens, clearTokens, refreshAccessToken, connect, disconnect, isConnected as _isConnected } from './dropbox/dropboxAuth.js';

export { connect, disconnect } from './dropbox/dropboxAuth.js';

const API_BASE = 'https://api.dropboxapi.com/2';
const CONTENT_BASE = 'https://content.dropboxapi.com/2';
const APP_FOLDER_PREFIX = '/Glaze';

function stripAppFolderPrefix(path) {
    if (path === APP_FOLDER_PREFIX || path === APP_FOLDER_PREFIX + '/') return '';
    if (path.startsWith(APP_FOLDER_PREFIX + '/')) return path.slice(APP_FOLDER_PREFIX.length);
    return path;
}

async function getValidToken() {
    const tokens = await getTokens();
    if (!tokens) return null;

    try {
        await listFolder('');
        return tokens.access_token;
    } catch (e) {
        if (e.status === 401 && tokens.refresh_token) {
            try {
                const refreshed = await refreshAccessToken(tokens.refresh_token);
                return refreshed.access_token;
            } catch {
                await clearTokens();
                return null;
            }
        }
        return null;
    }
}

export async function isConnected() {
    const tokens = await getTokens();
    if (!tokens) return false;
    const valid = await getValidToken();
    return valid !== null;
}

async function apiCall(endpoint, body, accessToken) {
    if (!accessToken) {
        const tokens = await getTokens();
        if (!tokens) throw new Error('Not connected to Dropbox');
        accessToken = tokens.access_token;
    }

    const response = await fetch(`${API_BASE}${endpoint}`, {
        method: 'POST',
        headers: {
            'Authorization': `Bearer ${accessToken}`,
            'Content-Type': 'application/json'
        },
        body: JSON.stringify(body)
    });

    if (response.status === 401) {
        const tokens = await getTokens();
        if (tokens?.refresh_token) {
            const refreshed = await refreshAccessToken(tokens.refresh_token);
            return apiCall(endpoint, body, refreshed.access_token);
        }
        throw Object.assign(new Error('Session expired'), { status: 401 });
    }

    if (!response.ok) {
        const err = await response.json().catch(() => ({}));
        throw Object.assign(new Error(err.error?.tag || err.error_summary || `API error ${response.status}`), { status: response.status });
    }

    if (response.status === 204) return null;
    return response.json();
}

async function contentUpload(path, data, accessToken) {
    if (!accessToken) {
        const tokens = await getTokens();
        if (!tokens) throw new Error('Not connected to Dropbox');
        accessToken = tokens.access_token;
    }

    const body = typeof data === 'string' ? data : JSON.stringify(data);

    const response = await safeUploadFetch(`${CONTENT_BASE}/files/upload`, {
        method: 'POST',
        headers: {
            'Authorization': `Bearer ${accessToken}`,
            'Content-Type': 'application/octet-stream',
            'Dropbox-API-Arg': JSON.stringify({
                path,
                mode: 'overwrite',
                autorename: false,
                mute: true
            })
        },
        body
    });

    if (response.status === 401) {
        const tokens = await getTokens();
        if (tokens?.refresh_token) {
            const refreshed = await refreshAccessToken(tokens.refresh_token);
            return contentUpload(path, data, refreshed.access_token);
        }
        throw Object.assign(new Error('Session expired'), { status: 401 });
    }

    if (!response.ok) {
        const err = await response.json().catch(() => ({}));
        throw Object.assign(new Error(err.error?.tag || err.error_summary || `Upload failed ${response.status}`), { status: response.status });
    }

    return response.json();
}

async function contentDownload(path, accessToken) {
    if (!accessToken) {
        const tokens = await getTokens();
        if (!tokens) throw new Error('Not connected to Dropbox');
        accessToken = tokens.access_token;
    }

    const response = await safeUploadFetch(`${CONTENT_BASE}/files/download`, {
        method: 'POST',
        headers: {
            'Authorization': `Bearer ${accessToken}`,
            'Dropbox-API-Arg': JSON.stringify({ path })
        }
    });

    if (response.status === 401) {
        const tokens = await getTokens();
        if (tokens?.refresh_token) {
            const refreshed = await refreshAccessToken(tokens.refresh_token);
            return contentDownload(path, refreshed.access_token);
        }
        throw Object.assign(new Error('Session expired'), { status: 401 });
    }

    if (response.status === 409) {
        return null;
    }

    if (!response.ok) {
        throw Object.assign(new Error(`Download failed ${response.status}`), { status: response.status });
    }

    const metadata = JSON.parse(response.headers.get('dropbox-api-result') || '{}');
    const text = await response.text();
    return { data: text, metadata };
}

const _ensuredFolders = new Set();

export function invalidateFolderCache() {
    _ensuredFolders.clear();
}

export async function ensureFolder(path) {
    const strippedPath = stripAppFolderPrefix(path);
    const parts = strippedPath.split('/').filter(Boolean);
    if (parts.length === 0) return;
    let currentPath = '';
    for (const part of parts) {
        currentPath = currentPath + '/' + part;
        if (_ensuredFolders.has(currentPath)) continue;
        try {
            await apiCall('/files/create_folder_v2', { path: currentPath, autorename: false });
            _ensuredFolders.add(currentPath);
        } catch (e) {
            if (e.status === 409 || e.message?.includes('conflict') || e.message?.includes('already_exists')) {
                _ensuredFolders.add(currentPath);
                continue;
            }
            throw e;
        }
    }
}

export async function listFolder(path) {
    return apiCall('/files/list_folder', { path: stripAppFolderPrefix(path) || '', recursive: false, include_deleted: false });
}

export async function listFolderContinue(cursor) {
    return apiCall('/files/list_folder/continue', { cursor });
}

export async function upload(path, data) {
    return contentUpload(stripAppFolderPrefix(path), data);
}

export async function uploadBinary(path, arrayBuffer) {
    const strippedPath = stripAppFolderPrefix(path);
    if (!arrayBuffer) return null;
    const tokens = await getTokens();
    if (!tokens) throw new Error('Not connected to Dropbox');
    const accessToken = tokens.access_token;

    const response = await safeUploadFetch(`${CONTENT_BASE}/files/upload`, {
        method: 'POST',
        headers: {
            'Authorization': `Bearer ${accessToken}`,
            'Content-Type': 'application/octet-stream',
            'Dropbox-API-Arg': JSON.stringify({
                path: strippedPath,
                mode: 'overwrite',
                autorename: false,
                mute: true
            })
        },
        body: arrayBuffer
    });

    if (response.status === 401) {
        if (tokens?.refresh_token) {
            const refreshed = await refreshAccessToken(tokens.refresh_token);
            const retry = await safeUploadFetch(`${CONTENT_BASE}/files/upload`, {
                method: 'POST',
                headers: {
                    'Authorization': `Bearer ${refreshed.access_token}`,
                    'Content-Type': 'application/octet-stream',
                    'Dropbox-API-Arg': JSON.stringify({
                        path: strippedPath,
                        mode: 'overwrite',
                        autorename: false,
                        mute: true
                    })
                },
                body: arrayBuffer
            });
            if (!retry.ok) throw Object.assign(new Error(`Binary upload failed ${retry.status}`), { status: retry.status });
            return retry.json();
        }
        throw Object.assign(new Error('Session expired'), { status: 401 });
    }

    if (!response.ok) {
        const err = await response.json().catch(() => ({}));
        throw Object.assign(new Error(err.error?.tag || err.error_summary || `Binary upload failed ${response.status}`), { status: response.status });
    }

    return response.json();
}

export async function downloadBinary(path) {
    const strippedPath = stripAppFolderPrefix(path);
    const tokens = await getTokens();
    if (!tokens) throw new Error('Not connected to Dropbox');
    const accessToken = tokens.access_token;

    const response = await safeUploadFetch(`${CONTENT_BASE}/files/download`, {
        method: 'POST',
        headers: {
            'Authorization': `Bearer ${accessToken}`,
            'Dropbox-API-Arg': JSON.stringify({ path: strippedPath })
        }
    });

    if (response.status === 401) {
        if (tokens?.refresh_token) {
            const refreshed = await refreshAccessToken(tokens.refresh_token);
            const retry = await safeUploadFetch(`${CONTENT_BASE}/files/download`, {
                method: 'POST',
                headers: {
                    'Authorization': `Bearer ${refreshed.access_token}`,
                    'Dropbox-API-Arg': JSON.stringify({ path: strippedPath })
                }
            });
            if (retry.status === 409) return null;
            if (!retry.ok) throw Object.assign(new Error(`Binary download failed ${retry.status}`), { status: retry.status });
            return retry.arrayBuffer();
        }
        throw Object.assign(new Error('Session expired'), { status: 401 });
    }

    if (response.status === 409) return null;
    if (!response.ok) throw Object.assign(new Error(`Binary download failed ${response.status}`), { status: response.status });
    return response.arrayBuffer();
}

export async function download(path) {
    return contentDownload(stripAppFolderPrefix(path));
}

async function retryApiCall(endpoint, body, accessToken, retries = 3) {
    for (let attempt = 0; attempt <= retries; attempt++) {
        try {
            return await apiCall(endpoint, body, accessToken);
        } catch (e) {
            if (e.status === 429 && attempt < retries) {
                const delay = 1000 * Math.pow(2, attempt);
                await new Promise(r => setTimeout(r, delay));
                continue;
            }
            throw e;
        }
    }
}

export async function deleteFolder(path) {
    const strippedPath = stripAppFolderPrefix(path);
    if (!strippedPath) {
        let entries = [];
        try {
            const result = await apiCall('/files/list_folder', { path: '', recursive: true, include_deleted: false });
            entries = result?.entries || [];
            let cursor = result?.cursor || null;
            while (result?.has_more && cursor) {
                const more = await apiCall('/files/list_folder/continue', { cursor });
                entries.push(...(more?.entries || []));
                cursor = more?.cursor || null;
            }
        } catch {}
        try {
            await apiCall('/files/delete_batch', {
                entries: entries.map(e => ({ path: e.path_lower || e.path_display }))
            });
            return true;
        } catch {
            for (const entry of entries) {
                try {
                    await retryApiCall('/files/delete_v2', { path: entry.path_lower || entry.path_display });
                } catch {}
                await new Promise(r => setTimeout(r, 300));
            }
            return true;
        }
    }
    return retryApiCall('/files/delete_v2', { path: strippedPath });
}

export async function deleteFile(fileOrPath) {
    const path = typeof fileOrPath === 'string'
        ? fileOrPath
        : (fileOrPath?.path_display || fileOrPath?.path || '');
    return apiCall('/files/delete_v2', { path: stripAppFolderPrefix(path) });
}

export async function getAccountInfo() {
    const tokens = await getTokens();
    if (!tokens) return null;
    try {
        const result = await apiCall('/users/get_current_account', null, tokens.access_token);
        return {
            name: result.name?.display_name || 'Dropbox User',
            email: result.email,
            accountId: result.account_id
        };
    } catch {
        return null;
    }
}
