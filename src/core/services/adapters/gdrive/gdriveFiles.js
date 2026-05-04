import { apiRequest, getValidAccessToken, getTokens, refreshAccessToken, generateRandomString } from './gdriveAuth.js';
import { resolvePathToParent, getFolderIdCache, invalidateGlazeFolderCache, findFileByName } from './gdriveFolders.js';
import { safeUploadFetch } from '../nativeFetch.js';

const API_BASE = 'https://www.googleapis.com/drive/v3';
const UPLOAD_BASE = 'https://www.googleapis.com/upload/drive/v3';

const _fileIdCache = new Map();

function loadFileIdCache() {
    try {
        const raw = localStorage.getItem('gz_gdrive_file_id_cache');
        if (raw) {
            const parsed = JSON.parse(raw);
            for (const [k, v] of Object.entries(parsed)) _fileIdCache.set(k, v);
        }
    } catch {}
}

function saveFileIdCache() {
    try {
        const obj = Object.fromEntries(_fileIdCache.entries());
        localStorage.setItem('gz_gdrive_file_id_cache', JSON.stringify(obj));
    } catch {}
}

function cacheFileId(path, fileId) {
    _fileIdCache.set(path, fileId);
    saveFileIdCache();
}

function getCachedFileId(path) {
    return _fileIdCache.get(path) || null;
}

loadFileIdCache();

export function clearFileIdCache() {
    _fileIdCache.clear();
    saveFileIdCache();
}

export async function upload(path, data) {
    const { parentId, fileName } = await resolvePathToParent(path);
    let existingFile = null;
    const cachedId = getCachedFileId(path);
    if (cachedId) {
        const check = await apiRequest(`${API_BASE}/files/${cachedId}?fields=id,name,trashed&supportsAllDrives=true`);
        if (check.ok) {
            const info = await check.json();
            if (!info.trashed) existingFile = info;
        }
    }
    if (!existingFile) {
        existingFile = await findFileByName(fileName, parentId);
        if (existingFile) cacheFileId(path, existingFile.id);
    }

    const body = typeof data === 'string' ? data : JSON.stringify(data);

    if (existingFile) {
        const accessToken = await getValidAccessToken();
        if (!accessToken) throw new Error('Not connected to Google Drive');

        const response = await safeUploadFetch(
            `${UPLOAD_BASE}/files/${existingFile.id}?uploadType=media&supportsAllDrives=true`,
            {
                method: 'PATCH',
                headers: {
                    'Authorization': `Bearer ${accessToken}`,
                    'Content-Type': 'application/octet-stream'
                },
                body
            }
        );

        if (response.status === 401) {
            const tokens = await getTokens();
            if (tokens?.refresh_token) {
                const refreshed = await refreshAccessToken(tokens.refresh_token);
                const retry = await safeUploadFetch(
                    `${UPLOAD_BASE}/files/${existingFile.id}?uploadType=media&supportsAllDrives=true`,
                    {
                        method: 'PATCH',
                        headers: {
                            'Authorization': `Bearer ${refreshed.access_token}`,
                            'Content-Type': 'application/octet-stream'
                        },
                        body
                    }
                );
                if (!retry.ok) throw new Error(`Upload failed ${retry.status}`);
                return retry.json();
            }
            throw Object.assign(new Error('Session expired'), { status: 401 });
        }

        if (!response.ok) {
            const err = await response.json().catch(() => ({}));
            throw new Error(err.error?.message || `Upload failed ${response.status}`);
        }

        return response.json();
    } else {
        const accessToken = await getValidAccessToken();
        if (!accessToken) throw new Error('Not connected to Google Drive');

        const metadata = {
            name: fileName,
            parents: [parentId]
        };

        const boundary = 'glaze_boundary_' + generateRandomString(16);
        const multipartBody =
            `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${JSON.stringify(metadata)}\r\n` +
            `--${boundary}\r\nContent-Type: application/octet-stream\r\n\r\n${body}\r\n` +
            `--${boundary}--`;

        const response = await safeUploadFetch(
            `${UPLOAD_BASE}/files?uploadType=multipart&fields=id`,
            {
                method: 'POST',
                headers: {
                    'Authorization': `Bearer ${accessToken}`,
                    'Content-Type': `multipart/related; boundary=${boundary}`
                },
                body: multipartBody
            }
        );

        if (response.status === 401) {
            const tokens = await getTokens();
            if (tokens?.refresh_token) {
                const refreshed = await refreshAccessToken(tokens.refresh_token);
                const retry = await safeUploadFetch(
                    `${UPLOAD_BASE}/files?uploadType=multipart&fields=id&supportsAllDrives=true`,
                    {
                        method: 'POST',
                        headers: {
                            'Authorization': `Bearer ${refreshed.access_token}`,
                            'Content-Type': `multipart/related; boundary=${boundary}`
                        },
                        body: multipartBody
                    }
                );
                if (!retry.ok) throw new Error(`Upload failed ${retry.status}`);
                return retry.json();
            }
            throw Object.assign(new Error('Session expired'), { status: 401 });
        }

        if (!response.ok) {
            const err = await response.json().catch(() => ({}));
            throw new Error(err.error?.message || `Upload failed ${response.status}`);
        }

        const result = await response.json();
        if (result?.id) cacheFileId(path, result.id);
        return result;
    }
}

