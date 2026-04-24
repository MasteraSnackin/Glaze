import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { t } from '@/utils/i18n.js';

const helpTipHtml = (term) => `<button class="help-tip" data-term="${term}" type="button" tabindex="-1" style="width:20px;height:20px;padding:0;border:none;background:none;cursor:pointer;display:inline-flex;align-items:center;justify-content:center;flex-shrink:0;opacity:0.4;color:var(--text-gray);vertical-align:middle;margin-left:4px;"><svg viewBox="0 0 24 24" style="width:16px;height:16px;fill:currentColor;"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 17h-2v-2h2v2zm2.07-7.75l-.9.92C13.45 12.9 13 13.5 13 15h-2v-.5c0-1.1.45-2.1 1.17-2.83l1.24-1.26c.37-.36.59-.86.59-1.41 0-1.1-.9-2-2-2s-2 .9-2 2H8c0-2.21 1.79-4 4-4s4 1.79 4 4c0 .88-.36 1.68-.93 2.25z"/></svg></button>`;

export function useAuthorsNoteSheet({ currentPreset, activeChatChar }) {
    function openAuthorsNoteSheet() {
        if (!activeChatChar?.value) return;
        const char = activeChatChar.value;
        const block = currentPreset.value.blocks.find(b => b.id === 'authors_note'); if (!block) return;
        const data = { enabled: block.enabled !== undefined ? block.enabled : true, role: block.role || 'system', insertion_mode: block.insertion_mode || 'relative', depth: block.depth ?? 0, content: char.authors_note || '' };

        const getToggleIcon = (enabled) => `<input type="checkbox" class="vk-switch" ${enabled ? 'checked' : ''} style="pointer-events: none;">`;

        const content = document.createElement('div');
        content.innerHTML = [
            `<div class="settings-item"><label>${t('label_role')}${helpTipHtml('preset-role')}</label>`,
            `<select id="an-role" class="settings-select">`,
            `<option value="system" ${data.role === 'system' ? 'selected' : ''}>${t('role_system')}</option>`,
            `<option value="user" ${data.role === 'user' ? 'selected' : ''}>${t('role_user')}</option>`,
            `<option value="assistant" ${data.role === 'assistant' ? 'selected' : ''}>${t('role_assistant')}</option>`,
            `</select></div>`,
            `<div class="settings-item"><label>${t('label_injection_point')}${helpTipHtml('preset-injection')}</label>`,
            `<select id="an-mode" class="settings-select">`,
            `<option value="relative" ${data.insertion_mode === 'relative' ? 'selected' : ''}>${t('injection_relative')}</option>`,
            `<option value="depth" ${data.insertion_mode === 'depth' ? 'selected' : ''}>${t('injection_depth')}</option>`,
            `</select></div>`,
            `<div class="settings-item" id="an-depth-container" style="${data.insertion_mode === 'depth' ? '' : 'display:none'}">`,
            `<label>${t('label_depth')}</label><input type="number" id="an-depth" value="${data.depth}" placeholder="${t('placeholder_depth')}"></div>`,
            `<div class="settings-item" style="color: var(--text-gray); font-size: 12px; text-align: center; justify-content: center; opacity: 0.8; margin-top: -4px;">`,
            `${t('unique_for_chat') || 'Content is unique for each chat'}</div>`,
            `<div class="settings-item"><label>${t('label_content')}</label>`,
            `<textarea id="an-content" rows="5">${data.content}</textarea></div>`
        ].join('');

        content.querySelectorAll('.help-tip').forEach(btn => {
            btn.onclick = (e) => { e.stopPropagation(); publishAppEvent(APP_EVENTS.nav.openGlossary, { term: btn.dataset.term }); };
        });

        let debounceTimer = null;
        const save = () => {
            block.enabled = data.enabled;
            block.role = content.querySelector('#an-role').value;
            block.insertion_mode = content.querySelector('#an-mode').value;
            const parsedDepth = parseInt(content.querySelector('#an-depth').value);
            block.depth = isNaN(parsedDepth) ? 0 : parsedDepth;
            char.authors_note = content.querySelector('#an-content').value;
        };
        const debouncedSave = () => { if (debounceTimer) clearTimeout(debounceTimer); debounceTimer = setTimeout(save, 500); };

        content.querySelector('#an-role')?.addEventListener('change', save);
        content.querySelector('#an-mode')?.addEventListener('change', (e) => {
            content.querySelector('#an-depth-container').style.display = e.target.value === 'depth' ? 'block' : 'none'; save();
        });
        content.querySelector('#an-depth')?.addEventListener('input', save);
        content.querySelector('#an-content')?.addEventListener('input', debouncedSave);

        const toggleAction = (e) => {
            data.enabled = !data.enabled; save();
            if (e?.currentTarget) { const input = e.currentTarget.querySelector('input'); if (input) input.checked = data.enabled; }
        };

        showBottomSheet({
            title: t('magic_authors_notes'), helpTip: 'authornote', content, isSolid: true,
            headerAction: { icon: getToggleIcon(data.enabled), onClick: toggleAction },
            onClose: () => { if (debounceTimer) clearTimeout(debounceTimer); save(); }
        });
    }

    return { openAuthorsNoteSheet };
}
