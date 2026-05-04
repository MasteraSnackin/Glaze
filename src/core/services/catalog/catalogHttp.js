/**
 * HTTP abstraction for catalog requests.
 * - Native (Android/iOS): CapacitorHttp — bypasses CORS, arbitrary headers allowed.
 * - Electron: direct fetch — webSecurity:false disables CORS, no proxy needed.
 * - Web dev: Vite server proxy at /dc-proxy → datacat.run (handles decompression in Node.js).
 */
import { Capacitor, CapacitorHttp } from '@capacitor/core';

const TIMEOUT = 20000;

function isElectron() {
    return typeof navigator !== 'undefined' && navigator.userAgent.includes('Electron');
}

function resolveUrl(url, useProxy = true) {
    if (Capacitor.isNativePlatform() || !useProxy || isElectron()) return url;
    // Web dev: route through Vite proxy which handles CORS and decompression in Node.js
    return url.replace('https://datacat.run', '/dc-proxy');
}

/**
 * GET request with custom headers.
 * @param {string} url
 * @param {Record<string, string>} headers
 * @returns {Promise<any>} Parsed JSON response data
 */
export async function catalogGet(url, headers = {}, useProxy = true) {
    if (Capacitor.isNativePlatform()) {
        const response = await CapacitorHttp.get({
            url,
            headers,
            responseType: 'text',
            connectTimeout: TIMEOUT,
            readTimeout: TIMEOUT
        });
        if (response.status >= 400) {
            throw Object.assign(new Error(`HTTP ${response.status}`), { status: response.status, data: response.data });
        }
        return parseJson(response.data, url);
    }

    const res = await fetch(resolveUrl(url, useProxy), { headers });
    if (!res.ok) {
        const text = await res.text().catch(() => '');
        throw Object.assign(new Error(`HTTP ${res.status}`), { status: res.status, data: text });
    }
    const text = await res.text();
    return parseJson(text, url);
}

/**
 * GET request that returns raw text (for HTML scraping).
 */
export async function catalogGetText(url, headers = {}, useProxy = true) {
    if (Capacitor.isNativePlatform()) {
        const response = await CapacitorHttp.get({
            url,
            headers,
            responseType: 'text',
            connectTimeout: TIMEOUT,
            readTimeout: TIMEOUT
        });
        if (response.status >= 400) {
            throw Object.assign(new Error(`HTTP ${response.status}`), { status: response.status });
        }
        return response.data;
    }

    const res = await fetch(resolveUrl(url, useProxy), { headers });
    if (!res.ok) throw Object.assign(new Error(`HTTP ${res.status}`), { status: res.status });
    return res.text();
}

/**
 * POST request with JSON body and custom headers.
 * @param {string} url
 * @param {object} body
 * @param {Record<string, string>} headers
 * @returns {Promise<any>} Parsed JSON response data
 */
export async function catalogPost(url, body, headers = {}, useProxy = true) {
    const allHeaders = { 'Content-Type': 'application/json', ...headers };

    if (Capacitor.isNativePlatform()) {
        const response = await CapacitorHttp.post({
            url,
            headers: allHeaders,
            data: body,
            responseType: 'text',
            connectTimeout: TIMEOUT,
            readTimeout: TIMEOUT
        });
        if (response.status >= 400) {
            throw Object.assign(new Error(`HTTP ${response.status}`), { status: response.status, data: response.data });
        }
        return parseJson(response.data, url);
    }

    const res = await fetch(resolveUrl(url, useProxy), {
        method: 'POST',
        headers: allHeaders,
        body: JSON.stringify(body)
    });
    if (!res.ok) {
        const text = await res.text().catch(() => '');
        throw Object.assign(new Error(`HTTP ${res.status}`), { status: res.status, data: text });
    }
    const text = await res.text();
    return parseJson(text, url);
}

function parseJson(text, url) {
    if (typeof text === 'object' && text !== null) return text;
    try {
        return JSON.parse(text);
    } catch (e) {
        const preview = typeof text === 'string' ? text.slice(0, 120) : String(text);
        throw new Error(`Server returned invalid JSON from ${new URL(url).pathname}: ${preview}`);
    }
}
