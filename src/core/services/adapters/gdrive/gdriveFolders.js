import { apiRequest, getTokens, saveTokens, getValidAccessToken } from './gdriveAuth.js';
import { GDRIVE_CLIENT_ID } from '@/core/config/syncConfig.js';

const API_BASE = 'https://www.googleapis.com/drive/v3';

const FOLDER_NAME = 'Glaze';
let folderIdCache = null;
const _folderIdCache = new Map();
let pickerApiLoaded = false;

export function getFolderIdCache() { return folderIdCache; }
export function setFolderIdCache(v) { folderIdCache = v; }
export function getFolderIdMap() { return _folderIdCache; }

export function invalidateGlazeFolderCache() {
    folderIdCache = null;
    _folderIdCache.clear();
}

export async function setGlazeFolderId(folderId) {
    folderIdCache = folderId;
    const tokens = await getTokens();
    if (tokens) {
        tokens.folderId = folderId;
        await saveTokens(tokens);
    }
}

async function findFoldersByName(name, parentId) {
    let query = `name='${name}' and mimeType='application/vnd.google-apps.folder' and trashed=false`;
    if (parentId) {
        query += ` and '${parentId}' in parents`;
    } else {
        query += ` and 'root' in parents`;
    }

    const response = await apiRequest(
        `${API_BASE}/files?q=${encodeURIComponent(query)}&spaces=drive&fields=files(id,name)&includeItemsFromAllDrives=true&supportsAllDrives=true`
    );

    if (!response.ok) {
        const err = await response.json().catch(() => ({}));
        throw new Error(err.error?.message || `Failed to search for folder '${name}' (${response.status})`);
    }
    const data = await response.json();
    return data.files || [];
}

async function findFolderByName(name, parentId) {
    let query = `name='${name}' and mimeType='application/vnd.google-apps.folder' and trashed=false`;
    if (parentId) {
        query += ` and '${parentId}' in parents`;
    } else {
        query += ` and 'root' in parents`;
    }

    const response = await apiRequest(
        `${API_BASE}/files?q=${encodeURIComponent(query)}&spaces=drive&fields=files(id,name)&includeItemsFromAllDrives=true&supportsAllDrives=true`
    );

    if (!response.ok) {
        const err = await response.json().catch(() => ({}));
        throw new Error(err.error?.message || `Failed to search for folder '${name}' (${response.status})`);
    }
    const data = await response.json();
    return data.files?.[0]?.id || null;
}

export async function findFileByName(name, parentId) {
    if (!parentId) return null;
    const query = `name='${name}' and '${parentId}' in parents and trashed=false`;
    const response = await apiRequest(
        `${API_BASE}/files?q=${encodeURIComponent(query)}&spaces=drive&fields=files(id,name,modifiedTime)&includeItemsFromAllDrives=true&supportsAllDrives=true`
    );

    if (!response.ok) {
        if (response.status === 404) return null;
        const err = await response.json().catch(() => ({}));
        throw new Error(err.error?.message || `Failed to search for file '${name}' (${response.status})`);
    }
    const data = await response.json();
    return data.files?.[0] || null;
}

async function folderHasContent(folderId) {
    const query = `'${folderId}' in parents and trashed=false`;
    const response = await apiRequest(
        `${API_BASE}/files?q=${encodeURIComponent(query)}&spaces=drive&fields=files(id)&pageSize=1&includeItemsFromAllDrives=true&supportsAllDrives=true`
    );
    if (!response.ok) return false;
    const data = await response.json();
    return (data.files?.length || 0) > 0;
}

async function loadPickerApi() {
    if (pickerApiLoaded && window.google?.picker) return;
    return new Promise((resolve, reject) => {
        const script = document.createElement('script');
        script.src = 'https://apis.google.com/js/api.js';
        script.onload = () => {
            window.gapi.load('picker', {
                callback: () => { pickerApiLoaded = true; resolve(); },
                onerror: () => reject(new Error('Failed to load Google Picker API'))
            });
        };
        script.onerror = () => reject(new Error('Failed to load Google API script'));
        document.head.appendChild(script);
    });
}

