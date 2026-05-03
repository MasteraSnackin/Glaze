import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { generateSummary } from '@/core/llm/usecases/generateSummary.js';
import { t } from '@/utils/i18n.js';

const SUMMARY_CUSTOM_MODEL_ENABLED_KEY = 'gz_summary_custom_model_enabled';
const SUMMARY_CUSTOM_MODEL_KEY = 'gz_summary_custom_model';

const helpTipHtml = (term) => `<button class="help-tip" data-term="${term}" type="button" tabindex="-1" style="width:20px;height:20px;padding:0;border:none;background:none;cursor:pointer;display:inline-flex;align-items:center;justify-content:center;flex-shrink:0;opacity:0.4;color:var(--text-gray);vertical-align:middle;margin-left:4px;"><svg viewBox="0 0 24 24" style="width:16px;height:16px;fill:currentColor;"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 17h-2v-2h2v2zm2.07-7.75l-.9.92C13.45 12.9 13 13.5 13 15h-2v-.5c0-1.1.45-2.1 1.17-2.83l1.24-1.26c.37-.36.59-.86.59-1.41 0-1.1-.9-2-2-2s-2 .9-2 2H8c0-2.21 1.79-4 4-4s4 1.79 4 4c0 .88-.36 1.68-.93 2.25z"/></svg></button>`;

