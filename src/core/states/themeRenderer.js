const SYSTEM_FONT_STACK = '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif';

export function hexToRgb(hex) {
    const result = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(hex);
    return result ? `${parseInt(result[1], 16)}, ${parseInt(result[2], 16)}, ${parseInt(result[3], 16)}` : '255, 255, 255';
}

export function applyBackgroundImage(state, dataUrl) {
    let bgEl = document.getElementById('app-background-layer');

    if (!bgEl) {
        bgEl = document.createElement('div');
        bgEl.id = 'app-background-layer';
        Object.assign(bgEl.style, {
            position: 'fixed', top: '-50px', left: '-50px', width: 'calc(100% + 100px)', height: 'calc(100% + 100px)',
            zIndex: '-1', backgroundSize: 'cover', backgroundPosition: 'center',
            pointerEvents: 'none',
            transition: 'filter 0.3s ease'
        });

        const noiseLayer = document.createElement('div');
        noiseLayer.className = 'bg-noise-overlay';
        Object.assign(noiseLayer.style, {
            position: 'absolute', top: 0, left: 0, width: '100%', height: '100%',
            pointerEvents: 'none',
            zIndex: 1
        });
        bgEl.appendChild(noiseLayer);

        const overlay = document.createElement('div');
        Object.assign(overlay.style, {
            position: 'absolute', top: 0, left: 0, width: '100%', height: '100%',
            backgroundColor: '#000',
            opacity: 'var(--theme-bg-opacity, 0)',
            transition: 'opacity 0.3s ease'
        });
        bgEl.appendChild(overlay);

        document.body.appendChild(bgEl);
    }

    if (dataUrl) {
        state.hasBackgroundImage = true;
        bgEl.style.backgroundImage = `url('${dataUrl}')`;
        document.body.classList.add('has-custom-background');
        updateThemeStyles(state);
    } else {
        state.hasBackgroundImage = false;
        bgEl.style.backgroundImage = '';
        document.body.classList.remove('has-custom-background');
        const styleEl = document.getElementById('theme-overrides');
        if (styleEl) styleEl.remove();
    }
}

export function applyUiFont(state, uiFontDataUrl) {
    let styleEl = document.getElementById('theme-custom-font');
    const mode = state.uiFontMode;

    if (mode === 'system') {
        if (!styleEl) {
            styleEl = document.createElement('style');
            styleEl.id = 'theme-custom-font';
            document.head.appendChild(styleEl);
        }
        styleEl.textContent = `
            body, button, input, textarea, select, .menu-text, .section-header, .item-title, .item-subtitle {
                font-family: ${SYSTEM_FONT_STACK} !important;
            }
        `;
    } else if (mode === 'custom' && uiFontDataUrl) {
        if (!styleEl) {
            styleEl = document.createElement('style');
            styleEl.id = 'theme-custom-font';
            document.head.appendChild(styleEl);
        }
        styleEl.textContent = `
            @font-face {
                font-family: 'GlazeCustomFont';
                src: url('${uiFontDataUrl}');
                font-display: swap;
            }
            body, button, input, textarea, select, .menu-text, .section-header, .item-title, .item-subtitle {
                font-family: 'GlazeCustomFont', 'Inter', ${SYSTEM_FONT_STACK} !important;
                font-weight: 450;
            }
        `;
    } else {
        if (styleEl) styleEl.remove();
    }

    if (state.chatFontMode === 'ui') {
        applyChatFont(state, null);
    }
}

export function applyChatFont(state, chatFontDataUrl) {
    let styleEl = document.getElementById('theme-chat-font');
    const mode = state.chatFontMode;

    if (mode === 'system') {
        if (!styleEl) {
            styleEl = document.createElement('style');
            styleEl.id = 'theme-chat-font';
            document.head.appendChild(styleEl);
        }
        styleEl.textContent = `.msg-body { font-family: ${SYSTEM_FONT_STACK} !important; }`;
    } else if (mode === 'glaze') {
        if (!styleEl) {
            styleEl = document.createElement('style');
            styleEl.id = 'theme-chat-font';
            document.head.appendChild(styleEl);
        }
        styleEl.textContent = `.msg-body { font-family: 'Inter', ${SYSTEM_FONT_STACK} !important; }`;
    } else if (mode === 'custom' && chatFontDataUrl) {
        if (!styleEl) {
            styleEl = document.createElement('style');
            styleEl.id = 'theme-chat-font';
            document.head.appendChild(styleEl);
        }
        styleEl.textContent = `
            @font-face {
                font-family: 'GlazeChatFont';
                src: url('${chatFontDataUrl}');
                font-display: swap;
            }
            .msg-body {
                font-family: 'GlazeChatFont', 'Inter', ${SYSTEM_FONT_STACK} !important;
                font-weight: 450;
            }
        `;
    } else {
        if (styleEl) styleEl.remove();
    }
}

