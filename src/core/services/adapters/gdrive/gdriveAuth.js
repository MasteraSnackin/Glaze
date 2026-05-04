import { Capacitor } from '@capacitor/core';
import { Browser } from '@capacitor/browser';
import { App } from '@capacitor/app';
import { db } from '@/utils/db.js';
import { GDRIVE_CLIENT_ID, GDRIVE_CLIENT_SECRET } from '@/core/config/syncConfig.js';
import { SYNC_TOKENS_KEY } from '@/core/states/syncState.js';

const AUTH_BASE = 'https://accounts.google.com/o/oauth2/v2/auth';
const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const SCOPES = 'https://www.googleapis.com/auth/drive.file';

const getNativeRedirectUri = () => {
    if (import.meta.env.VITE_GDRIVE_REDIRECT_NATIVE) return import.meta.env.VITE_GDRIVE_REDIRECT_NATIVE;
    if (GDRIVE_CLIENT_ID && GDRIVE_CLIENT_ID.endsWith('.apps.googleusercontent.com')) {
        return GDRIVE_CLIENT_ID.split('.').reverse().join('.') + ':/oauth2redirect';
    }
    return 'com.hydall.glaze://oauth/gdrive';
};
const REDIRECT_URI_NATIVE = getNativeRedirectUri();
const REDIRECT_URI_WEB = import.meta.env.VITE_GDRIVE_REDIRECT_WEB || `${window.location.origin}/oauth/gdrive/redirect.html`;

export function isElectron() {
    return typeof navigator !== 'undefined' && navigator.userAgent.includes('Electron');
}

function getRedirectUri() {
    if (Capacitor.isNativePlatform()) return REDIRECT_URI_NATIVE;
    if (isElectron()) return `http://127.0.0.1:${localStorage.getItem('gz_electron_oauth_port') || '0'}/oauth/callback`;
    return REDIRECT_URI_WEB;
}

export function generateRandomString(length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    const array = crypto.getRandomValues(new Uint8Array(length));
    return Array.from(array, b => chars[b % chars.length]).join('');
}

async function sha256(text) {
    if (!crypto.subtle) return null;
    const encoder = new TextEncoder();
    const data = encoder.encode(text);
    const hash = await crypto.subtle.digest('SHA-256', data);
    return btoa(String.fromCharCode(...new Uint8Array(hash)))
        .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export async function getTokens() {
    const all = await db.get(SYNC_TOKENS_KEY);
    if (!all) return null;
    return all.gdrive || null;
}

export async function saveTokens(tokens) {
    const all = (await db.get(SYNC_TOKENS_KEY)) || {};
    all.gdrive = tokens;
    await db.queuedSet(SYNC_TOKENS_KEY, all);
}

async function clearTokens() {
    const all = (await db.get(SYNC_TOKENS_KEY)) || {};
    delete all.gdrive;
    await db.queuedSet(SYNC_TOKENS_KEY, all);
}

export async function refreshAccessToken(refreshToken) {
    if (!GDRIVE_CLIENT_ID) throw new Error('Google Drive client ID not configured');

    const params = {
        grant_type: 'refresh_token',
        refresh_token: refreshToken,
        client_id: GDRIVE_CLIENT_ID,
        ...(GDRIVE_CLIENT_SECRET && { client_secret: GDRIVE_CLIENT_SECRET })
    };

    const response = await fetch(TOKEN_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams(params)
    });

    if (!response.ok) {
        const err = await response.json().catch(() => ({}));
        throw Object.assign(new Error(err.error_description || 'Token refresh failed'), { status: response.status });
    }

    const existing = await getTokens();
    const data = await response.json();
    const newTokens = {
        access_token: data.access_token,
        refresh_token: refreshToken,
        expires_at: Date.now() + (data.expires_in || 3600) * 1000,
        ...(existing?.folderId ? { folderId: existing.folderId } : {})
    };
    await saveTokens(newTokens);
    return newTokens;
}