export async function pickFolder() {
    const accessToken = await getValidAccessToken();
    if (!accessToken) throw new Error('Not connected to Google Drive');

    await loadPickerApi();

    return new Promise((resolve, reject) => {
        try {
            const appId = GDRIVE_CLIENT_ID?.split('-')[0] || '';
            const view = new window.google.picker.DocsView(
                window.google.picker.ViewId.DOCS
            )
                .setSelectFolderEnabled(true)
                .setMimeTypes('application/vnd.google-apps.folder')
                .setMode(window.google.picker.DocsViewMode.LIST);

            const picker = new window.google.picker.PickerBuilder()
                .setAppId(appId)
                .setOAuthToken(accessToken)
                .addView(view)
                .setTitle('Select Glaze folder')
                .setCallback((data) => {
                    if (data.action === window.google.picker.Action.PICKED) {
                        const folder = data.docs[0];
                        resolve({ id: folder.id, name: folder.name });
                    } else if (data.action === window.google.picker.Action.CANCEL) {
                        resolve(null);
                    }
                })
                .build();
            picker.setVisible(true);
        } catch (e) {
            reject(e);
        }
    });
}

export function extractFolderId(input) {
    if (!input) return null;
    input = input.trim();
    const driveUrlMatch = input.match(/\/folders\/([a-zA-Z0-9_-]+)/);
    if (driveUrlMatch) return driveUrlMatch[1];
    const openUrlMatch = input.match(/[?&]id=([a-zA-Z0-9_-]+)/);
    if (openUrlMatch) return openUrlMatch[1];
    if (/^[a-zA-Z0-9_-]{10,}$/.test(input)) return input;
    return null;
}

export async function verifyFolderId(folderId) {
    try {
        const response = await apiRequest(
            `${API_BASE}/files/${encodeURIComponent(folderId)}?fields=id,name,mimeType,trashed&supportsAllDrives=true`
        );
        if (!response.ok) return null;
        const data = await response.json();
        if (data.trashed) return null;
        if (data.mimeType !== 'application/vnd.google-apps.folder') return null;
        return data;
    } catch {
        return null;
    }
}

export { getGlazeFolderId };

async function getGlazeFolderId(invalidate = false) {
    if (invalidate) {
        folderIdCache = null;
        _folderIdCache.clear();
    }
    if (folderIdCache) {
        const check = await apiRequest(`${API_BASE}/files/${folderIdCache}?fields=id,trashed,name&supportsAllDrives=true`);
        if (check.ok) {
            const data = await check.json();
            if (!data.trashed && data.name === FOLDER_NAME) return folderIdCache;
        }
        folderIdCache = null;
        _folderIdCache.clear();
    }
    const persistedTokens = await getTokens();
    if (persistedTokens?.folderId && persistedTokens.folderId !== folderIdCache) {
        const check = await apiRequest(`${API_BASE}/files/${persistedTokens.folderId}?fields=id,trashed,name&supportsAllDrives=true`);
        if (check.ok) {
            const data = await check.json();
            if (!data.trashed && data.name === FOLDER_NAME) {
                folderIdCache = persistedTokens.folderId;
                _folderIdCache.clear();
                return folderIdCache;
            }
        }
    }
    const folders = await findFoldersByName(FOLDER_NAME, null);
    if (folders.length === 0) return null;
    if (folders.length === 1) {
        folderIdCache = folders[0].id;
        return folderIdCache;
    }
    let bestFolder = null;
    for (const folder of folders) {
        const manifestFile = await findFileByName('manifest.json', folder.id);
        if (manifestFile) {
            bestFolder = folder;
            break;
        }
    }
    if (!bestFolder) {
        for (const folder of folders) {
            if (await folderHasContent(folder.id)) {
                bestFolder = folder;
                break;
            }
        }
    }
    if (!bestFolder) {
        bestFolder = folders[0];
    }
    folderIdCache = bestFolder.id;
    for (const folder of folders) {
        if (folder.id !== bestFolder.id) {
            const hasContent = await folderHasContent(folder.id);
            if (!hasContent) {
                try {
                    await apiRequest(`${API_BASE}/files/${folder.id}`, { method: 'DELETE' });
                } catch {}
            }
        }
    }
    return folderIdCache;
}

async function createFolder(name, parentId) {
    const body = {
        name,
        mimeType: 'application/vnd.google-apps.folder'
    };
    if (parentId) {
        body.parents = [parentId];
    }

    const response = await apiRequest(`${API_BASE}/files?fields=id&supportsAllDrives=true`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body)
    });

    if (!response.ok) {
        const err = await response.json().catch(() => ({}));
        throw new Error(err.error?.message || 'Failed to create folder');
    }

    const data = await response.json();
    return data.id;
}

async function getOrCreateFolder(name, parentId) {
    const existingId = await findFolderByName(name, parentId);
    if (existingId) return existingId;
    return createFolder(name, parentId);
}