export function useSummarySheet({ currentPreset, activeChatChar, chatHistory }) {
    function openSummarySheet() {
        if (!activeChatChar?.value) return;
        const char = activeChatChar.value;
        const block = currentPreset.value.blocks.find(b => b.id === 'summary'); if (!block) return;

        const data = { role: block.role || 'system', insertion_mode: block.insertion_mode || 'relative', depth: block.depth ?? 4, savedContent: char.summary || '', draftContent: char.summary || '', prefix: block.prefix || 'Summary: ' };
        let isGenerating = false; let debounceTimer = null;
        let useCustomModel = localStorage.getItem(SUMMARY_CUSTOM_MODEL_ENABLED_KEY) === 'true';
        let customModel = localStorage.getItem(SUMMARY_CUSTOM_MODEL_KEY) || '';

        const content = document.createElement('div'); content.className = 'summary-sheet';
        content.innerHTML = [
            `<div class="settings-item"><label>${t('label_role')}${helpTipHtml('preset-role')}</label>`,
            `<select id="summary-role" class="settings-select">`,
            `<option value="system" ${data.role === 'system' ? 'selected' : ''}>${t('role_system') || 'System'}</option>`,
            `<option value="user" ${data.role === 'user' ? 'selected' : ''}>${t('role_user') || 'User'}</option>`,
            `<option value="assistant" ${data.role === 'assistant' ? 'selected' : ''}>${t('role_assistant') || 'Assistant'}</option>`,
            `</select></div>`,
            `<div class="settings-item"><label>${t('label_injection_point')}${helpTipHtml('preset-injection')}</label>`,
            `<select id="summary-mode" class="settings-select">`,
            `<option value="relative" ${data.insertion_mode === 'relative' ? 'selected' : ''}>${t('injection_relative')}</option>`,
            `<option value="depth" ${data.insertion_mode === 'depth' ? 'selected' : ''}>${t('injection_depth')}</option>`,
            `</select></div>`,
            `<div class="settings-item" id="summary-depth-container" style="${data.insertion_mode === 'depth' ? '' : 'display:none'}">`,
            `<label>${t('label_depth')}</label><input type="number" id="summary-depth" value="${data.depth}" placeholder="${t('placeholder_depth')}"></div>`,
            `<div class="settings-item"><label>${t('label_prefix') || 'Prefix'}</label>`,
            `<input type="text" id="summary-prefix" value="${data.prefix}" placeholder="Summary: "></div>`,
            `<div class="settings-item-checkbox"><label>${t('label_custom_model') || 'Custom summary model'}</label>`,
            `<input type="checkbox" id="summary-custom-model-enabled" class="vk-switch" ${useCustomModel ? 'checked' : ''}></div>`,
            `<div class="settings-item" id="summary-custom-model-row" style="${useCustomModel ? '' : 'display:none'}">`,
            `<label>${t('label_model') || 'Model'}</label><input type="text" id="summary-custom-model" value="${customModel}" placeholder="${t('label_model') || 'Model'}"></div>`,
            `<div class="summary-status-row"><div class="summary-status-badge" id="summary-status-badge">${data.savedContent ? 'Saved summary present' : 'No saved summary yet'}</div>`,
            `<div class="summary-status-text" id="summary-status-text">Draft editing is separate until you press Save.</div></div>`,
            `<div class="settings-item"><label>${t('label_content')}</label>`,
            `<textarea id="summary-content" rows="8" placeholder="${t('summary_placeholder')}">${data.draftContent}</textarea></div>`,
            `<div class="summary-action-grid">`,
            `<button id="btn-summary-generate" class="btn-save summary-action-btn summary-action-secondary">Generate Draft</button>`,
            `<button id="btn-summary-update" class="btn-save summary-action-btn summary-action-secondary">Update Draft</button>`,
            `<button id="btn-summary-save" class="btn-save summary-action-btn">Save</button></div>`
        ].join('');

        content.querySelectorAll('.help-tip').forEach(btn => {
            btn.onclick = (e) => { e.stopPropagation(); publishAppEvent(APP_EVENTS.nav.openGlossary, { term: btn.dataset.term }); };
        });

        const save = () => {
            block.role = content.querySelector('#summary-role').value;
            block.insertion_mode = content.querySelector('#summary-mode').value;
            const parsedDepth = parseInt(content.querySelector('#summary-depth').value);
            block.depth = isNaN(parsedDepth) ? 0 : parsedDepth;
            block.prefix = content.querySelector('#summary-prefix').value;
        };

        const persistSummaryModelSettings = () => {
            useCustomModel = !!content.querySelector('#summary-custom-model-enabled')?.checked;
            customModel = content.querySelector('#summary-custom-model')?.value?.trim() || '';
            localStorage.setItem(SUMMARY_CUSTOM_MODEL_ENABLED_KEY, String(useCustomModel));
            localStorage.setItem(SUMMARY_CUSTOM_MODEL_KEY, customModel);
        };

        const updateDraftState = (text) => {
            data.draftContent = text; const isDirty = data.draftContent !== data.savedContent;
            const statusBadge = content.querySelector('#summary-status-badge');
            const statusText = content.querySelector('#summary-status-text');
            if (statusBadge) statusBadge.textContent = isDirty ? 'Draft has unsaved changes' : (data.savedContent ? 'Draft matches saved summary' : 'No saved summary yet');
            if (statusText) statusText.textContent = isDirty ? 'Press Save to apply this summary to the chat.' : 'Draft editing is separate until you press Save.';
        };

        const debouncedSave = () => { if (debounceTimer) clearTimeout(debounceTimer); debounceTimer = setTimeout(save, 500); };

        content.querySelector('#summary-role')?.addEventListener('change', save);
        content.querySelector('#summary-mode')?.addEventListener('change', (e) => {
            const dc = content.querySelector('#summary-depth-container'); if (dc) dc.style.display = e.target.value === 'depth' ? 'block' : 'none'; save();
        });
        content.querySelector('#summary-depth')?.addEventListener('input', save);
        content.querySelector('#summary-prefix')?.addEventListener('input', save);
        content.querySelector('#summary-content')?.addEventListener('input', (e) => { updateDraftState(e.target.value); debouncedSave(); });
        content.querySelector('#summary-custom-model-enabled')?.addEventListener('change', (e) => {
            const mr = content.querySelector('#summary-custom-model-row'); if (mr) mr.style.display = e.target.checked ? 'block' : 'none'; persistSummaryModelSettings();
        });
        content.querySelector('#summary-custom-model')?.addEventListener('input', persistSummaryModelSettings);

        const runSummaryGeneration = async (mode) => {
            if (isGenerating) return; isGenerating = true;
            const genBtn = content.querySelector('#btn-summary-generate'); const updBtn = content.querySelector('#btn-summary-update'); const svBtn = content.querySelector('#btn-summary-save');
            const origGen = genBtn.innerHTML; const origUpd = updBtn.innerHTML;
            genBtn.disabled = true; updBtn.disabled = true; svBtn.disabled = true;
            if (mode === 'generate') genBtn.innerHTML = '<div class="app-loader-spinner" style="width:20px;height:20px;border-width:2px;"></div>';
            else updBtn.innerHTML = '<div class="app-loader-spinner" style="width:20px;height:20px;border-width:2px;"></div>';
            try {
                const historyText = chatHistory?.value?.filter(m => !m.isHidden && !m.isTyping).slice(-50).map(m => `${m.role === 'user' ? (m.persona?.name || 'User') : char.name}: ${m.text}`).join('\n') || '';
                const currentDraft = content.querySelector('#summary-content').value.trim();
                const promptBase = currentPreset.value.summaryPrompt;
                const prompt = mode === 'update' && currentDraft ? `${promptBase}\n\nCurrent summary draft:\n${currentDraft}\n\nUpdate the draft summary to reflect the conversation more accurately.` : promptBase;
                const summary = await generateSummary({ history: historyText, prompt, debugKey: `summary:${char.id}:${Date.now()}`, apiConfigOverride: useCustomModel && customModel ? { model: customModel } : null });
                content.querySelector('#summary-content').value = summary; updateDraftState(summary);
            } catch (e) { console.error(e); } finally {
                isGenerating = false; genBtn.disabled = false; updBtn.disabled = false; svBtn.disabled = false;
                genBtn.innerHTML = origGen; updBtn.innerHTML = origUpd;
            }
        };

        content.querySelector('#btn-summary-generate')?.addEventListener('click', () => runSummaryGeneration('generate'));
        content.querySelector('#btn-summary-update')?.addEventListener('click', () => runSummaryGeneration('update'));
        content.querySelector('#btn-summary-save')?.addEventListener('click', () => {
            save(); data.savedContent = content.querySelector('#summary-content').value; char.summary = data.savedContent; updateDraftState(data.savedContent); closeBottomSheet();
        });
        updateDraftState(data.draftContent);

        showBottomSheet({ title: t('magic_summary'), helpTip: 'summary', content, isSolid: true, onClose: () => { if (debounceTimer) clearTimeout(debounceTimer); save(); } });
    }

    return { openSummarySheet };
}
