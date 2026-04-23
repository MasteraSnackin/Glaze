<script setup>
import { ref, onMounted, onBeforeUnmount } from 'vue';
import SheetView from '@/components/ui/SheetView.vue';
import { notificationsState } from '@/core/states/notificationsState.js';

const sheet = ref(null);

function open() {
    sheet.value?.open();
}

function formatTime(ts) {
    const diff = Math.floor((Date.now() - ts) / 1000);
    if (diff < 60) return 'только что';
    if (diff < 3600) return `${Math.floor(diff / 60)} мин назад`;
    if (diff < 86400) return `${Math.floor(diff / 3600)} ч назад`;
    return new Date(ts).toLocaleDateString();
}

const onOpen = () => open();

onMounted(() => window.addEventListener('open-notifications-sheet', onOpen));
onBeforeUnmount(() => window.removeEventListener('open-notifications-sheet', onOpen));

defineExpose({ open });
</script>

<template>
    <SheetView ref="sheet" :title="'Уведомления'" :fit-content="true">
        <div class="notif-sheet-body">
            <div v-if="notificationsState.items.length === 0" class="notif-empty">
                <svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 22c1.1 0 2-.9 2-2h-4c0 1.1.9 2 2 2zm6-6v-5c0-3.07-1.64-5.64-4.5-6.32V4c0-.83-.67-1.5-1.5-1.5s-1.5.67-1.5 1.5v.68C7.63 5.36 6 7.92 6 11v5l-2 2v1h16v-1l-2-2z"/></svg>
                <span>Уведомлений пока нет</span>
            </div>
            <div v-else class="notif-list">
                <div v-for="(item, idx) in notificationsState.items" :key="idx" class="notif-item">
                    <span class="notif-text">{{ item.text }}</span>
                    <span class="notif-time">{{ formatTime(item.time) }}</span>
                </div>
            </div>
        </div>
    </SheetView>
</template>

<style scoped>
.notif-sheet-body {
    padding: 8px 0 16px;
    min-height: 80px;
}

.notif-empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 10px;
    padding: 32px 16px;
    color: var(--text-gray, #888);
    font-size: 14px;
}

.notif-empty svg {
    width: 36px;
    height: 36px;
    opacity: 0.4;
}

.notif-list {
    display: flex;
    flex-direction: column;
}

.notif-item {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    gap: 12px;
    padding: 11px 20px;
    border-bottom: 1px solid var(--border-color, rgba(0,0,0,0.06));
}

.notif-item:last-child {
    border-bottom: none;
}

.notif-text {
    font-size: 14px;
    color: var(--text-color, #000);
    line-height: 1.4;
    flex: 1;
}

.notif-time {
    font-size: 12px;
    color: var(--text-gray, #888);
    white-space: nowrap;
    flex-shrink: 0;
}
</style>