export async function getValidAccessToken() {
    const tokens = await getTokens();
    if (!tokens) return null;

    if (tokens.expires_at && Date.now() < tokens.expires_at - 60000) {
        return tokens.access_token;
    }

    if (tokens.refresh_token) {
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

export async function apiRequest(url, options = {}) {
    const accessToken = await getValidAccessToken();
    if (!accessToken) throw new Error('Not connected to Google Drive');

    const headers = {
        'Authorization': `Bearer ${accessToken}`,
        ...options.headers
    };

    const response = await fetch(url, { ...options, headers });

    if (response.status === 401) {
        const tokens = await getTokens();
        if (tokens?.refresh_token) {
            const refreshed = await refreshAccessToken(tokens.refresh_token);
            headers.Authorization = `Bearer ${refreshed.access_token}`;
            return fetch(url, { ...options, headers });
        }
        throw Object.assign(new Error('Session expired'), { status: 401 });
    }

    return response;
}

async function waitForElectronOAuth(challenge, usePlain, state, verifier) {
    const ipcRenderer = window.require('electron').ipcRenderer;
    const port = await ipcRenderer.invoke('oauth-start-server');
    const redirectUri = `http://127.0.0.1:${port}/oauth/callback`;

    const authUrl = new URL(AUTH_BASE);
    authUrl.searchParams.set('client_id', GDRIVE_CLIENT_ID);
    authUrl.searchParams.set('redirect_uri', redirectUri);
    authUrl.searchParams.set('response_type', 'code');
    authUrl.searchParams.set('scope', SCOPES);
    authUrl.searchParams.set('code_challenge', usePlain ? verifier : challenge);
    authUrl.searchParams.set('code_challenge_method', usePlain ? 'plain' : 'S256');
    authUrl.searchParams.set('state', state);
    authUrl.searchParams.set('access_type', 'offline');
    authUrl.searchParams.set('prompt', 'consent');

    const width = 500;
    const height = 600;
    const left = window.screenX + (window.outerWidth - width) / 2;
    const top = window.screenY + (window.outerHeight - height) / 2;
    const win = window.open(authUrl.toString(), 'gdrive-auth', `width=${width},height=${height},left=${left},top=${top}`);

    return new Promise((resolve) => {
        let resolved = false;
        let interval;
        const cleanup = () => clearInterval(interval);

        ipcRenderer.once('oauth-callback', (event, { code, state: returnedState, error }) => {
            if (resolved) return;
            resolved = true;
            cleanup();
            try { if (win && !win.closed) win.close(); } catch { }

            if (error || !code) { resolve(null); return; }
            if (returnedState !== state) {
                console.error('[gdriveAdapter] State mismatch');
                resolve(null);
                return;
            }
            resolve({ code, redirectUri });
        });

        interval = setInterval(() => {
            if (resolved) return;
            try {
                if (win && win.closed) {
                    resolved = true;
                    cleanup();
                    ipcRenderer.invoke('oauth-cancel-server');
                    resolve(null);
                }
            } catch {
                resolved = true;
                cleanup();
                resolve(null);
            }
        }, 1000);
    });
}

function waitForWebOAuth(authUrl, expectedState) {
    return new Promise((resolve) => {
        const width = 500;
        const height = 600;
        const left = window.screenX + (window.outerWidth - width) / 2;
        const top = window.screenY + (window.outerHeight - height) / 2;
        const win = window.open(authUrl, 'gdrive-auth', `width=${width},height=${height},left=${left},top=${top}`);

        let resolved = false;
        let interval;
        let onMessage;

        const cleanup = () => {
            clearInterval(interval);
            window.removeEventListener('message', onMessage);
        };

        onMessage = (e) => {
            if (resolved) return;
            if (e.data?.type === 'gdrive-oauth') {
                resolved = true;
                cleanup();
                const state = e.data.state;
                if (state !== expectedState) {
                    console.error('[gdriveAdapter] State mismatch');
                    resolve(null);
                    return;
                }
                resolve(e.data.code || null);
            }
        };

        interval = setInterval(() => {
            if (resolved) return;
            try {
                if (win.closed) {
                    cleanup();
                    resolve(null);
                }
            } catch {
                cleanup();
                resolve(null);
            }
        }, 1000);

        window.addEventListener('message', onMessage);
    });
}

async function exchangeCodeForToken(code, verifier, redirectUri) {
    const params = {
        grant_type: 'authorization_code',
        code,
        code_verifier: verifier,
        client_id: GDRIVE_CLIENT_ID,
        redirect_uri: redirectUri,
        ...(GDRIVE_CLIENT_SECRET && { client_secret: GDRIVE_CLIENT_SECRET })
    };

    const response = await fetch(TOKEN_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams(params)
    });

    if (!response.ok) {
        const err = await response.json().catch(() => ({}));
        throw new Error(err.error_description || 'Token exchange failed');
    }

    const data = await response.json();
    await saveTokens({
        access_token: data.access_token,
        refresh_token: data.refresh_token,
        expires_at: Date.now() + (data.expires_in || 3600) * 1000,
        token_type: data.token_type
    });

    localStorage.removeItem('gz_gdrive_pkce_verifier');
    localStorage.removeItem('gz_gdrive_pkce_state');
}

export async function connect() {
    if (!GDRIVE_CLIENT_ID) {
        throw new Error('Google Drive is not configured. Set VITE_GDRIVE_CLIENT_ID environment variable.');
    }

    const verifier = generateRandomString(64);
    const challenge = await sha256(verifier);
    const usePlain = !challenge;
    const state = generateRandomString(16);

    localStorage.setItem('gz_gdrive_pkce_verifier', verifier);
    localStorage.setItem('gz_gdrive_pkce_state', state);

    if (isElectron()) {
        const result = await waitForElectronOAuth(challenge, usePlain, state, verifier);
        if (result) {
            await exchangeCodeForToken(result.code, verifier, result.redirectUri);
        } else {
            throw new Error('Authorization cancelled');
        }
        return;
    }

    const redirectUri = getRedirectUri();
    const authUrl = new URL(AUTH_BASE);
    authUrl.searchParams.set('client_id', GDRIVE_CLIENT_ID);
    authUrl.searchParams.set('redirect_uri', redirectUri);
    authUrl.searchParams.set('response_type', 'code');
    authUrl.searchParams.set('scope', SCOPES);
    authUrl.searchParams.set('code_challenge', usePlain ? verifier : challenge);
    authUrl.searchParams.set('code_challenge_method', usePlain ? 'plain' : 'S256');
    authUrl.searchParams.set('state', state);
    authUrl.searchParams.set('access_type', 'offline');
    authUrl.searchParams.set('prompt', 'consent');

    if (Capacitor.isNativePlatform()) {
        await new Promise((resolve, reject) => {
            App.addListener('appUrlOpen', async (data) => {
                try {
                    const url = new URL(data.url);
                    const code = url.searchParams.get('code');
                    const returnedState = url.searchParams.get('state');

                    if (!code) return;

                    if (returnedState !== state) {
                        reject(new Error('State mismatch'));
                        return;
                    }

                    await exchangeCodeForToken(code, verifier, redirectUri);
                    resolve();
                } catch (e) {
                    reject(e);
                } finally {
                    try { await Browser.close(); } catch { }
                }
            }).then(listener => {
                Browser.open({ url: authUrl.toString() }).catch(reject);
            });
        });
    } else {
        const code = await waitForWebOAuth(authUrl.toString(), state);
        if (code) {
            await exchangeCodeForToken(code, verifier, redirectUri);
        } else {
            throw new Error('Authorization cancelled');
        }
    }
}

export async function disconnect() {
    const tokens = await getTokens();
    if (tokens?.access_token) {
        try {
            await fetch(`https://oauth2.googleapis.com/revoke?token=${tokens.access_token}`, {
                method: 'POST'
            });
        } catch { }
    }
    await clearTokens();
}

export async function isConnected() {
    const token = await getValidAccessToken();
    return token !== null;
}

export async function getAccountInfo() {
    const accessToken = await getValidAccessToken();
    if (!accessToken) return null;

    try {
        const response = await fetch('https://www.googleapis.com/oauth2/v2/userinfo', {
            headers: { 'Authorization': `Bearer ${accessToken}` }
        });

        if (!response.ok) return null;
        const data = await response.json();
        return {
            name: data.name || 'Google User',
            email: data.email,
            accountId: data.id
        };
    } catch {
        return null;
    }
}
