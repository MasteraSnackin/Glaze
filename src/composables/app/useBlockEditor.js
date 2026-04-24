import { computed } from 'vue';
import { t } from '@/utils/i18n.js';

export function useBlockEditor({ currentPreset, activeEditBlock, activeChatChar, emit }) {
    function getMagicBlockFields(blockId) {
        const block = currentPreset.value.blocks.find(b => b.id === blockId);
        if (!block) return [];
        const fields = [];
        const mode = block.insertion_mode || 'relative';

        fields.push({ key: 'role', label: 'label_role', type: 'select', options: [
            { value: 'system', label: 'role_system' }, { value: 'user', label: 'role_user' }, { value: 'assistant', label: 'role_assistant' }
        ]});
        fields.push({ key: 'insertion_mode', label: 'label_injection_point', type: 'select', options: [
            { value: 'relative', label: 'injection_relative' }, { value: 'depth', label: 'injection_depth' }
        ]});
        if (mode === 'depth') fields.push({ key: 'depth', label: t('label_depth') || 'Depth', type: 'number', placeholder: '4' });
        if (blockId === 'summary') fields.push({ key: 'prefix', label: t('label_prefix') || 'Prefix', type: 'text', placeholder: 'Summary: ' });
        if (blockId === 'authors_note') fields.push({ key: 'info', label: '', type: 'info', text: t('unique_for_chat') || 'Content is unique for each chat' });
        fields.push({ key: 'content', label: t('label_content') || 'Content', type: 'textarea', rows: 5, expandable: true });
        return fields;
    }

    const editorConfig = computed(() => {
        if (activeEditBlock.value?.id === 'authors_note') return [{ title: t('magic_authors_notes') || "Author's Note", fields: getMagicBlockFields('authors_note') }];
        if (activeEditBlock.value?.id === 'summary') return [{ title: t('magic_summary') || "Summary", fields: getMagicBlockFields('summary') }];
        if (activeEditBlock.value?.id === 'guided_generation') {
            const mode = activeEditBlock.value.insertion_mode || 'relative';
            const fields = [
                { key: 'role', label: 'label_role', type: 'select', helpTerm: 'preset-role', options: [{ value: 'system', label: 'role_system' }, { value: 'user', label: 'role_user' }, { value: 'assistant', label: 'role_assistant' }] },
                { key: 'insertion_mode', label: 'label_injection_point', type: 'select', helpTerm: 'preset-injection', options: [{ value: 'relative', label: 'injection_relative' }, { value: 'depth', label: 'injection_depth' }] },
                ...(mode === 'depth' ? [{ key: 'depth', label: t('label_depth') || 'Depth', type: 'number', placeholder: '0' }] : []),
                { key: 'info', label: '', type: 'info', text: t('guided_generation_block_hint') || 'This prompt is sent only when Guided Generation is active.\n{{guidance}} \u2014 user instruction.' },
                { key: 'guidedGenerationPrompt', label: t('label_guided_generation_prompt') || 'Generation Prompt', type: 'textarea', rows: 2, expandable: true },
                { key: 'guidedImpersonationPrompt', label: t('label_guided_impersonation_prompt') || 'Impersonation Prompt', type: 'textarea', rows: 2, expandable: true }
            ];
            return [{ title: t('block_guided_generation') || 'Guided Generation', fields }];
        }
        if (activeEditBlock.value?.isStatic) {
            const blockName = activeEditBlock.value.i18n ? t(activeEditBlock.value.i18n) : activeEditBlock.value.name;
            const fields = [];
            if (activeEditBlock.value.id !== 'chat_history') fields.push({ key: 'role', label: 'label_role', type: 'select', helpTerm: 'preset-role', options: [{ value: 'system', label: 'role_system' }, { value: 'user', label: 'role_user' }, { value: 'assistant', label: 'role_assistant' }] });
            fields.push({ key: 'insertion_mode', label: 'label_injection_point', type: 'select', helpTerm: 'preset-injection', options: [{ value: 'relative', label: 'injection_relative' }, { value: 'depth', label: 'injection_depth' }] });
            if (activeEditBlock.value.insertion_mode === 'depth') fields.push({ key: 'depth', label: 'label_depth', type: 'number', placeholder: '4' });
            fields.push({ key: 'content', label: '', type: 'info', text: `${t('msg_block_managed_by')} "${blockName}"` });
            return [{ title: '', fields }];
        }
        const genericFields = [
            { key: 'name', label: 'label_block_name', type: 'text' },
            { key: 'role', label: 'label_role', type: 'select', helpTerm: 'preset-role', options: [{ value: 'system', label: 'role_system' }, { value: 'user', label: 'role_user' }, { value: 'assistant', label: 'role_assistant' }] },
            { key: 'insertion_mode', label: 'label_injection_point', type: 'select', helpTerm: 'preset-injection', options: [{ value: 'relative', label: 'injection_relative' }, { value: 'depth', label: 'injection_depth' }] }
        ];
        if (activeEditBlock.value?.insertion_mode === 'depth') genericFields.push({ key: 'depth', label: 'label_depth', type: 'number', placeholder: '4' });
        genericFields.push({ key: 'content', label: 'label_content', type: 'textarea', rows: 10, expandable: true });
        return [{ title: '', fields: genericFields }];
    });

    const editorProxy = computed({
        get() {
            if (!activeEditBlock.value) return null;
            if (activeEditBlock.value.id === 'authors_note') return { content: activeChatChar?.value?.authors_note || '', depth: activeEditBlock.value.depth ?? 0, role: activeEditBlock.value.role || 'system', insertion_mode: activeEditBlock.value.insertion_mode || 'relative' };
            if (activeEditBlock.value.id === 'summary') return { content: activeChatChar?.value?.summary || '', depth: activeEditBlock.value.depth ?? 4, role: activeEditBlock.value.role || 'system', insertion_mode: activeEditBlock.value.insertion_mode || 'relative', prefix: activeEditBlock.value.prefix || 'Summary: ' };
            if (activeEditBlock.value.id === 'guided_generation') return { role: activeEditBlock.value.role || 'system', insertion_mode: activeEditBlock.value.insertion_mode || 'relative', depth: activeEditBlock.value.depth ?? 0, guidedGenerationPrompt: currentPreset.value.guidedGenerationPrompt || '', guidedImpersonationPrompt: currentPreset.value.guidedImpersonationPrompt || '' };
            return activeEditBlock.value;
        },
        set(newVal) {
            if (!activeEditBlock.value || !newVal) return;
            if (activeEditBlock.value.id === 'authors_note') {
                if (activeChatChar?.value) emit('update:activeChatChar', { ...activeChatChar.value, authors_note: newVal.content });
                activeEditBlock.value.depth = newVal.depth; activeEditBlock.value.role = newVal.role; activeEditBlock.value.insertion_mode = newVal.insertion_mode;
            } else if (activeEditBlock.value.id === 'summary') {
                if (activeChatChar?.value) emit('update:activeChatChar', { ...activeChatChar.value, summary: newVal.content });
                activeEditBlock.value.depth = newVal.depth; activeEditBlock.value.role = newVal.role; activeEditBlock.value.insertion_mode = newVal.insertion_mode; activeEditBlock.value.prefix = newVal.prefix;
            } else if (activeEditBlock.value.id === 'guided_generation') {
                activeEditBlock.value.role = newVal.role; activeEditBlock.value.insertion_mode = newVal.insertion_mode; activeEditBlock.value.depth = newVal.depth;
                currentPreset.value.guidedGenerationPrompt = newVal.guidedGenerationPrompt; currentPreset.value.guidedImpersonationPrompt = newVal.guidedImpersonationPrompt;
            } else { Object.assign(activeEditBlock.value, newVal); }
        }
    });

    function updateActiveBlock(newVal) {
        const block = activeEditBlock.value; if (!block) return;
        if (block.id === 'authors_note' || block.id === 'summary') {
            if (activeChatChar?.value) emit('update:activeChatChar', { ...activeChatChar.value, ...newVal });
            const prefix = block.id === 'authors_note' ? 'authors_note_' : 'summary_';
            if (newVal[prefix + 'role']) block.role = newVal[prefix + 'role'];
            if (newVal[prefix + 'depth'] !== undefined) block.depth = newVal[prefix + 'depth'];
            if (newVal[prefix + 'insertion_mode']) block.insertion_mode = newVal[prefix + 'insertion_mode'];
            if (block.id === 'summary' && newVal.summary_prefix !== undefined) block.prefix = newVal.summary_prefix;
        } else { Object.assign(block, newVal); }
    }

    return { getMagicBlockFields, editorConfig, editorProxy, updateActiveBlock };
}
