import { initGlobalErrorHandling } from './utils/errors.js';
import { createApp } from 'vue';
import App from './App.vue';
import './assets/styles.css';
import { initWindowEventBridge } from './core/events/bridges/windowEventBridge.js';
import { initDebugStateProjection } from './core/events/projections/debugStateProjection.js';
import { initAppExtensions } from './core/extensions/appExtensions.js';
import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';

initGlobalErrorHandling();
initWindowEventBridge();
initDebugStateProjection();
initAppExtensions();

const app = createApp(App);

app.config.errorHandler = (err, vm, info) => {
    console.error('[Vue Error]', err, info);
    publishAppEvent(APP_EVENTS.debug.vueError, { err, info });
};

app.mount('#app');
