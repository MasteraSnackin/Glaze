import { reactive } from 'vue';
import { db } from '@/utils/db.js';
import { applyBackgroundImage as _applyBg, applyUiFont as _applyUiFont, applyChatFont as _applyChatFont, updateThemeStyles as _updateStyles, hexToRgb } from '@/core/states/themeRenderer.js';
export { PRESET_COLORS, PRESET_UI_COLORS, DEFAULT_PRESET } from '@/core/states/themeConstants.js';
import { PRESET_COLORS, DEFAULT_PRESET } from '@/core/states/themeConstants.js';
import { presetFromState, presetFromStateWithBlobs, presetToExport, presetFromImport, newPresetObject, getPresetsFromDb, savePresetsToDb, getActivePresetId, setActivePresetId, saveBlobKeys, scheduleDbSave } from '@/core/states/themePersistence.js';
import { migrateLocalStorageToDb, migrateChatLayout, buildInitialPreset } from '@/core/states/themeMigration.js';

export const themeState = reactive({
    accentColor: '#7996ce',
    lastCustomColor: '#ff0000', // Default fallback
    hasBackgroundImage: false,
    bgOpacity: 0.85,
    bgBlur: 0,
    elementOpacity: 0.8,
    elementBlur: 12,
    uiColor: null,
    customFontName: null,
    activePresetId: null,
    chatLayout: 'default',
    userBubbleColor: null,
    charBubbleColor: null,
    userQuoteColor: null,
    charQuoteColor: null,
    userTextColor: null,
    charTextColor: null,
    userItalicColor: null,
    charItalicColor: null,
    uiFontSize: 15,
    uiLetterSpacing: 0,
    chatFontSize: 15,
    chatLetterSpacing: 0,
    chatFontName: null,
    uiFontMode: 'glaze',
    chatFontMode: 'ui',
    uiTextColor: null,
    uiTextGrayColor: null,
    borderWidth: 1,
    borderColor: null,
    borderOpacity: 0.1,
    noiseOpacity: 0.03,
    noiseIntensity: 0.8,
    bgNoiseOpacity: 0.03,
    bgNoiseIntensity: 0.4
});

let saveTimeout = null;
let isApplyingPreset = false;
let _uiFontDataUrl = null;
let _chatFontDataUrl = null;

function scheduleSave() {
    scheduleDbSave(themeState, isApplyingPreset, () => saveTimeout, (v) => { saveTimeout = v; });
}

async function saveStateToActivePreset() {
    if (!themeState.activePresetId) return;
    const presets = (await db.get('gz_theme_presets')) || [];
    const index = presets.findIndex(p => p.id === themeState.activePresetId);
    if (index === -1) return;

    if (themeState.activePresetId !== 'default') {
        const fullPreset = await presetFromStateWithBlobs(themeState);
        presets[index] = { ...presets[index], ...fullPreset };
    }

    await db.set('gz_theme_presets', presets);
}

