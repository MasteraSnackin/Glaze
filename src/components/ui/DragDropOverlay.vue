<script setup>
import { ref, onMounted, onUnmounted } from 'vue';
import { parseCharacterCard, extractCharacterBook } from '@/utils/characterIO.js';
import { db } from '@/utils/db.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { publishAppEvent } from '@/core/events/eventHub.js';

const isDragging = ref(false);
const isProcessing = ref(false);

const dragCount = ref(0); // to handle child element enter/leave correctly

const isExternalFile = (e) => {
    return e.dataTransfer && e.dataTransfer.types && Array.from(e.dataTransfer.types).includes("Files");
};

const onDragEnter = (e) => {
    if (!isExternalFile(e)) return;
    e.preventDefault();
    dragCount.value++;
    if (dragCount.value === 1) {
        isDragging.value = true;
    }
};

const onDragLeave = (e) => {
    if (!isExternalFile(e)) return;
    e.preventDefault();
    dragCount.value--;
    if (dragCount.value === 0) {
        isDragging.value = false;
    }
};

const onDragOver = (e) => {
    if (!isExternalFile(e)) return;
    e.preventDefault();
};

const showSuccess = (title, message) => {
    const lang = currentLang.value;
    showBottomSheet({
        title: title || 'Import Successful',
        bigInfo: {
            icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;color:#44ff44"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z"/></svg>',
            description: message,
            buttonText: translations[lang]?.btn_ok || 'OK',
            onButtonClick: () => closeBottomSheet()
        }
    });
};

const showError = (message) => {
    const lang = currentLang.value;
    showBottomSheet({
        title: translations[lang]?.title_error || "Error",
        bigInfo: {
            icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;color:#ff4444"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>',
            description: message,
            buttonText: translations[lang]?.btn_ok || "OK",
            onButtonClick: () => closeBottomSheet()
        }
    });
};

const onDrop = async (e) => {
    if (!isExternalFile(e)) return;
    e.preventDefault();
    dragCount.value = 0;
    isDragging.value = false;
    
    if (e.dataTransfer.files && e.dataTransfer.files.length > 0) {
        const file = e.dataTransfer.files[0];
        
        if (!file.name.toLowerCase().endsWith('.png') && !file.name.toLowerCase().endsWith('.json')) {
            showError("Unsupported file format. Please use PNG or JSON.");
            return;
        }

        isProcessing.value = true;
        try {
            if (file.name.toLowerCase().endsWith('.json')) {
                const text = await file.text();
                const json = JSON.parse(text);

                if (json.entries) {
                    const { importSTLorebook, saveLorebooks } = await import('@/core/states/lorebookState.js');
                    await importSTLorebook(json, file.name);
                    await saveLorebooks();
                    showSuccess('Import Successful', 'Successfully imported lorebook: ' + (json.name || file.name.replace('.json', '')));
                    isProcessing.value = false;
                    return;
                } else if (Array.isArray(json) || json.scriptName || json.regex || json.findRegex) {
                    const scriptsToImport = Array.isArray(json) ? json : [json];
                    const stored = localStorage.getItem('regex_scripts');
                    const scripts = stored ? JSON.parse(stored) : [];
                    scriptsToImport.forEach(item => {
                        scripts.push({
                            id: Date.now().toString() + Math.random(),
                            name: item.scriptName || item.name || 'Imported Regex',
                            regex: item.findRegex || item.regex || '',
                            replacement: item.replaceString || item.replacement || '',
                            trimOut: Array.isArray(item.trimStrings) ? item.trimStrings.join('\n') : (item.trimOut || ''),
                            placement: Array.isArray(item.placement) ? item.placement : (typeof item.placement === 'number' ? [item.placement] : [2]),
                            disabled: item.disabled ?? false,
                            runOnEdit: item.runOnEdit ?? false,
                            macroRules: (item.substituteRegex ?? 0).toString(),
                            ephemerality: Array.isArray(item.ephemerality) ? item.ephemerality : (item.promptOnly === true ? [2] : [1, 2]),
                            minDepth: item.minDepth ?? null,
                            maxDepth: item.maxDepth ?? null
                        });
                    });
                    localStorage.setItem('regex_scripts', JSON.stringify(scripts));
                    publishAppEvent(APP_EVENTS.domain.lorebook.regexScriptsChanged);
                    showSuccess('Import Successful', 'Successfully imported regex scripts.');
                    isProcessing.value = false;
                    return;
                } else if (json.blocks && Array.isArray(json.blocks)) {
                    const { presetState, savePresets, initPresetState } = await import('@/core/states/presetState.js');
                    const { finalizeImportedPreset } = await import('@/core/services/presetImportService.js');
                    if (!presetState.initialized) {
                        await initPresetState();
                    }
                    let preset = { ...json };
                    if (!preset.id) preset.id = Date.now().toString();
                    preset = finalizeImportedPreset(preset);
                    presetState.presets[preset.id] = preset;
                    savePresets();
                    showSuccess('Import Successful', 'Successfully imported preset: ' + (preset.name || 'Unnamed'));
                    isProcessing.value = false;
                    return;
                } else if (json.prompts && Array.isArray(json.prompts)) {
                    const { presetState, savePresets, initPresetState } = await import('@/core/states/presetState.js');
                    const { convertSTPreset, finalizeImportedPreset } = await import('@/core/services/presetImportService.js');
                    if (!presetState.initialized) {
                        await initPresetState();
                    }
                    let preset = convertSTPreset(json, file.name.replace('.json', ''));
                    preset = finalizeImportedPreset(preset);
                    presetState.presets[preset.id] = preset;
                    savePresets();
                    showSuccess('Import Successful', 'Successfully imported SillyTavern preset: ' + (preset.name || 'Unnamed'));
                    isProcessing.value = false;
                    return;
                } else if (json.tabs && Array.isArray(json.tabs)) {
                    const { presetState, savePresets, initPresetState } = await import('@/core/states/presetState.js');
                    const { convertLatexPreset, finalizeImportedPreset } = await import('@/core/services/presetImportService.js');
                    if (!presetState.initialized) {
                        await initPresetState();
                    }
                    let preset = convertLatexPreset(json, file.name.replace('.json', ''));
                    preset = finalizeImportedPreset(preset);
                    presetState.presets[preset.id] = preset;
                    savePresets();
                    showSuccess('Import Successful', 'Successfully imported LaTeX preset: ' + (preset.name || 'Unnamed'));
                    isProcessing.value = false;
                    return;
                } else if (json.themeMode || json.accentColor || json.bgOpacity !== undefined) {
                    const { switchPreset } = await import('@/core/states/themeState.js');
                    const presets = (await db.get('gz_theme_presets')) || [];
                    const newTheme = { ...json, id: Date.now().toString() };
                    if (!newTheme.name) newTheme.name = file.name.replace('.json', '');
                    presets.push(newTheme);
                    await db.set('gz_theme_presets', presets);
                    await switchPreset(newTheme.id);
                    showSuccess('Import Successful', 'Successfully imported theme: ' + newTheme.name);
                    isProcessing.value = false;
                    return;
                }
                
                // If it's none of the above, we fall through and try to parse it as a character card:
            }

            const charData = await parseCharacterCard(file);
            if (charData) {
                if (!charData.id) {
                    charData.id = Date.now().toString();
                }
                await extractCharacterBook(charData);
                await db.saveCharacter(charData, -1);
                
                // Notify UI to update
                publishAppEvent(APP_EVENTS.domain.character.updated);
                
                const lang = currentLang.value;
                showSuccess(
                    translations[lang]?.sheet_title_char_options || 'Import Successful',
                    (translations[lang]?.msg_import_char_success || 'Successfully imported character:') + ' ' + charData.name
                );
            } else if (file.name.toLowerCase().endsWith('.json')) {
                const lang = currentLang.value;
                showError(
                    (translations[lang]?.msg_import_char_failed || 'Failed to import file') + ': Unrecognized JSON format. Expected a character card, lorebook, preset, regex script, or theme file.'
                );
            }
        } catch (error) {
            console.error("Import failed via drag & drop:", error);
            const lang = currentLang.value;
            showError((translations[lang]?.msg_import_char_failed || "Failed to import file") + ": " + error.message);
        } finally {
            isProcessing.value = false;
        }
    }
};

