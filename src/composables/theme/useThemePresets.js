import { ref, computed, watch } from 'vue';
import { themeState, PRESET_COLORS, createPreset, getPresets, deletePreset, switchPreset, exportThemePreset, importThemePreset, updatePresetMeta, setBackgroundImage } from '@/core/states/themeState.js';
import { saveFile } from '@/core/services/fileSaver.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { updateAppColors } from '@/core/services/ui.js';

const t = (key) => translations[currentLang.value]?.[key] || key;

export function useThemePresets() {
    const presets = ref([]);
    const themeImportInput = ref(null);

    const activePresetName = computed(() => {
        const p = presets.value.find(x => x.id === themeState.activePresetId);
        return p ? p.name : (t('theme_preset_unknown') || 'Unknown');
    });

    const activePresetAuthor = computed(() => {
        const p = presets.value.find(x => x.id === themeState.activePresetId);
        return p ? p.author : '';
    });

    const loadPresetsList = async () => {
        presets.value = await getPresets();
    };

    watch(() => themeState.accentColor, (newVal) => {
        const index = presets.value.findIndex(p => p.id === themeState.activePresetId);
        if (index !== -1) {
            presets.value[index].accentColor = newVal;
        }
    });

    const handleSavePreset = () => {
        showBottomSheet({
            title: t('theme_save_preset'),
            input: {
                label: t('theme_preset_name_placeholder'),
                value: '',
                placeholder: t('theme_my_theme') || 'My Theme',
                confirmLabel: t('btn_save'),
                onConfirm: async (val) => {
                    if (val) {
                        presets.value = await createPreset(val);
                        closeBottomSheet();
                    }
                }
            }
        });
    };

    const handleDeletePreset = (id) => {
        showBottomSheet({
            title: t('theme_confirm_delete_preset'),
            items: [
                {
                    label: t('btn_delete'),
                    icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                    iconColor: '#ff4444',
                    isDestructive: true,
                    onClick: async () => {
                        presets.value = await deletePreset(id);
                        closeBottomSheet();
                    }
                },
                {
                    label: t('btn_cancel'),
                    icon: '<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>',
                    onClick: closeBottomSheet
                }
            ]
        });
    };

    const handleApplyPreset = async (preset) => {
        await switchPreset(preset.id);
        updateAppColors();
        await loadPresetsList();
    };

    const handleExportPreset = async (presetId) => {
        try {
            const exportedData = await exportThemePreset(presetId);
            if (!exportedData) return;
            const fileName = (exportedData.name || 'Theme').replace(/[^a-z0-9а-яё]/gi, '_').toLowerCase();
            await saveFile(`${fileName}.json`, JSON.stringify(exportedData, null, 4), 'application/json', 'themes');
        } catch (e) {
            console.error('Export theme failed', e);
        }
    };

    const openAddThemeSheet = () => {
        showBottomSheet({
            title: t('theme_presets') || 'Presets',
            items: [
                {
                    label: t('action_create_new') || 'Create New',
                    icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                    onClick: () => {
                        closeBottomSheet();
                        handleSavePreset();
                    }
                },
                {
                    label: t('action_import') || 'Import from file',
                    icon: '<svg viewBox="0 0 24 24"><path d="M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96zM14 13v4h-4v-4H7l5-5 5 5h-3z"/></svg>',
                    onClick: () => {
                        closeBottomSheet();
                        themeImportInput.value?.click();
                    }
                }
            ]
        });
    };

    const openThemePresetOptions = (preset) => {
        const items = [];
        
        items.push({
            label: t('action_edit_name') || 'Change Name',
            icon: '<svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>',
            onClick: () => {
                closeBottomSheet();
                showBottomSheet({
                    title: t('action_edit_name') || 'Change Name',
                    input: {
                        placeholder: t('theme_preset_name_placeholder') || 'Enter name',
                        value: preset.name,
                        confirmLabel: t('btn_save') || 'Save',
                        onConfirm: async (val) => {
                            if (val) {
                                presets.value = await updatePresetMeta(preset.id, val, preset.author);
                                closeBottomSheet();
                            }
                        }
                    }
                });
            }
        });

        items.push({
            label: t('change_author') || 'Change Author',
            icon: '<svg viewBox="0 0 24 24"><path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"/></svg>',
            onClick: () => {
                closeBottomSheet();
                showBottomSheet({
                    title: t('change_author') || 'Change Author',
                    input: {
                        placeholder: t('placeholder_author_name') || 'Enter author',
                        value: preset.author || '',
                        confirmLabel: t('btn_save') || 'Save',
                        onConfirm: async (val) => {
                            presets.value = await updatePresetMeta(preset.id, preset.name, val);
                            closeBottomSheet();
                        }
                    }
                });
            }
        });

        items.push({
            label: t('action_export') || 'Export',
            icon: '<svg viewBox="0 0 24 24"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"/></svg>',
            onClick: async () => {
                closeBottomSheet();
                await handleExportPreset(preset.id);
            }
        });

        items.push({
            label: t('btn_delete') || 'Delete',
            icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
            iconColor: '#ff4444',
            isDestructive: true,
            onClick: () => {
                closeBottomSheet();
                handleDeletePreset(preset.id);
            }
        });

        showBottomSheet({
            title: preset.name,
            items
        });
    };

    const openPresetSelector = () => {
        const cardItems = presets.value.map(p => {
            const isActive = themeState.activePresetId === p.id;
            const sublabelParts = [];
            if (p.author) sublabelParts.push(`by ${p.author}`);
            if (isActive) sublabelParts.push(t('preset_active') || 'Active');

            const item = {
                label: p.name,
                sublabel: sublabelParts.join(' • ') || '',
                image: p.bgImage || null,
                icon: !p.bgImage ? '<svg viewBox="0 0 24 24" style="fill:currentColor;"><circle cx="12" cy="12" r="10" fill="' + (p.accentColor || '#7996ce') + '"/></svg>' : null,
                onClick: () => {
                    handleApplyPreset(p);
                    closeBottomSheet();
                }
            };

            if (p.id !== 'default') {
                item.actions = [
                    {
                        icon: '<svg viewBox="0 0 24 24"><path d="M12 8c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm0 2c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2zm0 6c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2z"/></svg>',
                        color: 'var(--text-gray)',
                        onClick: (e) => {
                            e.stopPropagation();
                            closeBottomSheet();
                            openThemePresetOptions(p);
                        }
                    }
                ];
            }
            return item;
        });

        cardItems.push({
            label: t('btn_add') || 'Add / Import',
            sublabel: t('theme_create_import_desc') || 'Create or import a theme',
            icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
            onClick: () => {
                closeBottomSheet();
                openAddThemeSheet();
            }
        });

        showBottomSheet({
            title: t('theme_presets') || 'Presets',
            cardItems
        });
    };

    const onThemeFileSelected = async (event) => {
        const file = event.target.files[0];
        if (!file) return;

        const reader = new FileReader();
        reader.onload = async (e) => {
            try {
                const json = JSON.parse(e.target.result);
                const newPreset = await importThemePreset(json, file.name.replace(/\.json$/i, ''));
                updateAppColors();
                await loadPresetsList();
            } catch (err) {
                console.error('Error importing theme:', err);
                alert(err.message || 'Invalid theme file');
            }
            event.target.value = '';
        };
        reader.readAsText(file);
    };

    const getPresetName = (id) => {
        if (!id) return t('theme_preset_none') || 'None';
        const p = presets.value.find(x => x.id === id);
        return p ? p.name : (t('theme_preset_unknown') || 'Unknown');
    };

    const onBackgroundImageSelected = (e) => {
        const file = e.target.files[0];
        if (!file) return;

        const reader = new FileReader();
        reader.onload = (re) => {
            const dataUrl = re.target.result;
            setBackgroundImage(file);
            
            const index = presets.value.findIndex(p => p.id === themeState.activePresetId);
            if (index !== -1) {
                presets.value[index].bgImage = dataUrl;
            }
        };
        reader.readAsDataURL(file);
    };

    return {
        presets,
        themeImportInput,
        activePresetName,
        activePresetAuthor,
        loadPresetsList,
        handleSavePreset,
        handleDeletePreset,
        handleApplyPreset,
        handleExportPreset,
        openAddThemeSheet,
        openThemePresetOptions,
        openPresetSelector,
        onThemeFileSelected,
        getPresetName,
        onBackgroundImageSelected
    };
}