export async function initTheme() {
    const presets = await getPresetsFromDb();
    const hadPresets = presets.length > 0;

    if (!presets.find(p => p.id === 'default')) {
        presets.unshift(DEFAULT_PRESET);
        await savePresetsToDb(presets);
    }

    if (hadPresets) {
        let activeId = await getActivePresetId();
        let activePreset = presets.find(p => p.id === activeId);
        if (!activePreset) {
            activePreset = presets[0];
            activeId = activePreset.id;
            await setActivePresetId(activeId);
        }
        themeState.activePresetId = activeId;
        await applyPreset(activePreset);
        return;
    }

    await migrateLocalStorageToDb();

    let savedAccent = await db.get('gz_theme_accent');
    if (savedAccent) {
        setAccentColor(savedAccent);
    }

    const savedLastCustom = await db.get('gz_theme_last_custom');
    if (savedLastCustom) {
        themeState.lastCustomColor = savedLastCustom;
    } else if (!PRESET_COLORS.some(c => c.toLowerCase() === themeState.accentColor.toLowerCase())) {
        themeState.lastCustomColor = themeState.accentColor;
    }

    let savedOpacity = await db.get('gz_theme_opacity');
    if (savedOpacity !== undefined && savedOpacity !== null) themeState.bgOpacity = parseFloat(savedOpacity);

    let savedBlur = await db.get('gz_theme_blur');
    if (savedBlur !== undefined && savedBlur !== null) themeState.bgBlur = parseInt(savedBlur);

    let savedElemOpacity = await db.get('gz_theme_elem_opacity');
    if (savedElemOpacity !== undefined && savedElemOpacity !== null) themeState.elementOpacity = parseFloat(savedElemOpacity);

    let savedElemBlur = await db.get('gz_theme_elem_blur');
    if (savedElemBlur !== undefined && savedElemBlur !== null) themeState.elementBlur = parseInt(savedElemBlur);

    const savedUiColor = await db.get('gz_theme_ui_color');
    if (savedUiColor) {
        setUiColor(savedUiColor);
    }

    const migratedLayout = await migrateChatLayout();
    if (migratedLayout) {
        themeState.chatLayout = migratedLayout;
    }

    const savedBg = await db.get('gz_theme_bg');
    if (savedBg) {
        applyBackgroundImage(savedBg);
    }

    const savedFont = await db.get('gz_theme_font');
    const savedFontName = await db.get('gz_theme_font_name');
    if (savedFont) {
        _uiFontDataUrl = savedFont;
        themeState.customFontName = savedFontName;
        themeState.uiFontMode = 'custom';
    }
    applyUiFont();
    updateThemeStyles();

    const newPreset = await buildInitialPreset(themeState);
    await savePresetsToDb([newPreset]);
    await setActivePresetId(newPreset.id);
    themeState.activePresetId = newPreset.id;
}

export function setAccentColor(color) {
    themeState.accentColor = color;
    db.set('gz_theme_accent', color).catch(e => console.error('Failed to save accent', e));
    document.documentElement.style.setProperty('--vk-blue', color);
    const rgb = hexToRgb(color);
    document.documentElement.style.setProperty('--vk-blue-rgb', rgb);

    // If the color is not a preset, save it as the last custom color
    if (!PRESET_COLORS.some(c => c.toLowerCase() === color.toLowerCase())) {
        themeState.lastCustomColor = color;
        db.set('gz_theme_last_custom', color).catch(e => console.error('Failed to save last custom', e));
    }
    scheduleSave();
}



export function setUiColor(color) {
    themeState.uiColor = color;
    if (color) {
        db.set('gz_theme_ui_color', color).catch(e => console.error('Failed to save ui color', e));
    } else {
        db.set('gz_theme_ui_color', null).catch(e => console.error('Failed to delete ui color', e));
    }
    updateThemeStyles();
    scheduleSave();
}

export function setBgOpacity(val) {
    themeState.bgOpacity = val;
    db.set('gz_theme_opacity', val).catch(e => console.error('Failed to save opacity', e));
    updateThemeStyles();
    scheduleSave();
}

export function setBgBlur(val) {
    themeState.bgBlur = val;
    db.set('gz_theme_blur', val).catch(e => console.error('Failed to save blur', e));
    updateThemeStyles();
    scheduleSave();
}

export function setElementOpacity(val) {
    themeState.elementOpacity = val;
    db.set('gz_theme_elem_opacity', val).catch(e => console.error('Failed to save elem opacity', e));
    localStorage.setItem('gz_theme_elem_opacity', val);
    updateThemeStyles();
    scheduleSave();
}

export function setElementBlur(val) {
    themeState.elementBlur = val;
    db.set('gz_theme_elem_blur', val).catch(e => console.error('Failed to save elem blur', e));
    localStorage.setItem('gz_theme_elem_blur', val);
    updateThemeStyles();
    scheduleSave();
}

export async function setBackgroundImage(file) {
    if (!file) {
        try {
            await db.set('gz_theme_bg', null);
        } catch (e) {
            console.error("Failed to delete background from db", e);
        }
        applyBackgroundImage(null);
        scheduleSave();
        return;
    }

    const reader = new FileReader();
    reader.onload = async (e) => {
        const result = e.target.result;
        try {
            await db.set('gz_theme_bg', result);
        } catch (e) {
            console.error("Failed to save background to db", e);
        }
        applyBackgroundImage(result);
        scheduleSave();
    };
    reader.readAsDataURL(file);
}