const onDragStart = (e) => {
    const target = e.composedPath ? e.composedPath()[0] : e.target;
    if (target && target.tagName && target.tagName.toLowerCase() === 'img') {
        e.preventDefault();
    }
};

onMounted(() => {
    window.addEventListener('dragstart', onDragStart);
    window.addEventListener('dragenter', onDragEnter);
    window.addEventListener('dragleave', onDragLeave);
    window.addEventListener('dragover', onDragOver);
    window.addEventListener('drop', onDrop);
});

onUnmounted(() => {
    window.removeEventListener('dragstart', onDragStart);
    window.removeEventListener('dragenter', onDragEnter);
    window.removeEventListener('dragleave', onDragLeave);
    window.removeEventListener('dragover', onDragOver);
    window.removeEventListener('drop', onDrop);
});
</script>

<template>
    <div class="drag-drop-overlay" v-if="isDragging || isProcessing">
        <div class="overlay-content">
            <svg class="upload-icon" viewBox="0 0 24 24" v-if="!isProcessing"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"/></svg>
            <div class="spinner" v-else></div>
            <div class="overlay-text">
{{ isProcessing ? 'Importing...' : 'Drop File Here' }}
</div>
            <div class="overlay-subtext" v-if="!isProcessing">
(Supported formats: PNG, JSON)
</div>
        </div>
    </div>
</template>

<style scoped>
.drag-drop-overlay {
    position: fixed;
    top: 0;
    left: 0;
    width: 100vw;
    height: 100vh;
    background-color: rgba(0, 0, 0, 0.6);
    backdrop-filter: blur(8px);
    z-index: 9999;
    display: flex;
    justify-content: center;
    align-items: center;
    pointer-events: none;
}

.overlay-content {
    display: flex;
    flex-direction: column;
    align-items: center;
    background: rgba(255, 255, 255, 0.1);
    padding: 40px;
    border-radius: 20px;
    border: 2px dashed rgba(255, 255, 255, 0.8);
    box-shadow: 0 10px 30px rgba(0, 0, 0, 0.3);
}

.upload-icon {
    width: 80px;
    height: 80px;
    fill: #ffffff;
    margin-bottom: 20px;
    animation: bounce 1s infinite alternate;
}

.overlay-text {
    font-size: 24px;
    font-weight: bold;
    color: #ffffff;
}

.overlay-subtext {
    font-size: 16px;
    color: rgba(255, 255, 255, 0.7);
    margin-top: 8px;
}

@keyframes bounce {
    from { transform: translateY(0); }
    to { transform: translateY(-10px); }
}

.spinner {
    width: 60px;
    height: 60px;
    border: 6px solid rgba(255, 255, 255, 0.3);
    border-top: 6px solid #ffffff;
    border-radius: 50%;
    animation: spin 1s linear infinite;
    margin-bottom: 20px;
}

@keyframes spin {
    0% { transform: rotate(0deg); }
    100% { transform: rotate(360deg); }
}
</style>
