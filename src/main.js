import { initGlobalErrorHandling } from './utils/errors.js';
import { createApp } from 'vue';
import App from './App.vue';
import './assets/styles.css';
import { initWindowEventBridge } from './core/events/bridges/windowEventBridge.js';
import { initDebugStateProjection } from './core/events/projections/debugStateProjection.js';
import { initAppExtensions } from './core/extensions/appExtensions.js';

initGlobalErrorHandling();
initWindowEventBridge();
initDebugStateProjection();
initAppExtensions();

const app = createApp(App);

app.config.errorHandler = (err, vm, info) => {
    console.error('[Vue Error]', err, info);
    window.dispatchEvent(
        new CustomEvent('vue-error', { detail: { err, info } })
    );
};

app.mount('#app');