function applyBackgroundImage(dataUrl) {
    _applyBg(themeState, dataUrl);
}

export async function setCustomFont(file) {
    if (!file) {
        _uiFontDataUrl = null;
        try {
            await db.set('gz_theme_font', null);
            await db.set('gz_theme_font_name', null);
        } catch (e) {
            console.error("Failed to delete font from db", e);
        }
        themeState.customFontName = null;
        if (themeState.uiFontMode === 'custom') {
            themeState.uiFontMode = 'glaze';
        }
        applyUiFont();
        scheduleSave();
        return;
    }

    const reader = new FileReader();
    reader.onload = async (e) => {
        _uiFontDataUrl = e.target.result;
        try {
            await db.set('gz_theme_font', _uiFontDataUrl);
            await db.set('gz_theme_font_name', file.name);
        } catch (e) {
            console.error("Failed to save font to db", e);
        }
        themeState.customFontName = file.name;
        themeState.uiFontMode = 'custom';
        applyUiFont();
        scheduleSave();
    };
    reader.readAsDataURL(file);
}

export function setUiFontMode(mode) {
    themeState.uiFontMode = mode;
    if (mode !== 'custom') {
        themeState.customFontName = null;
    }
    applyUiFont();
    scheduleSave();
}

export function setChatFontMode(mode) {
    themeState.chatFontMode = mode;
    if (mode !== 'custom') {
        themeState.chatFontName = null;
    }
    applyChatFont();
    scheduleSave();
}

const SYSTEM_FONT_STACK = '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif';

function applyUiFont() {
    _applyUiFont(themeState, _uiFontDataUrl);
}

function applyChatFont() {
    _applyChatFont(themeState, _chatFontDataUrl);
}

export async function createPreset(name) {
    const presets = await getPresetsFromDb();
    const newPreset = newPresetObject(name, themeState.chatLayout);
    presets.push(newPreset);
    await savePresetsToDb(presets);
    await switchPreset(newPreset.id);
    return presets;
}

export async function getPresets() {
    return getPresetsFromDb();
}

export async function deletePreset(id) {
    if (id === 'default') return getPresetsFromDb();
    let presets = await getPresetsFromDb();
    presets = presets.filter(p => p.id !== id);
    await savePresetsToDb(presets);

    if (themeState.activePresetId === id) {
        const next = presets[0];
        if (next) {
            await switchPreset(next.id);
        }
    }
    return presets;
}

export async function updatePresetMeta(id, name, author) {
    const presets = await getPresetsFromDb();
    const index = presets.findIndex(p => p.id === id);
    if (index !== -1) {
        if (name !== undefined) presets[index].name = name;
        if (author !== undefined) presets[index].author = author;
        await savePresetsToDb(presets);
        return presets;
    }
    return presets;
}

export async function switchPreset(id) {
    if (themeState.activePresetId && themeState.activePresetId !== id) {
        if (saveTimeout) {
            clearTimeout(saveTimeout);
            saveTimeout = null;
        }
        await saveStateToActivePreset();
    }

    const presets = await getPresetsFromDb();
    const preset = presets.find(p => p.id === id);
    if (preset) {
        themeState.activePresetId = id;
        await setActivePresetId(id);
        await applyPreset(preset);
    }
}