export async function uploadBinary(path, arrayBuffer) {
    if (!arrayBuffer) return null;
    const { parentId, fileName } = await resolvePathToParent(path);
    let existingFile = null;
    const cachedId = getCachedFileId(path);
    if (cachedId) {
        const check = await apiRequest(`${API_BASE}/files/${cachedId}?fields=id,name,trashed&supportsAllDrives=true`);
        if (check.ok) {
            const info = await check.json();
            if (!info.trashed) existingFile = info;
        }
    }
    if (!existingFile) {
        existingFile = await findFileByName(fileName, parentId);
        if (existingFile) cacheFileId(path, existingFile.id);
    }
    const accessToken = await getValidAccessToken();
    if (!accessToken) throw new Error('Not connected to Google Drive');

    if (existingFile) {
        const response = await safeUploadFetch(
            `${UPLOAD_BASE}/files/${existingFile.id}?uploadType=media&supportsAllDrives=true`,
            {
                method: 'PATCH',
                headers: {
                    'Authorization': `Bearer ${accessToken}`,
                    'Content-Type': 'application/octet-stream'
                },
                body: arrayBuffer
            }
        );
        if (!response.ok) throw new Error(`Binary upload failed ${response.status}`);
        return response.json();
    }

    const metadata = { name: fileName, parents: [parentId] };
    const boundary = 'glaze_boundary_' + generateRandomString(16);
    const metaPart = `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${JSON.stringify(metadata)}\r\n`;
    const binaryBlob = new Blob([arrayBuffer]);
    const multipartBody = new Blob([
        new TextEncoder().encode(metaPart),
        new TextEncoder().encode(`--${boundary}\r\nContent-Type: application/octet-stream\r\n\r\n`),
        binaryBlob,
        new TextEncoder().encode(`\r\n--${boundary}--`)
    ]);

    const response = await safeUploadFetch(
        `${UPLOAD_BASE}/files?uploadType=multipart&fields=id&supportsAllDrives=true`,
        {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${accessToken}`,
                'Content-Type': `multipart/related; boundary=${boundary}`
            },
            body: multipartBody
        }
    );
    if (!response.ok) throw new Error(`Binary upload failed ${response.status}`);
    const result = await response.json();
    if (result?.id) cacheFileId(path, result.id);
    return result;
}

export async function downloadBinary(path, _retry = false) {
    const { parentId, fileName } = await resolvePathToParent(path);
    let file = null;
    const cachedId = getCachedFileId(path);
    if (cachedId) {
        const check = await apiRequest(`${API_BASE}/files/${cachedId}?fields=id,name,trashed&supportsAllDrives=true`);
        if (check.ok) {
            const info = await check.json();
            if (!info.trashed) file = info;
        }
    }
    if (!file) {
        file = await findFileByName(fileName, parentId);
        if (file) cacheFileId(path, file.id);
    }

    if (!file) {
        if (!_retry && parentId === getFolderIdCache()) {
            invalidateGlazeFolderCache();
            clearFileIdCache();
            return downloadBinary(path, true);
        }
        return null;
    }

    const response = await apiRequest(
        `${API_BASE}/files/${file.id}?alt=media&supportsAllDrives=true`
    );

    if (!response.ok) {
        if (response.status === 404) return null;
        throw new Error(`Binary download failed ${response.status}`);
    }

    return response.arrayBuffer();
}

export async function download(path, _retry = false) {
    const { parentId, fileName } = await resolvePathToParent(path);
    let file = null;
    const cachedId = getCachedFileId(path);
    if (cachedId) {
        const check = await apiRequest(`${API_BASE}/files/${cachedId}?fields=id,name,trashed&supportsAllDrives=true`);
        if (check.ok) {
            const info = await check.json();
            if (!info.trashed) file = info;
        }
    }
    if (!file) {
        file = await findFileByName(fileName, parentId);
        if (file) cacheFileId(path, file.id);
    }

    if (!file) {
        if (!_retry && parentId === getFolderIdCache()) {
            invalidateGlazeFolderCache();
            clearFileIdCache();
            return download(path, true);
        }
        return null;
    }

    const response = await apiRequest(
        `${API_BASE}/files/${file.id}?alt=media&supportsAllDrives=true`
    );

    if (!response.ok) {
        if (response.status === 404) return null;
        throw new Error(`Download failed ${response.status}`);
    }

    const text = await response.text();
    return {
        data: text,
        metadata: { id: file.id, modifiedTime: file.modifiedTime }
    };
}

export async function deleteFile(fileOrPath) {
    let fileId = null;
    let resolvedPath = '';

    if (typeof fileOrPath === 'object' && fileOrPath?.id) {
        fileId = fileOrPath.id;
        resolvedPath = fileOrPath?.path_display || fileOrPath?.path || '';
    } else {
        resolvedPath = typeof fileOrPath === 'string'
            ? fileOrPath
            : (fileOrPath?.path_display || fileOrPath?.path || '');
        const GLAZE_PATH_PREFIX = '/Glaze';
        if (!resolvedPath || !resolvedPath.startsWith(GLAZE_PATH_PREFIX)) {
            throw new Error(`Refusing to delete outside Glaze folder: ${resolvedPath}`);
        }
        const { parentId, fileName } = await resolvePathToParent(resolvedPath);
        const file = await findFileByName(fileName, parentId);
        if (!file) return null;
        fileId = file.id;
    }

    const response = await apiRequest(
        `${API_BASE}/files/${fileId}?supportsAllDrives=true`,
        { method: 'DELETE' }
    );

    if (!response.ok && response.status !== 204) {
        throw new Error(`Delete failed ${response.status}`);
    }

    return null;
}