export async function ensureFolder(path) {
    const parts = path.split('/').filter(Boolean);
    let parentId = null;

    if (parts[0] === FOLDER_NAME) {
        parentId = await getGlazeFolderId();
        if (!parentId) {
            parentId = await createFolder(FOLDER_NAME, null);
            folderIdCache = parentId;
            _folderIdCache.clear();
        }
        for (let i = 1; i < parts.length; i++) {
            parentId = await getOrCreateFolder(parts[i], parentId);
        }
    } else {
        for (const part of parts) {
            parentId = await getOrCreateFolder(part, parentId);
        }
    }

    if (path === '/Glaze') {
        folderIdCache = parentId;
    }

    return parentId;
}

export async function resolvePathToParent(path) {
    const parts = path.replace(/^\//, '').split('/');
    const fileName = parts.pop();
    let parentId = await getGlazeFolderId();

    if (!parentId) return { parentId: null, fileName };

    for (const dir of parts) {
        if (dir === FOLDER_NAME) continue;
        const cacheKey = `${parentId}/${dir}`;
        if (_folderIdCache.has(cacheKey)) {
            parentId = _folderIdCache.get(cacheKey);
            continue;
        }
        const existing = await findFolderByName(dir, parentId);
        if (existing) {
            _folderIdCache.set(cacheKey, existing);
            parentId = existing;
        } else {
            const created = await createFolder(dir, parentId);
            _folderIdCache.set(cacheKey, created);
            parentId = created;
        }
    }

    return { parentId, fileName };
}

export async function deleteFolder(path) {
    const GLAZE_PATH_PREFIX = '/Glaze';
    if (!path || !path.startsWith(GLAZE_PATH_PREFIX)) {
        throw new Error(`Refusing to delete outside Glaze folder: ${path}`);
    }
    if (path === '/Glaze' || path === `/${FOLDER_NAME}`) {
        const folderId = await getGlazeFolderId();
        if (!folderId) return false;
        const verifyResponse = await apiRequest(`${API_BASE}/files/${folderId}?fields=name&supportsAllDrives=true`);
        if (verifyResponse.ok) {
            const verifyData = await verifyResponse.json();
            if (verifyData.name !== FOLDER_NAME) {
                throw new Error(`Safety check failed: folder ID ${folderId} is named "${verifyData.name}", expected "${FOLDER_NAME}". Aborting delete.`);
            }
        }
        const response = await apiRequest(`${API_BASE}/files/${folderId}?supportsAllDrives=true`, { method: 'DELETE' });
        if (!response.ok && response.status !== 204) {
            throw new Error(`Delete folder failed ${response.status}`);
        }
        folderIdCache = null;
        _folderIdCache.clear();
        return true;
    }
    const parts = path.replace(/^\//, '').split('/').filter(Boolean);
    const folderName = parts[parts.length - 1];
    const parentPath = '/' + parts.slice(0, -1).join('/');
    const { parentId } = await resolvePathToParent(parentPath);
    const folderId = await findFolderByName(folderName, parentId);
    if (!folderId) return false;
    const response = await apiRequest(`${API_BASE}/files/${folderId}?supportsAllDrives=true`, { method: 'DELETE' });
    if (!response.ok && response.status !== 204) {
        throw new Error(`Delete folder failed ${response.status}`);
    }
    return true;
}

export async function listFolder(path) {
    const parts = path.replace(/^\//, '').split('/').filter(Boolean);
    let parentId = null;

    if (parts.length === 0 || (parts.length === 1 && parts[0] === FOLDER_NAME)) {
        parentId = await getGlazeFolderId();
    } else {
        const folderName = parts[parts.length - 1];
        const parentPath = '/' + parts.slice(0, -1).join('/');
        const { parentId: resolvedParent } = await resolvePathToParent(parentPath || `/${FOLDER_NAME}`);
        const folder = await findFolderByName(folderName, resolvedParent);
        parentId = folder;
    }

    if (!parentId) return { entries: [] };

    const query = `'${parentId}' in parents and trashed=false`;
    const response = await apiRequest(
        `${API_BASE}/files?q=${encodeURIComponent(query)}&spaces=drive&fields=files(id,name,mimeType,modifiedTime)&pageSize=1000&includeItemsFromAllDrives=true&supportsAllDrives=true`
    );

    if (!response.ok) return { entries: [] };

    const data = await response.json();
    const entries = (data.files || []).map(f => ({
        '.tag': f.mimeType === 'application/vnd.google-apps.folder' ? 'folder' : 'file',
        name: f.name,
        path: path === '/Glaze' ? `/Glaze/${f.name}` : `${path}/${f.name}`,
        path_display: path === '/Glaze' ? `/Glaze/${f.name}` : `${path}/${f.name}`,
        serverModified: f.modifiedTime,
        id: f.id
    }));

    return { entries, has_more: false };
}

export async function listFolderContinue() {
    return { entries: [], has_more: false };
}