export async function applyPreset(preset) {
    isApplyingPreset = true;
    try {
        localStorage.setItem('gz_theme', 'dark');
        setAccentColor(preset.accentColor);
        setBgOpacity(preset.bgOpacity);
        setBgBlur(preset.bgBlur);
        setElementOpacity(preset.elementOpacity !== undefined ? preset.elementOpacity : 0.8);
        setElementBlur(preset.elementBlur !== undefined ? preset.elementBlur : 12);
        setUiColor(preset.uiColor || null);
        setChatLayout(preset.chatLayout || 'default');
        setUserBubbleColor(preset.userBubbleColor || null);
        setCharBubbleColor(preset.charBubbleColor || null);
        setUserQuoteColor(preset.userQuoteColor || null);
        setCharQuoteColor(preset.charQuoteColor || null);
        setUserTextColor(preset.userTextColor || null);
        setCharTextColor(preset.charTextColor || null);
        setUserItalicColor(preset.userItalicColor || null);
        setCharItalicColor(preset.charItalicColor || null);
        setUiTextColor(preset.uiTextColor || null);
        setUiTextGrayColor(preset.uiTextGrayColor || null);
        setUiFontSize(preset.uiFontSize !== undefined ? preset.uiFontSize : 'system');
        setUiLetterSpacing(preset.uiLetterSpacing !== undefined ? preset.uiLetterSpacing : 0);
        setChatFontSize(preset.chatFontSize !== undefined ? preset.chatFontSize : 'system');
        setChatLetterSpacing(preset.chatLetterSpacing !== undefined ? preset.chatLetterSpacing : 0);
        setBorderWidth(preset.borderWidth !== undefined ? preset.borderWidth : 1);
        setBorderColor(preset.borderColor || null);
        setBorderOpacity(preset.borderOpacity !== undefined ? preset.borderOpacity : 0.1);
        setNoiseOpacity(preset.noiseOpacity !== undefined ? preset.noiseOpacity : 0.03);
        setNoiseIntensity(preset.noiseIntensity !== undefined ? preset.noiseIntensity : 0.8);
        setBgNoiseOpacity(preset.bgNoiseOpacity !== undefined ? preset.bgNoiseOpacity : 0.03);
        setBgNoiseIntensity(preset.bgNoiseIntensity !== undefined ? preset.bgNoiseIntensity : 0.4);

        // UI font mode (backward compat: infer from customFont if no mode saved)
        const uiFontMode = preset.uiFontMode || (preset.customFont ? 'custom' : 'glaze');
        themeState.uiFontMode = uiFontMode;
        if (preset.customFont) {
            _uiFontDataUrl = preset.customFont;
            themeState.customFontName = preset.customFontName;
            try {
                await saveBlobKeys(preset.customFont, preset.customFontName);
            } catch (e) {
                console.error('Failed to save font preset', e);
            }
        } else {
            _uiFontDataUrl = null;
            themeState.customFontName = null;
            try {
                await saveBlobKeys(null, null);
            } catch (e) {
                console.error('Failed to delete font preset', e);
            }
        }
        applyUiFont();

        if (preset.bgImage) {
            try {
                await saveBlobKeys(undefined, undefined, undefined, undefined, preset.bgImage);
            } catch (e) {
                console.error('Failed to save bg preset', e);
            }
            applyBackgroundImage(preset.bgImage);
        } else {
            try {
                await saveBlobKeys(undefined, undefined, undefined, undefined, null);
            } catch (e) {
                console.error('Failed to delete bg preset', e);
            }
            applyBackgroundImage(null);
        }

        // Chat font mode (backward compat: infer from chatFont if no mode saved)
        const chatFontMode = preset.chatFontMode || (preset.chatFont ? 'custom' : 'ui');
        themeState.chatFontMode = chatFontMode;
        if (preset.chatFont) {
            _chatFontDataUrl = preset.chatFont;
            themeState.chatFontName = preset.chatFontName;
            try {
                await saveBlobKeys(undefined, undefined, preset.chatFont, preset.chatFontName);
            } catch (e) {
                console.error('Failed to save chat font preset', e);
            }
        } else {
            _chatFontDataUrl = null;
            themeState.chatFontName = null;
            try {
                await saveBlobKeys(undefined, undefined, null, null);
            } catch (e) {
                console.error('Failed to delete chat font preset', e);
            }
        }
        applyChatFont();
    } finally {
        isApplyingPreset = false;
    }
}

function updateThemeStyles() {
    _updateStyles(themeState);
}

export function setChatLayout(val) {
    themeState.chatLayout = val;
    scheduleSave();
}

export function setUserBubbleColor(val) {
    themeState.userBubbleColor = val;
    updateThemeStyles();
    scheduleSave();
}

export function setCharBubbleColor(val) {
    themeState.charBubbleColor = val;
    updateThemeStyles();
    scheduleSave();
}

