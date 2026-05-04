import { Capacitor } from '@capacitor/core';
import { Browser } from '@capacitor/browser';
import { App } from '@capacitor/app';
import { db } from '@/utils/db.js';
import { DROPBOX_APP_KEY } from '@/core/config/syncConfig.js';
import { SYNC_TOKENS_KEY } from '@/core/states/syncState.js';

const REDIRECT_URI_NATIVE = import.meta.env.VITE_DROPBOX_REDIRECT_NATIVE || 'com.hydall.glaze://oauth/dropbox';
const REDIRECT_URI_WEB = import.meta.env.VITE_DROPBOX_REDIRECT_WEB || `${window.location.origin}/oauth/dropbox/redirect.html`;

export function isElectron() {
    return typeof navigator !== 'undefined' && navigator.userAgent.includes('Electron');
}

function getRedirectUri() {
    if (Capacitor.isNativePlatform()) return REDIRECT_URI_NATIVE;
    if (isElectron()) return `http://127.0.0.1:${localStorage.getItem('gz_electron_oauth_port') || '0'}/oauth/callback`;
    return REDIRECT_URI_WEB;
}

function generateRandomString(length) {
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
    return all.dropbox || null;
}

export async function saveTokens(tokens) {
    const all = (await db.get(SYNC_TOKENS_KEY)) || {};
    all.dropbox = tokens;
    await db.queuedSet(SYNC_TOKENS_KEY, all);
}

export async function clearTokens() {
    const all = (await db.get(SYNC_TOKENS_KEY)) || {};
    delete all.dropbox;
    await db.queuedSet(SYNC_TOKENS_KEY, all);
}

export async function refreshAccessToken(refreshToken) {
    if (!DROPBOX_APP_KEY) throw new Error('Dropbox app key not configured');

    const response = await fetch('https://api.dropboxapi.com/oauth2/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
            grant_type: 'refresh_token',
            refresh_token: refreshToken,
            client_id: DROPBOX_APP_KEY
        })
    });

    if (!response.ok) {
        const err = await response.json().catch(() => ({}));
        throw Object.assign(new Error(err.error_description || 'Token refresh failed'), { status: response.status });
    }

    const data = await response.json();
    const newTokens = {
        access_token: data.access_token,
        refresh_token: refreshToken,
        expires_at: Date.now() + (data.expires_in || 14400) * 1000,
        account_id: data.account_id
    };
    await saveTokens(newTokens);
    return newTokens;
}

async function exchangeCodeForToken(code, verifier, redirectUri) {
    const response = await fetch('https://api.dropboxapi.com/oauth2/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
            grant_type: 'authorization_code',
            code,
            code_verifier: verifier,
            client_id: DROPBOX_APP_KEY,
            redirect_uri: redirectUri
        })
    });

    if (!response.ok) {
        const err = await response.json().catch(() => ({}));
        throw new Error(err.error_description || 'Token exchange failed');
    }

    const data = await response.json();
    await saveTokens({
        access_token: data.access_token,
        refresh_token: data.refresh_token,
        expires_at: Date.now() + (data.expires_in || 14400) * 1000,
        account_id: data.account_id,
        uid: data.uid
    });

    localStorage.removeItem('gz_dropbox_pkce_verifier');
    localStorage.removeItem('gz_dropbox_pkce_state');
}

