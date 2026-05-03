import { db } from '@/utils/db.js';
import { PRESET_COLORS } from '@/core/states/themeConstants.js';

export async function migrateLocalStorageToDb() {
    const migrations = [
        { dbKey: 'gz_theme_accent', lsKey: 'gz_theme_accent', parse: v => v },
        { dbKey: 'gz_theme_opacity', lsKey: 'gz_theme_opacity', parse: v => parseFloat(v) },
        { dbKey: 'gz_theme_blur', lsKey: 'gz_theme_blur', parse: v => parseInt(v) },
        { dbKey: 'gz_theme_elem_opacity', lsKey: 'gz_theme_elem_opacity', parse: v => parseFloat(v) },
        { dbKey: 'gz_theme_elem_blur', lsKey: 'gz_theme_elem_blur', parse: v => parseInt(v) },
    ];

    for (const { dbKey, lsKey, parse } of migrations) {
        const dbVal = await db.get(dbKey);
        if (dbVal === undefined || dbVal === null) {
            const lsVal = localStorage.getItem(lsKey);
            if (lsVal) {
                await db.set(dbKey, parse(lsVal));
            }
        }
    }
}

export async function migrateChatLayout() {
    const savedLayout = localStorage.getItem('gz_chat_layout');
    if (savedLayout) {
        localStorage.removeItem('gz_chat_layout');
        return savedLayout;
    }
    return null;
}

export async function buildInitialPreset(state) {
    const newPreset = {
        id: Date.now().toString(),
        name: 'My Theme',
        author: '',
    };

    const presetFields = [
        'accentColor', 'bgOpacity', 'bgBlur', 'elementOpacity', 'elementBlur',
        'uiColor', 'chatLayout', 'userBubbleColor', 'charBubbleColor',
        'userQuoteColor', 'charQuoteColor', 'userTextColor', 'charTextColor',
        'userItalicColor', 'charItalicColor', 'uiFontSize', 'uiLetterSpacing',
        'chatFontSize', 'chatLetterSpacing', 'uiFontMode', 'chatFontMode',
        'uiTextColor', 'uiTextGrayColor', 'borderWidth', 'borderColor',
        'borderOpacity', 'noiseOpacity', 'noiseIntensity', 'bgNoiseOpacity',
        'bgNoiseIntensity'
    ];
    for (const key of presetFields) {
        newPreset[key] = state[key];
    }

    newPreset.bgImage = state.hasBackgroundImage ? await db.get('gz_theme_bg') : null;
    newPreset.customFont = state.customFontName ? await db.get('gz_theme_font') : null;
    newPreset.customFontName = state.customFontName;
    newPreset.chatFont = null;
    newPreset.chatFontName = null;

    return newPreset;
}
