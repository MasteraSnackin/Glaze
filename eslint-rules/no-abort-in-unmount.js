export default {
    meta: {
        type: 'problem',
        docs: {
            description: 'Disallow .abort() calls in Vue onUnmounted/onBeforeUnmount hooks',
            category: 'Architecture',
            recommended: true
        },
        messages: {
            noAbortInUnmount: 'Do not call .abort() in {{hookName}}. Async operations belong to the service layer, not the component lifecycle. Unsubscribe from UI callbacks instead of killing the operation. See docs/rules/vue-components.md — "Async operation lifecycle" section.'
        },
        schema: []
    },

    create(context) {
        function findAbortCalls(node, results) {
            if (!node || typeof node !== 'object') return;
            if (
                node.type === 'CallExpression' &&
                node.callee?.type === 'MemberExpression' &&
                node.callee.property?.name === 'abort'
            ) {
                results.push(node);
            }
            for (const key of Object.keys(node)) {
                if (key === 'parent') continue;
                const val = node[key];
                if (Array.isArray(val)) {
                    for (const child of val) findAbortCalls(child, results);
                } else if (val && typeof val === 'object' && val.type) {
                    findAbortCalls(val, results);
                }
            }
        }

        return {
            CallExpression(node) {
                if (
                    node.callee.type === 'Identifier' &&
                    (node.callee.name === 'onUnmounted' || node.callee.name === 'onBeforeUnmount')
                ) {
                    const callback = node.arguments[0];
                    if (!callback) return;
                    const aborts = [];
                    findAbortCalls(callback.body || callback, aborts);
                    for (const abortNode of aborts) {
                        context.report({
                            node: abortNode,
                            messageId: 'noAbortInUnmount',
                            data: { hookName: node.callee.name }
                        });
                    }
                }
            }
        };
    }
};
