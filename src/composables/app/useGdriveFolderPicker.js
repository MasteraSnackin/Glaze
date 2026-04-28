import { ref } from 'vue';
import * as gdriveAdapter from '@/core/services/adapters/gdriveAdapter.js';

export function useGdriveFolderPicker() {
    const gdriveFolderStatus = ref('unchecked');
    const isPickingFolder = ref(false);
    const isCreatingFolder = ref(false);
    const pickerError = ref('');

    async function checkGdriveFolder() {
        gdriveFolderStatus.value = 'checking';
        pickerError.value = '';
        try {
            const folderId = await gdriveAdapter.getGlazeFolderId();
            gdriveFolderStatus.value = folderId ? 'found' : 'not_found';
        } catch (e) {
            console.error('[useGdriveFolderPicker] check failed:', e);
            gdriveFolderStatus.value = 'not_found';
            pickerError.value = e.message;
        }
    }

    async function selectExistingFolder() {
        isPickingFolder.value = true;
        pickerError.value = '';
        try {
            const result = await gdriveAdapter.pickFolder();
            if (result) {
                await gdriveAdapter.setGlazeFolderId(result.id);
                gdriveFolderStatus.value = 'found';
            }
        } catch (e) {
            console.error('[useGdriveFolderPicker] pick failed:', e);
            pickerError.value = e.message;
        } finally {
            isPickingFolder.value = false;
        }
    }

    async function createNewFolder() {
        isCreatingFolder.value = true;
        pickerError.value = '';
        try {
            await gdriveAdapter.ensureFolder('/Glaze');
            const folderId = await gdriveAdapter.getGlazeFolderId(true);
            if (folderId) {
                await gdriveAdapter.setGlazeFolderId(folderId);
            }
            gdriveFolderStatus.value = 'found';
        } catch (e) {
            console.error('[useGdriveFolderPicker] create failed:', e);
            pickerError.value = e.message;
        } finally {
            isCreatingFolder.value = false;
        }
    }

    function resetFolderStatus() {
        gdriveFolderStatus.value = 'unchecked';
        pickerError.value = '';
    }

    return {
        gdriveFolderStatus,
        isPickingFolder,
        isCreatingFolder,
        pickerError,
        checkGdriveFolder,
        selectExistingFolder,
        createNewFolder,
        resetFolderStatus
    };
}