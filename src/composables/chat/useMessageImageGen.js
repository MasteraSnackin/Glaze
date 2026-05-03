import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { saveFile } from '@/core/services/fileSaver.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { publishAppEvent } from '@/core/events/eventHub.js';

const t = (key) => translations[currentLang.value]?.[key] || key;

function parseIIGInstruction(el) {
    if (!el?.dataset?.iigInstruction) return null;
    try {
        return JSON.parse(el.dataset.iigInstruction
            .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&'));
    } catch { return null; }
}

function openImage(src, instruction = null) {
    if (!src) return;
    publishAppEvent(APP_EVENTS.nav.triggerOpenImage, { src, name: 'Attachment', description: instruction?.prompt || '' });
}

export function useMessageImageGen(emit) {
    const handleContentClick = (e, _layoutMode, _isSelectionMode) => {
        const path = e.composedPath();

        const loadingBlock = path.find(el => el?.classList?.contains('imggen-loading'));
        if (loadingBlock) {
            e.stopPropagation();
            loadingBlock.classList.toggle('expanded');
            return;
        }

        const janitorOptionsBtn = path.find(el => el?.classList?.contains('janitor-options-btn'));
        if (janitorOptionsBtn) {
            e.stopPropagation();
            const wrapper = path.find(el => el?.classList?.contains('janitor-img-wrapper'));
            const img = wrapper?.querySelector?.('img.janitor-img');
            if (!img) return;
            const src = img.src;
            showBottomSheet({
                items: [
                    {
                        label: t('imggen_expand_image') || 'Expand image',
                        hint: t('expand_image_hint') || 'Открыть картинку в полноэкранном режиме',
                        icon: '<svg viewBox="0 0 24 24"><path d="M12 4.5C7 4.5 2.73 7.61 1 12c1.73 4.39 6 7.5 11 7.5s9.27-3.11 11-7.5c-1.73-4.39-6-7.5-11-7.5zm0 12.5c-2.76 0-5-2.24-5-5s2.24-5 5-5 5 2.24 5 5-2.24 5-5 5zm0-8c-1.66 0-3 1.34-3 3s1.34 3 3 3 3-1.34 3-3-1.34-3-3-3z"/></svg>',
                        onClick: () => { closeBottomSheet(); openImage(src); }
                    },
                    {
                        label: t('action_save_image') || 'Save image',
                        hint: t('imggen_save_hint') || 'Сохранить картинку на устройство',
                        icon: '<svg viewBox="0 0 24 24"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"/></svg>',
                        onClick: async () => {
                            closeBottomSheet();
                            try {
                                const response = await fetch(src);
                                const blob = await response.blob();
                                await saveFile(`Image_${Date.now()}.png`, blob, 'image/png');
                            } catch (err) {
                                console.error('Failed to save image:', err);
                            }
                        }
                    },
                ]
            });
            return;
        }

        const optionsBtn = path.find(el => el?.classList?.contains('imggen-options-btn'));
        if (optionsBtn) {
            e.stopPropagation();
            const wrapper = path.find(el => el?.classList?.contains('imggen-result-wrapper'));
            const img = wrapper?.querySelector?.('img.imggen-result');
            if (!img) return;
            const instr = parseIIGInstruction(img);
            const id = img.dataset?.iigId;
            const src = img.src;
            showBottomSheet({
                items: [
                    {
                        label: t('imggen_expand_image') || 'Expand image',
                        hint: t('imggen_expand_image_hint') || 'Открыть картинку в полноэкранном режиме и посмотреть промпт',
                        icon: '<svg viewBox="0 0 24 24"><path d="M12 4.5C7 4.5 2.73 7.61 1 12c1.73 4.39 6 7.5 11 7.5s9.27-3.11 11-7.5c-1.73-4.39-6-7.5-11-7.5zm0 12.5c-2.76 0-5-2.24-5-5s2.24-5 5-5 5 2.24 5 5-2.24 5-5 5zm0-8c-1.66 0-3 1.34-3 3s1.34 3 3 3 3-1.34 3-3-1.34-3-3-3z"/></svg>',
                        onClick: () => { closeBottomSheet(); openImage(src, instr); }
                    },
                    {
                        label: t('action_save_image') || 'Save image',
                        hint: t('imggen_save_hint') || 'Сохранить картинку на устройство',
                        icon: '<svg viewBox="0 0 24 24"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"/></svg>',
                        onClick: async () => {
                            closeBottomSheet();
                            try {
                                const response = await fetch(src);
                                const blob = await response.blob();
                                await saveFile(`Image_${Date.now()}.png`, blob, 'image/png');
                            } catch (err) {
                                console.error('Failed to save image:', err);
                            }
                        }
                    },
                    {
                        label: t('action_regenerate') || 'Regenerate',
                        hint: t('imggen_regenerate_hint') || 'Повторно сгенерировать картинку',
                        icon: '<svg viewBox="0 0 24 24"><path d="M17.65 6.35C16.2 4.9 14.21 4 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08c-.82 2.33-3.04 4-5.65 4-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z"/></svg>',
                        onClick: () => { closeBottomSheet(); if (instr && id) emit('regenerate-image', { instruction: instr, id }); }
                    },
                ]
            });
            return;
        }

        const retryBtn = path.find(el => el?.classList?.contains('imggen-error-retry'));
        if (retryBtn) {
            e.stopPropagation();
            const errorBlock = path.find(el => el?.classList?.contains('imggen-error'));
            if (errorBlock) {
                const instr = parseIIGInstruction(errorBlock);
                const id = errorBlock.dataset?.iigId;
                if (instr && id) emit('regenerate-image', { instruction: instr, id });
            }
            return;
        }

        const enableBtn = path.find(el => el?.classList?.contains('imggen-enable-retry'));
        if (enableBtn) {
            e.stopPropagation();
            const disabledBlock = path.find(el => el?.classList?.contains('imggen-disabled'));
            if (disabledBlock) {
                import('@/core/services/imageGenService.js').then(module => {
                    const settings = module.getImageGenSettings();
                    settings.enabled = true;
                    module.saveImageGenSettings(settings);
                    
                    const instr = parseIIGInstruction(disabledBlock);
                    const id = disabledBlock.dataset?.iigId;
                    if (instr && id) emit('regenerate-image', { instruction: instr, id });
                });
            }
            return;
        }

        return true;
    };

    return {
        handleContentClick,
        openImage,
    };
}
