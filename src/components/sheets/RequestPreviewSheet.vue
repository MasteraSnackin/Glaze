<script setup>
import { ref, watch } from 'vue';
import SheetView from '@/components/ui/SheetView.vue';
import { getLastRequestPreviewSnapshot } from '@/core/states/requestPreviewState.js';
import { getRequestTrace } from '@/core/states/requestTraceState.js';
import { subscribeAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import HelpTip from '@/components/ui/HelpTip.vue';

const t = (key) => translations[currentLang.value]?.[key] || key;

const sheet = ref(null);
const previewData = ref(null);
const traceData = ref(null);
const previewTab = ref('formatted');
const dataTab = ref('request');
const expandedMessages = ref(new Set());


let unsubs = [];

const refreshData = () => {
    const snapshot = getLastRequestPreviewSnapshot();
    previewData.value = snapshot.prompt;
    const trace = getRequestTrace();
    traceData.value = trace;
};

const open = () => {
    const snapshot = getLastRequestPreviewSnapshot();
    previewData.value = snapshot.prompt;
    traceData.value = snapshot.trace;
    expandedMessages.value.clear();
    
    unsubs = [
        subscribeAppEvent(APP_EVENTS.debug.promptPreviewUpdated, () => {
            previewData.value = getLastRequestPreviewSnapshot().prompt;
        }),
        subscribeAppEvent(APP_EVENTS.debug.requestTraceStarted, () => {
            traceData.value = getRequestTrace();
        }),
        subscribeAppEvent(APP_EVENTS.debug.requestTraceUpdated, () => {
            traceData.value = getRequestTrace();
        }),
        subscribeAppEvent(APP_EVENTS.debug.requestTraceLineAppended, () => {
            traceData.value = getRequestTrace();
        }),
        subscribeAppEvent(APP_EVENTS.debug.requestTraceFinished, () => {
            traceData.value = getRequestTrace();
        })
    ];
    
    if (sheet.value) sheet.value.open();
};

const onClose = () => {
    unsubs.forEach(unsub => unsub());
    unsubs = [];
};

watch(dataTab, () => {
    refreshData();
});

const toggleMessage = (index) => {
    if (expandedMessages.value.has(index)) {
        expandedMessages.value.delete(index);
    } else {
        expandedMessages.value.add(index);
    }
};

const getParams = (data) => {
    if (!data) return {};
    const { messages, ...rest } = data;
    return rest;
};

const formatParamValue = (val) => {
    if (val === null || val === undefined) return '';
    if (typeof val === 'object') return JSON.stringify(val);
    return val;
};

const getMessageContent = (msg) => {
    if (typeof msg.content === 'string') return msg.content;
    return JSON.stringify(msg.content, null, 2);
};

const getRawJson = () => {
    if (!previewData.value) return '';
    const clean = JSON.parse(JSON.stringify(previewData.value));
    if (clean.messages) {
        clean.messages = clean.messages.map(({ blockName, chatId, sources, _allSources, blockId, isDepth, depth, isHistory, ...rest }) => {
            if (rest.image && typeof rest.image === 'string' && rest.image.length > 100) {
                rest.image = rest.image.slice(0, 80) + '...{BASE64_STRING}';
            }
            return rest;
        });
    }
    return JSON.stringify(clean, null, 2);
};

const getTraceRequestJson = () => {
    if (!traceData.value?.request) return '';
    return JSON.stringify(traceData.value.request, null, 2);
};

const getTraceResponseJson = () => {
    if (traceData.value?.rawResponse === null || traceData.value?.rawResponse === undefined) return '';
    if (typeof traceData.value.rawResponse === 'string') return traceData.value.rawResponse;
    return JSON.stringify(traceData.value.rawResponse, null, 2);
};

const getTraceHeadersJson = (headers) => {
    if (!headers) return '';
    return JSON.stringify(headers, null, 2);
};

const getStreamLinesText = () => {
    if (!traceData.value?.streamLines?.length) return '';
    return traceData.value.streamLines.join('\n');
};

defineExpose({ open });
</script>

<template>
    <SheetView ref="sheet" :title="t('magic_request_preview')" @close="onClose">
        <template #header-title>
            <HelpTip term="request-preview" />
        </template>
        <template #header-bottom>
            <div class="gen-sheet-tabs">
                <div class="tabs-row preview-tabs-row">
                    <div class="top-tabs-container tabs-2">
                        <div class="tab-slider" :style="{ transform: `translateX(${dataTab === 'request' ? '0%' : '100%'})` }"></div>
                        <div class="top-tab" :class="{ active: dataTab === 'request' }" @click="dataTab = 'request'">
                            <svg class="tab-icon" viewBox="0 0 24 24"><path d="M4 12l1.41 1.41L11 7.83V20h2V7.83l5.58 5.59L20 12l-8-8-8 8z"/></svg>
                            <span>{{ t('tab_request') || 'Request' }}</span>
                        </div>
                        <div class="top-tab" :class="{ active: dataTab === 'response' }" @click="dataTab = 'response'">
                            <svg class="tab-icon" viewBox="0 0 24 24"><path d="M20 12l-1.41-1.41L13 16.17V4h-2v12.17l-5.58-5.59L4 12l8 8 8-8z"/></svg>
                            <span>{{ t('tab_response') || 'Response' }}</span>
                        </div>
                    </div>
                </div>
            </div>
        </template>
        <template #header-right>
            <div class="segmented-toggle" @click="previewTab = previewTab === 'formatted' ? 'raw' : 'formatted'">
                <div class="segmented-slider" :class="{ right: previewTab === 'raw' }"></div>
                <div class="segmented-option" :class="{ active: previewTab === 'formatted' }">
                    <svg viewBox="0 0 24 24"><path d="M12 4.5C7 4.5 2.73 7.61 1 12c1.73 4.39 6 7.5 11 7.5s9.27-3.11 11-7.5c-1.73-4.39-6-7.5-11-7.5zM12 17c-2.76 0-5-2.24-5-5s2.24-5 5-5 5 2.24 5 5-2.24 5-5 5zm0-8c-1.66 0-3 1.34-3 3s1.34 3 3 3 3-1.34 3-3-1.34-3-3-3z"/></svg>
                </div>
                <div class="segmented-option" :class="{ active: previewTab === 'raw' }">
                    <svg viewBox="0 0 24 24"><path d="M9.4 16.6L4.8 12l4.6-4.6L8 6l-6 6 6 6 1.4-1.4zm5.2 0l4.6-4.6-4.6-4.6L16 6l6 6-6 6-1.4-1.4z"/></svg>
                </div>
            </div>
        </template>
        <div class="preview-container" v-if="previewData || traceData">
            <Transition name="tab-fade" mode="out-in">
                <!-- Request tab -->
                <div v-if="dataTab === 'request'" key="request">
                    <template v-if="previewData">
                        <Transition name="content-fade" mode="out-in">
                            <div v-if="previewTab === 'formatted'" key="req-formatted">
                                <div class="preview-section-title">{{ t('section_gen_params') || 'Parameters' }}</div>
                                <div class="params-grid">
                                    <div v-for="(value, key) in getParams(previewData)" :key="key" class="param-item">
                                        <div class="param-label">{{ key }}</div>
                                        <div class="param-value">{{ formatParamValue(value) }}</div>
                                    </div>
                                </div>
                                <div class="preview-section-title">{{ t('stat_messages') }} ({{ previewData.messages ? previewData.messages.length : 0 }})</div>
                                <div class="messages-list">
                                    <div v-for="(msg, index) in previewData.messages" :key="index" class="message-card">
                                        <div class="message-header" @click="toggleMessage(index)">
                                            <div class="message-header-content">
                                                <div class="message-meta-row">
                                                    <div class="message-role" :class="msg.role">{{ msg.role }}</div>
                                                    <div class="message-block-name" v-if="msg.blockName">{{ msg.blockName }}</div>
                                                </div>
                                                <div class="message-preview-text" v-if="!expandedMessages.has(index)">
                                                    {{ typeof msg.content === 'string' ? (msg.content.slice(0, 60) + (msg.content.length > 60 ? '...' : '')) : '[Complex Content]' }}
                                                </div>
                                            </div>
                                            <div class="message-toggle-icon" :class="{ rotated: expandedMessages.has(index) }">
                                                <svg viewBox="0 0 24 24"><path d="M7.41 8.59L12 13.17l4.59-4.58L18 10l-6 6-6-6 1.41-1.41z"/></svg>
                                            </div>
                                        </div>
                                        <div class="message-body" v-if="expandedMessages.has(index)">
                                            <pre>{{ getMessageContent(msg) }}</pre>
                                        </div>
                                    </div>
                                </div>
                            </div>
                            <div v-else key="req-raw" class="raw-block">
                                <div class="preview-section-title">Prompt JSON</div>
                                <pre>{{ getRawJson() }}</pre>
                            </div>
                        </Transition>
                    </template>
                    <div v-else class="empty-state">
                        <svg class="empty-state-icon" viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm0 14H6l-2 2V4h16v12z"/></svg>
                        <div class="empty-state-text">{{ t('no_preview_available') || 'No request data' }}</div>
                    </div>
                </div>

                <!-- Response tab -->
                <div v-else key="response">
                    <template v-if="traceData">
                        <Transition name="content-fade" mode="out-in">
                            <div v-if="previewTab === 'formatted'" key="res-formatted">
                                <div class="trace-summary-card">
                                    <div class="preview-section-title">Network Trace</div>
                                    <div class="params-grid">
                                        <div class="param-item">
                                            <div class="param-label">Type</div>
                                            <div class="param-value">{{ traceData.requestType || 'unknown' }}</div>
                                        </div>
                                        <div class="param-item">
                                            <div class="param-label">Status</div>
                                            <div class="param-value">{{ traceData.responseStatus ?? 'pending' }}</div>
                                        </div>
                                        <div class="param-item">
                                            <div class="param-label">Streaming</div>
                                            <div class="param-value">{{ traceData.stream ? 'yes' : 'no' }}</div>
                                        </div>
                                        <div class="param-item">
                                            <div class="param-label">Duration</div>
                                            <div class="param-value">{{ traceData.durationMs ?? 0 }} ms</div>
                                        </div>
                                    </div>
                                    <div class="preview-section-title">Parsed Response</div>
                                    <div class="message-card">
                                        <div class="message-body always-open">
                                            <pre>{{ traceData.parsed?.text || '' }}</pre>
                                        </div>
                                    </div>
                                    <div v-if="traceData.parsed?.reasoning" class="preview-section-title">Parsed Reasoning</div>
                                    <div v-if="traceData.parsed?.reasoning" class="message-card">
                                        <div class="message-body always-open">
                                            <pre>{{ traceData.parsed?.reasoning }}</pre>
                                        </div>
                                    </div>
                                    <div v-if="traceData.parsed?.error" class="preview-section-title">Error</div>
                                    <div v-if="traceData.parsed?.error" class="message-card">
                                        <div class="message-body always-open">
                                            <pre>{{ traceData.parsed?.error }}</pre>
                                        </div>
                                    </div>
                                </div>
                            </div>
                            <div v-else key="res-raw" class="raw-block">
                                <div class="preview-section-title">Response Headers</div>
                                <pre>{{ getTraceHeadersJson(traceData.responseHeaders) }}</pre>
                                <div class="preview-section-title">Raw Response</div>
                                <pre>{{ getTraceResponseJson() }}</pre>
                                <div v-if="traceData.streamLines?.length" class="preview-section-title">Raw SSE Lines</div>
                                <pre v-if="traceData.streamLines?.length">{{ getStreamLinesText() }}</pre>
                            </div>
                        </Transition>
                    </template>
                    <div v-else class="empty-state">
                        <svg class="empty-state-icon" viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm0 14H6l-2 2V4h16v12z"/></svg>
                        <div class="empty-state-text">{{ t('no_preview_available') || 'No response data' }}</div>
                    </div>
                </div>
            </Transition>
        </div>
        <div class="empty-state" v-else>
            <svg class="empty-state-icon" viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm0 14H6l-2 2V4h16v12z"/></svg>
            <div class="empty-state-text">{{ t('no_preview_available') || 'No preview available' }}</div>
        </div>
    </SheetView>
</template>

<style scoped>
.gen-sheet-tabs {
    padding: 0 16px;
    flex-shrink: 0;
}

.segmented-toggle {
    display: flex;
    align-items: center;
    background-color: rgba(255, 255, 255, 0.08);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 20px;
    padding: 0;
    position: relative;
    isolation: isolate;
    flex-shrink: 0;
    cursor: pointer;
}

.segmented-slider {
    position: absolute;
    width: 50%;
    height: 100%;
    border-radius: 20px;
    background-color: var(--vk-blue, #4080ff);
    transition: transform 0.25s cubic-bezier(0.4, 0, 0.2, 1);
    z-index: 0;
}

.segmented-slider.right {
    transform: translateX(100%);
}

.segmented-option {
    width: 32px;
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 1;
    border-radius: 20px;
    transition: color 0.25s ease;
    color: var(--text-gray);
    pointer-events: none;
}

.segmented-option.active {
    color: #fff;
}

.segmented-option svg {
    width: 18px;
    height: 18px;
    fill: currentColor;
}

.preview-container {
    padding: 16px;
    overflow-x: auto;
    font-family: monospace;
    font-size: 12px;
    color: var(--text-black);
    padding-bottom: 40px;
}

.preview-section-title {
    font-size: 13px;
    font-weight: 600;
    text-transform: uppercase;
    color: var(--text-gray);
    margin-bottom: 10px;
    margin-top: 20px;
}
.preview-section-title:first-child {
    margin-top: 0;
}

.params-grid {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 8px;
}

.param-item {
    background-color: rgba(255,255,255,0.05);
    border: 1px solid rgba(255,255,255,0.1);
    border-radius: 12px;
    padding: 10px;
    display: flex;
    flex-direction: column;
    overflow: hidden;
}

.param-label {
    font-size: 11px;
    color: var(--text-gray);
    margin-bottom: 4px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

.param-value {
    font-size: 14px;
    font-weight: 500;
    word-break: break-word;
}

.messages-list {
    display: flex;
    flex-direction: column;
    gap: 8px;
}

.message-card {
    background-color: rgba(255,255,255,0.05);
    border: 1px solid rgba(255,255,255,0.1);
    border-radius: 12px;
    overflow: hidden;
}

.message-header {
    padding: 10px 12px;
    display: flex;
    align-items: center;
    gap: 10px;
    cursor: pointer;
    background-color: rgba(255,255,255,0.02);
    user-select: none;
}

.message-header-content {
    display: flex;
    flex-direction: column;
    gap: 4px;
    flex: 1;
    min-width: 0;
}

.message-meta-row {
    display: flex;
    align-items: center;
    gap: 8px;
}

.message-role {
    font-size: 11px;
    font-weight: 700;
    text-transform: uppercase;
    padding: 2px 6px;
    border-radius: 4px;
    background-color: #424242;
    color: #e0e0e0;
    flex-shrink: 0;
    align-self: flex-start;
}

.message-role.system { background-color: #1565c0; color: #e3f2fd; }
.message-role.user { background-color: #7b1fa2; color: #f3e5f5; }
.message-role.assistant { background-color: #2e7d32; color: #e8f5e9; }

.message-block-name {
    font-size: 11px;
    color: var(--text-gray);
    font-weight: 500;
    white-space: nowrap;
}

.message-preview-text {
    font-size: 13px;
    color: var(--text-gray);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.message-toggle-icon {
    width: 20px;
    height: 20px;
    fill: var(--text-gray);
    transition: transform 0.2s;
    flex-shrink: 0;
}

.message-toggle-icon.rotated {
    transform: rotate(180deg);
}

.message-body {
    padding: 12px;
    border-top: 1px solid rgba(255, 255, 255, 0.05);
    background-color: rgba(0, 0, 0, 0.2);
}

.message-body.always-open {
    border-top: none;
}

.message-body pre {
    margin: 0;
    white-space: pre-wrap;
    word-break: break-word;
    font-family: monospace;
    font-size: 12px;
    color: var(--text-black);
}

.raw-block pre {
    white-space: pre-wrap;
    word-break: break-all;
}

/* Tab & Content Transitions */
.tab-fade-enter-active,
.tab-fade-leave-active {
    transition: opacity 0.2s ease, transform 0.2s ease;
}
.tab-fade-enter-from {
    opacity: 0;
    transform: translateX(8px);
}
.tab-fade-leave-to {
    opacity: 0;
    transform: translateX(-8px);
}

.content-fade-enter-active,
.content-fade-leave-active {
    transition: opacity 0.15s ease;
}
.content-fade-enter-from,
.content-fade-leave-to {
    opacity: 0;
}

.trace-summary-card {
    margin-bottom: 16px;
}

.empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 40px 20px;
    gap: 12px;
    color: var(--text-gray);
}

.empty-state-icon {
    width: 48px;
    height: 48px;
    fill: var(--text-gray);
    opacity: 0.4;
}

.empty-state-text {
    font-size: 14px;
    font-weight: 500;
}
</style>