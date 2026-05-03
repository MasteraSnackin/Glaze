import { describe, it, expect } from 'vitest';
import { mount } from '@vue/test-utils';
import ToolStripTooltip from '../ToolStripTooltip.vue';

const defaultItems = [
    { id: 'view-personas', label: 'Personas' },
    { id: 'view-presets', label: 'Presets' },
];

describe('ToolStripTooltip — component setup', () => {
    it('mounts successfully with valid props', () => {
        const wrapper = mount(ToolStripTooltip, {
            props: { items: defaultItems },
        });
        expect(wrapper.exists()).toBe(true);
        expect(wrapper.find('.tool-strip-tooltip-wrapper').exists()).toBe(true);
    });

    it('applies default placement of "left"', () => {
        const wrapper = mount(ToolStripTooltip, {
            props: { items: defaultItems },
        });
        // Access the component's props
        expect(wrapper.props('placement')).toBe('left');
    });

    it('accepts a custom placement prop', () => {
        const wrapper = mount(ToolStripTooltip, {
            props: { items: defaultItems, placement: 'right' },
        });
        expect(wrapper.props('placement')).toBe('right');
    });

    it('does not render tooltip bubble when not visible', () => {
        const wrapper = mount(ToolStripTooltip, {
            props: { items: defaultItems },
        });
        // Tooltip bubble should not be in DOM when state.visible is false
        expect(wrapper.find('.tool-strip-tooltip-bubble').exists()).toBe(false);
    });

    it('exposes onItemEnter and onItemLeave via scoped slot', () => {
        let slotProps = null;
        mount(ToolStripTooltip, {
            props: { items: defaultItems },
            slots: {
                default: (props) => {
                    slotProps = props;
                    return [];
                },
            },
        });
        expect(typeof slotProps?.onItemEnter).toBe('function');
        expect(typeof slotProps?.onItemLeave).toBe('function');
    });
});
