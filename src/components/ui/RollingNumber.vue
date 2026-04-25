<template>
  <div class="rolling-number">
    <transition-group name="column" tag="div" class="rolling-number-inner">
      <div 
        v-for="col in columns" 
        :key="col.id" 
        class="rolling-column" 
        :class="{ 'is-symbol': isNaN(col.value) }"
      >
        <div v-if="isNaN(col.value)" class="symbol">
{{ col.value }}
</div>
        <div v-else class="digit-container">
          <div class="digit-measure">
0
</div>
          <transition :name="col.isFast ? 'slide-digit-fast' : 'slide-digit'">
            <div :key="col.value" class="digit">
{{ col.value }}
</div>
          </transition>
        </div>
      </div>
    </transition-group>
  </div>
</template>

<script setup>
import { computed } from 'vue';

const props = defineProps({
  value: { type: [String, Number], required: true }
});

const columns = computed(() => {
  const str = String(props.value);
  const cols = [];
  let isDecimal = false;
  // Assign stable IDs based on position from the right so that digits stay in their proper places (ones, tens, etc.).
  for (let i = 0; i < str.length; i++) {
    const char = str[i];
    if (char === '.' || char === ',') isDecimal = true;
    cols.push({
      id: `pos-${str.length - i}`,
      value: char,
      isFast: isDecimal && !isNaN(char) // fast animation for digits after decimal
    });
  }
  return cols;
});
</script>

<style scoped>
.rolling-number {
  display: inline-flex;
  align-items: center;
  vertical-align: middle;
  height: 1.2em;
  font-variant-numeric: tabular-nums;
}

.rolling-number-inner {
  display: inline-flex;
  align-items: center;
}

.rolling-column {
  position: relative;
  display: inline-flex;
  justify-content: center;
}

/* Enter/leave for the entire column (e.g., when transitioning from 9 to 10 and a new digit place appears) */
.column-enter-active,
.column-leave-active {
  transition: all 0.2s ease;
}
.column-enter-from,
.column-leave-to {
  opacity: 0;
  width: 0 !important;
  transform: scaleX(0);
}

.digit-container {
  display: inline-block;
  position: relative;
  height: 1.2em;
  overflow: hidden;
  vertical-align: top;
}

.digit-measure {
  visibility: hidden;
  display: inline-block;
  line-height: 1.2em;
}

.digit {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  text-align: center;
  line-height: 1.2em;
}

.symbol {
  line-height: 1.2em;
}
.is-symbol {
  width: auto;
}

/* Animation for numbers sliding up */
.slide-digit-enter-active,
.slide-digit-leave-active {
  transition: transform 0.2s cubic-bezier(0.4, 0.0, 0.2, 1), opacity 0.2s cubic-bezier(0.4, 0.0, 0.2, 1);
}

/* Fast animation for decimals */
.slide-digit-fast-enter-active,
.slide-digit-fast-leave-active {
  transition: transform 0.05s linear, opacity 0.05s linear;
}

.slide-digit-enter-from,
.slide-digit-fast-enter-from {
  transform: translateY(100%);
  opacity: 0;
}
.slide-digit-leave-to,
.slide-digit-fast-leave-to {
  transform: translateY(-100%);
  opacity: 0;
}
.slide-digit-enter-to,
.slide-digit-leave-from,
.slide-digit-fast-enter-to,
.slide-digit-fast-leave-from {
  transform: translateY(0);
  opacity: 1;
}
</style>
