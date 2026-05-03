import { subscribeAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { setPromptPreview } from '@/core/states/promptPreviewState.js';
import {
    hydratePersistedRequestTrace,
    startRequestTrace,
    updateRequestTrace,
    appendRequestTraceLine,
    finishRequestTrace
} from '@/core/states/requestTraceState.js';

let projectionCleanup = null;

export function initDebugStateProjection() {
    if (projectionCleanup) return projectionCleanup;

    hydratePersistedRequestTrace();

    const unsubscribers = [
        subscribeAppEvent(APP_EVENTS.debug.promptPreviewUpdated, ({ detail }) => {
            if (!detail?.debugKey) return;
            setPromptPreview({
                debugKey: detail.debugKey,
                prompt: detail.prompt
            });
        }),
        subscribeAppEvent(APP_EVENTS.debug.requestTraceStarted, ({ detail }) => {
            if (!detail?.debugKey) return;
            startRequestTrace(detail);
        }),
        subscribeAppEvent(APP_EVENTS.debug.requestTraceUpdated, ({ detail }) => {
            if (!detail?.debugKey) return;
            updateRequestTrace({
                debugKey: detail.debugKey,
                patch: detail.patch || {}
            });
        }),
        subscribeAppEvent(APP_EVENTS.debug.requestTraceLineAppended, ({ detail }) => {
            if (!detail?.debugKey) return;
            appendRequestTraceLine({
                debugKey: detail.debugKey,
                line: detail.line
            });
        }),
        subscribeAppEvent(APP_EVENTS.debug.requestTraceFinished, ({ detail }) => {
            if (!detail?.debugKey) return;
            finishRequestTrace(detail);
        })
    ];

    projectionCleanup = () => {
        unsubscribers.forEach(unsubscribe => unsubscribe());
        projectionCleanup = null;
    };

    return projectionCleanup;
}