export function updateThemeStyles(state) {
    document.documentElement.style.setProperty('--theme-bg-opacity', state.bgOpacity);
    document.documentElement.style.setProperty('--theme-bg-blur', state.bgBlur + 'px');
    document.documentElement.style.setProperty('--element-opacity', state.elementOpacity);
    document.documentElement.style.setProperty('--element-blur', state.elementBlur + 'px');

    const bgEl = document.getElementById('app-background-layer');
    if (bgEl) {
        bgEl.style.filter = `blur(${state.bgBlur}px)`;
    }

    if (state.uiColor) {
        const rgb = hexToRgb(state.uiColor);
        document.documentElement.style.setProperty('--theme-ui-color-rgb', rgb);
    } else {
        document.documentElement.style.removeProperty('--theme-ui-color-rgb');
    }

    if (state.userBubbleColor) {
        document.documentElement.style.setProperty('--user-bubble-color', state.userBubbleColor);
        document.documentElement.style.setProperty('--user-bubble-color-rgb', hexToRgb(state.userBubbleColor));
    } else {
        document.documentElement.style.removeProperty('--user-bubble-color');
        document.documentElement.style.removeProperty('--user-bubble-color-rgb');
    }

    if (state.charBubbleColor) {
        document.documentElement.style.setProperty('--char-bubble-color', state.charBubbleColor);
        document.documentElement.style.setProperty('--char-bubble-color-rgb', hexToRgb(state.charBubbleColor));
    } else {
        document.documentElement.style.removeProperty('--char-bubble-color');
        document.documentElement.style.removeProperty('--char-bubble-color-rgb');
    }

    if (state.userQuoteColor) {
        document.documentElement.style.setProperty('--user-quote-color', state.userQuoteColor);
    } else {
        document.documentElement.style.removeProperty('--user-quote-color');
    }

    if (state.charQuoteColor) {
        document.documentElement.style.setProperty('--char-quote-color', state.charQuoteColor);
    } else {
        document.documentElement.style.removeProperty('--char-quote-color');
    }

    if (state.userTextColor) {
        document.documentElement.style.setProperty('--user-text-color', state.userTextColor);
    } else {
        document.documentElement.style.removeProperty('--user-text-color');
    }

    if (state.charTextColor) {
        document.documentElement.style.setProperty('--char-text-color', state.charTextColor);
    } else {
        document.documentElement.style.removeProperty('--char-text-color');
    }

    if (state.userItalicColor) {
        document.documentElement.style.setProperty('--user-italic-color', state.userItalicColor);
    } else {
        document.documentElement.style.removeProperty('--user-italic-color');
    }

    if (state.charItalicColor) {
        document.documentElement.style.setProperty('--char-italic-color', state.charItalicColor);
    } else {
        document.documentElement.style.removeProperty('--char-italic-color');
    }

    if (state.uiTextColor) {
        document.documentElement.style.setProperty('--text-black', state.uiTextColor);
        document.documentElement.style.setProperty('--text-dark-gray', state.uiTextColor);
    } else {
        document.documentElement.style.removeProperty('--text-black');
        document.documentElement.style.removeProperty('--text-dark-gray');
    }

    if (state.uiTextGrayColor) {
        document.documentElement.style.setProperty('--text-gray', state.uiTextGrayColor);
    } else {
        document.documentElement.style.removeProperty('--text-gray');
    }

    const uiStyle = document.getElementById('theme-ui-overrides');
    if (uiStyle) uiStyle.remove();

    if (state.uiFontSize === 'system') {
        document.documentElement.style.removeProperty('--ui-font-size');
    } else {
        document.documentElement.style.setProperty('--ui-font-size', state.uiFontSize + 'px');
    }

    if (state.chatFontSize === 'system') {
        document.documentElement.style.removeProperty('--chat-font-size');
    } else {
        document.documentElement.style.setProperty('--chat-font-size', state.chatFontSize + 'px');
    }

    document.documentElement.style.setProperty('--ui-letter-spacing', state.uiLetterSpacing + 'px');
    document.documentElement.style.setProperty('--chat-letter-spacing', state.chatLetterSpacing + 'px');

    document.documentElement.style.setProperty('--border-width', state.borderWidth + 'px');
    document.documentElement.style.setProperty('--border-opacity', state.borderOpacity);
    if (state.borderColor) {
        const brgb = hexToRgb(state.borderColor);
        document.documentElement.style.setProperty('--border-color', `rgba(${brgb}, ${state.borderOpacity})`);
        document.documentElement.style.setProperty('--border-color-solid', state.borderColor);
    } else {
        const defaultRgb = '255, 255, 255';
        document.documentElement.style.setProperty('--border-color', `rgba(${defaultRgb}, ${state.borderOpacity})`);
        document.documentElement.style.setProperty('--border-color-solid', `rgb(${defaultRgb})`);
    }

    let noiseStyle = document.getElementById('theme-noise-style');
    if (!noiseStyle) {
        noiseStyle = document.createElement('style');
        noiseStyle.id = 'theme-noise-style';
        document.head.appendChild(noiseStyle);
    }
    const noiseOpacity = state.noiseOpacity;
    const noiseFreq = state.noiseIntensity;
    const noiseSvg = `url("data:image/svg+xml,%3Csvg width='200' height='200' viewBox='0 0 200 200' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noiseFilter'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='${noiseFreq}' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noiseFilter)' opacity='${noiseOpacity}'/%3E%3C/svg%3E")`;
    noiseStyle.textContent = `
        .menu-group,
        .preset-selector,
        .conn-badge  {
            background-image: ${noiseSvg} !important;
        }

        .bg-noise-overlay {
            background-image: url("data:image/svg+xml,%3Csvg width='200' height='200' viewBox='0 0 200 200' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='bgNoiseFilter'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='${state.bgNoiseIntensity}' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23bgNoiseFilter)' opacity='${state.bgNoiseOpacity}'/%3E%3C/svg%3E") !important;
        }
    `;
}