export function setUserQuoteColor(val) {
    themeState.userQuoteColor = val;
    updateThemeStyles();
    scheduleSave();
}

export function setCharQuoteColor(val) {
    themeState.charQuoteColor = val;
    updateThemeStyles();
    scheduleSave();
}

export function setUserTextColor(val) {
    themeState.userTextColor = val;
    updateThemeStyles();
    scheduleSave();
}

export function setCharTextColor(val) {
    themeState.charTextColor = val;
    updateThemeStyles();
    scheduleSave();
}

export function setUserItalicColor(val) {
    themeState.userItalicColor = val;
    updateThemeStyles();
    scheduleSave();
}

export function setUiTextColor(val) {
    themeState.uiTextColor = val;
    updateThemeStyles();
    scheduleSave();
}

export function setUiTextGrayColor(val) {
    themeState.uiTextGrayColor = val;
    updateThemeStyles();
    scheduleSave();
}

export function setCharItalicColor(val) {
    themeState.charItalicColor = val;
    updateThemeStyles();
    scheduleSave();
}

export function setUiFontSize(val) {
    themeState.uiFontSize = val;
    updateThemeStyles();
    scheduleSave();
}

export function setUiLetterSpacing(val) {
    themeState.uiLetterSpacing = val;
    updateThemeStyles();
    scheduleSave();
}

export function setChatFontSize(val) {
    themeState.chatFontSize = val;
    updateThemeStyles();
    scheduleSave();
}

export function setChatLetterSpacing(val) {
    themeState.chatLetterSpacing = val;
    updateThemeStyles();
    scheduleSave();
}

export async function setChatFont(file) {
    if (!file) {
        _chatFontDataUrl = null;
        try {
            await db.set('gz_theme_chat_font', null);
            await db.set('gz_theme_chat_font_name', null);
        } catch (e) {
            console.error('Failed to delete chat font from db', e);
        }
        themeState.chatFontName = null;
        if (themeState.chatFontMode === 'custom') {
            themeState.chatFontMode = 'ui';
        }
        applyChatFont();
        scheduleSave();
        return;
    }

    const reader = new FileReader();
    reader.onload = async (e) => {
        _chatFontDataUrl = e.target.result;
        try {
            await db.set('gz_theme_chat_font', _chatFontDataUrl);
            await db.set('gz_theme_chat_font_name', file.name);
        } catch (e) {
            console.error('Failed to save chat font to db', e);
        }
        themeState.chatFontName = file.name;
        themeState.chatFontMode = 'custom';
        applyChatFont();
        scheduleSave();
    };
    reader.readAsDataURL(file);
}

export function setBorderWidth(val) {
    themeState.borderWidth = val;
    updateThemeStyles();
    scheduleSave();
}

export function setBorderColor(val) {
    themeState.borderColor = val;
    updateThemeStyles();
    scheduleSave();
}

export function setBorderOpacity(val) {
    themeState.borderOpacity = val;
    updateThemeStyles();
    scheduleSave();
}

export function setNoiseOpacity(val) {
    themeState.noiseOpacity = val;
    updateThemeStyles();
    scheduleSave();
}

export function setNoiseIntensity(val) {
    themeState.noiseIntensity = val;
    updateThemeStyles();
    scheduleSave();
}

export function setBgNoiseOpacity(val) {
    themeState.bgNoiseOpacity = val;
    updateThemeStyles();
    scheduleSave();
}

export function setBgNoiseIntensity(val) {
    themeState.bgNoiseIntensity = val;
    updateThemeStyles();
    scheduleSave();
}

export async function exportThemePreset(presetId) {
    const presets = await getPresetsFromDb();
    const preset = presets.find(p => p.id === presetId);
    if (!preset) return null;
    return presetToExport(preset);
}

export async function importThemePreset(jsonData, defaultName) {
    const newPreset = presetFromImport(jsonData, defaultName);
    const presets = await getPresetsFromDb();
    presets.push(newPreset);
    await savePresetsToDb(presets);
    await switchPreset(newPreset.id);
    return newPreset;
}