function waitForElectronOAuth(redirectUri, expectedState) {
    const ipcRenderer = window.require('electron').ipcRenderer;
    const portPromise = ipcRenderer.invoke('oauth-start-server');

    return portPromise.then(async port => {
        redirectUri = `http://127.0.0.1:${port}/oauth/callback`;

        const authUrl = new URL('https://www.dropbox.com/oauth2/authorize');
        authUrl.searchParams.set('client_id', DROPBOX_APP_KEY);
        authUrl.searchParams.set('response_type', 'code');
        authUrl.searchParams.set('code_challenge', localStorage.getItem('gz_dropbox_pkce_verifier'));
        authUrl.searchParams.set('code_challenge_method', 'plain');
        authUrl.searchParams.set('redirect_uri', redirectUri);
        authUrl.searchParams.set('token_access_type', 'offline');
        authUrl.searchParams.set('state', expectedState);

        const width = 500;
        const height = 600;
        const left = window.screenX + (window.outerWidth - width) / 2;
        const top = window.screenY + (window.outerHeight - height) / 2;
        const win = window.open(authUrl.toString(), 'dropbox-auth', `width=${width},height=${height},left=${left},top=${top}`);

        return new Promise((resolve) => {
            let resolved = false;
            let interval;
            const cleanup = () => clearInterval(interval);

            ipcRenderer.once('oauth-callback', (event, { code, state: returnedState, error }) => {
                if (resolved) return;
                resolved = true;
                cleanup();
                try { if (win && !win.closed) win.close(); } catch {}

                if (error || !code) { resolve(null); return; }
                if (returnedState !== expectedState) {
                    console.error('[dropboxAdapter] State mismatch');
                    resolve(null);
                    return;
                }
                resolve(code);
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
    });
}

function waitForWebOAuth(authUrl, expectedState) {
    return new Promise((resolve) => {
        const width = 500;
        const height = 600;
        const left = window.screenX + (window.outerWidth - width) / 2;
        const top = window.screenY + (window.outerHeight - height) / 2;
        const win = window.open(authUrl, 'dropbox-auth', `width=${width},height=${height},left=${left},top=${top}`);

        let resolved = false;
        let interval;

        const cleanup = () => {
            clearInterval(interval);
            window.removeEventListener('message', onMessage);
        };

        function onMessage(e) {
            if (resolved) return;
            if (e.data?.type === 'dropbox-oauth') {
                resolved = true;
                cleanup();
                const state = e.data.state;
                if (state !== expectedState) {
                    console.error('[dropboxAdapter] State mismatch');
                    resolve(null);
                    return;
                }
                resolve(e.data.code || null);
            }
        }

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

export async function connect() {
    if (!DROPBOX_APP_KEY) {
        throw new Error('Dropbox is not configured. Set VITE_DROPBOX_APP_KEY environment variable.');
    }

    const verifier = generateRandomString(64);
    const challenge = await sha256(verifier);
    const usePlain = !challenge;
    const redirectUri = getRedirectUri();
    const state = generateRandomString(16);

    localStorage.setItem('gz_dropbox_pkce_verifier', verifier);
    localStorage.setItem('gz_dropbox_pkce_state', state);

    const authUrl = new URL('https://www.dropbox.com/oauth2/authorize');
    authUrl.searchParams.set('client_id', DROPBOX_APP_KEY);
    authUrl.searchParams.set('response_type', 'code');
    authUrl.searchParams.set('code_challenge', usePlain ? verifier : challenge);
    authUrl.searchParams.set('code_challenge_method', usePlain ? 'plain' : 'S256');
    authUrl.searchParams.set('redirect_uri', redirectUri);
    authUrl.searchParams.set('token_access_type', 'offline');
    authUrl.searchParams.set('state', state);

    if (Capacitor.isNativePlatform()) {
        const listener = await App.addListener('appUrlOpen', async (data) => {
            try {
                const url = new URL(data.url);
                const code = url.searchParams.get('code');
                const returnedState = url.searchParams.get('state');

                if (!code) return;

                if (returnedState !== state) {
                    console.error('[dropboxAdapter] State mismatch');
                    return;
                }

                await exchangeCodeForToken(code, verifier, redirectUri);
            } catch (e) {
                console.error('[dropboxAdapter] OAuth callback error:', e);
            } finally {
                listener.remove();
                try { await Browser.close(); } catch {}
            }
        });

        await Browser.open({ url: authUrl.toString() });
    } else if (isElectron()) {
        const code = await waitForElectronOAuth(redirectUri, state);
        if (code) {
            await exchangeCodeForToken(code, verifier, redirectUri);
        } else {
            throw new Error('Authorization cancelled');
        }
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
            await fetch('https://api.dropboxapi.com/2/auth/token/revoke', {
                method: 'POST',
                headers: { 'Authorization': `Bearer ${tokens.access_token}` }
            });
        } catch {}
    }
    await clearTokens();
}

export async function isConnected() {
    const tokens = await getTokens();
    return !!tokens;
}
