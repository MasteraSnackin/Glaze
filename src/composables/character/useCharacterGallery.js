import { computed } from 'vue';
import { db } from '@/utils/db.js';
import { fileToDataUrl } from '@/utils/imageUtils.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';

function getTranslated(key, fallback) {
    return translations[currentLang.value]?.[key] || fallback;
}

export function useCharacterGallery({ currentCharData, isControlled, localCharData }) {
    const galleryImages = computed(() => {
        const imgs = currentCharData.value?.images;
        return Array.isArray(imgs) ? imgs : [];
    });

    const isLocalCharacter = computed(() => !!currentCharData.value?.id);

    function openGalleryImage(img) {
        publishAppEvent(APP_EVENTS.nav.openImageViewer, { src: img.src });
    }

    async function addGalleryImages(files) {
        const char = currentCharData.value;
        if (!char) return;
        if (!Array.isArray(char.images)) char.images = [];
        for (const file of files) {
            const src = await fileToDataUrl(file);
            let thumbnail = null;
            try {
                const { generateThumbnail } = await import('@/utils/thumbnailUtils.js');
                thumbnail = await generateThumbnail(src, 300);
            } catch (_e) { /* skip thumbnail */ }
            char.images.push({
                id: 'img_' + Math.random().toString(36).slice(2, 10),
                src,
                name: file.name || '',
                thumbnail
            });
        }
        if (char.id) {
            await db.saveCharacter(char, -1);
            publishAppEvent(APP_EVENTS.domain.character.updated, { character: char });
        }
        if (!isControlled.value) {
            localCharData.value = { ...char };
        }
    }

    function triggerGalleryImageUpload() {
        const input = document.createElement('input');
        input.type = 'file';
        input.accept = 'image/*';
        input.multiple = true;
        input.onchange = async (e) => {
            const files = Array.from(e.target.files);
            if (!files.length) return;
            await addGalleryImages(files);
        };
        input.click();
    }

    async function deleteGalleryImage(imgId) {
        const char = currentCharData.value;
        if (!char?.images) return;
        char.images = char.images.filter(img => img.id !== imgId);
        if (char.id) {
            await db.saveCharacter(char, -1);
            publishAppEvent(APP_EVENTS.domain.character.updated, { character: char });
        }
        if (!isControlled.value) {
            localCharData.value = { ...char };
        }
    }

    function confirmDeleteGalleryImage(img) {
        showBottomSheet({
            title: getTranslated('confirm_delete_image', 'Delete image?'),
            items: [
                {
                    label: getTranslated('btn_yes', 'Yes'),
                    icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                    iconColor: '#ff4444',
                    isDestructive: true,
                    onClick: () => { closeBottomSheet(); deleteGalleryImage(img.id); }
                },
                {
                    label: getTranslated('btn_no', 'No'),
                    icon: '<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>',
                    onClick: () => closeBottomSheet()
                }
            ]
        });
    }

    return {
        galleryImages,
        isLocalCharacter,
        openGalleryImage,
        triggerGalleryImageUpload,
        deleteGalleryImage,
        confirmDeleteGalleryImage
    };
}
