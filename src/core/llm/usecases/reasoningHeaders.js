import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';

export function buildReasoningHeaders() {
    const t = (key) => translations[currentLang.value]?.[key] || key;
    return {
        headerModel: `<span style="color: var(--vk-blue); font-weight: 700; font-size: 0.85em; text-transform: uppercase; letter-spacing: 0.5px;">${t('reasoning_model')}</span>`,
        headerInline: `<span style="color: var(--vk-blue); font-weight: 700; font-size: 0.85em; text-transform: uppercase; letter-spacing: 0.5px;">${t('reasoning_inline')}</span>`
    };
}

export function getNotificationBody() {
    return translations[currentLang.value]?.model_typing || 'Generating...';
}
