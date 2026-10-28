<template>
  <div class="np-card">
    <div class="np-header">
      <h2>Physics Limiter</h2>
    </div>

      <label class="np-check">
        <input type="checkbox" :checked="state.enabled" @change="set('enabled', $event.target.checked)" />
        <span>Enable the mod</span>
      </label>

      <div class="np-section" :class="{ 'np-off': !state.enabled }">
        <div class="np-field">
          <span class="np-label">Cars ahead</span>
          <input
            type="range"
            min="0"
            max="20"
            step="1"
            :value="shown('carsAhead')"
            @input="draft.carsAhead = $event.target.value"
            @change="commit('carsAhead', $event.target.value)"
          />
          <input
            class="np-number"
            type="number"
            min="0"
            max="30"
            :value="shown('carsAhead')"
            @input="draft.carsAhead = $event.target.value"
            @change="commit('carsAhead', $event.target.value)"
            @focus="typing(true)"
            @blur="typing(false); delete draft.carsAhead"
          />
        </div>

        <div class="np-field">
          <span class="np-label">Cars behind</span>
          <input
            type="range"
            min="0"
            max="20"
            step="1"
            :value="shown('carsBehind')"
            @input="draft.carsBehind = $event.target.value"
            @change="commit('carsBehind', $event.target.value)"
          />
          <input
            class="np-number"
            type="number"
            min="0"
            max="30"
            :value="shown('carsBehind')"
            @input="draft.carsBehind = $event.target.value"
            @change="commit('carsBehind', $event.target.value)"
            @focus="typing(true)"
            @blur="typing(false); delete draft.carsBehind"
          />
        </div>

        <div class="np-field">
          <span class="np-label">Max distance</span>
          <input
            type="range"
            min="10"
            max="500"
            step="5"
            :value="shown('physicsDistance')"
            @input="draft.physicsDistance = $event.target.value"
            @change="commit('physicsDistance', $event.target.value)"
          />
          <input
            class="np-number"
            type="number"
            min="10"
            max="1000"
            :value="shown('physicsDistance')"
            @input="draft.physicsDistance = $event.target.value"
            @change="commit('physicsDistance', $event.target.value)"
            @focus="typing(true)"
            @blur="typing(false); delete draft.physicsDistance"
          />
          <span class="np-unit">m</span>
        </div>

        <div class="np-field">
          <span class="np-label">Target FPS</span>
          <input
            class="np-number"
            type="number"
            min="0"
            max="360"
            :value="shown('targetFps')"
            @input="draft.targetFps = $event.target.value"
            @change="commit('targetFps', $event.target.value)"
            @focus="typing(true)"
            @blur="typing(false); delete draft.targetFps"
          />
          <span class="np-unit">0 = off</span>
        </div>

        <div class="np-field">
          <span class="np-label">Visible distance</span>
          <input
            type="range"
            min="0"
            max="5000"
            step="100"
            :value="shown('visibleDistance')"
            @input="draft.visibleDistance = $event.target.value"
            @change="commit('visibleDistance', $event.target.value)"
          />
          <input
            class="np-number"
            type="number"
            min="0"
            max="20000"
            :value="shown('visibleDistance')"
            @input="draft.visibleDistance = $event.target.value"
            @change="commit('visibleDistance', $event.target.value)"
            @focus="typing(true)"
            @blur="typing(false); delete draft.visibleDistance"
          />
          <span class="np-unit">m, 0 = map's own</span>
        </div>

        <label class="np-check">
          <input type="checkbox" :checked="state.sounds" @change="set('sounds', $event.target.checked)" />
          <span>Stand-in sounds</span>
        </label>
        <label class="np-check">
          <input type="checkbox" :checked="state.effects" @change="set('effects', $event.target.checked)" />
          <span>Stand-in effects</span>
        </label>
      </div>

      <div class="np-section">
        <h3>Generate files</h3>
        <p class="np-warning">
          Generating takes a few minutes and the game may freeze or stutter while it runs. It needs about 3&nbsp;GB of
          free disk space. Run it again after a game update or when you add vehicles; "Generate missing" only does the
          vehicles that have no stand-in yet.
        </p>

        <div class="np-job">
          <button
            v-if="state.templates.missing > 0 && state.templates.modelsDone > 0"
            class="np-button"
            :disabled="!!state.templates.disabledReason || state.templates.running"
            @click="run('start', true)"
          >
            Generate missing ({{ state.templates.missing }})
          </button>
          <button
            class="np-button"
            :disabled="!!state.templates.disabledReason || state.templates.running"
            @click="run('start')"
          >
            {{ state.templates.modelsDone > 0 ? "Regenerate all" : "Generate" }}
          </button>
          <span v-if="!state.templates.running" :class="state.templates.ready ? 'np-done' : 'np-progress'">
            {{ state.templates.modelsDone }} / {{ state.templates.modelsTotal }} vehicles
          </span>
          <template v-if="state.templates.running">
            <progress :max="Math.max(state.templates.total, 1)" :value="state.templates.done"></progress>
            <span class="np-progress">{{ state.templates.done }} / {{ state.templates.total }} {{ state.templates.current || "" }}</span>
            <button class="np-button" @click="run('cancel')">Cancel</button>
          </template>
        </div>
        <p v-if="state.templates.disabledReason" class="np-reason">{{ state.templates.disabledReason }}</p>
        <p v-if="state.templates.failed > 0" class="np-reason">
          {{ state.templates.failed }} vehicle(s) could not be generated (see the game log); "Regenerate all" tries them again.
        </p>
      </div>

      <div class="np-footer">
        <button class="np-button" @click="run('reset')">Reset to defaults</button>
        <a class="np-link" href="#" @click.prevent="openLink">github.com/tmaster1000/physics-limiter</a>
      </div>
  </div>
</template>

<script setup>
import { ref, reactive, onMounted, onBeforeUnmount } from "vue"
import { useBridge } from "@/bridge"

const { events, api } = useBridge()

const state = reactive({
  enabled: false,
  carsAhead: 4,
  carsBehind: 2,
  physicsDistance: 500,
  sounds: true,
  effects: true,
  targetFps: 60,
  visibleDistance: 0,
  templates: { running: false, done: 0, total: 0, current: null, ready: false, modelsDone: 0, modelsTotal: 0, missing: 0, failed: 0, disabledReason: null },
})

function callLua(command) {
  if (api && api.engineLua) api.engineLua(command)
  else if (typeof bngApi !== "undefined" && bngApi.engineLua) bngApi.engineLua(command)
}

function set(key, value) {
  callLua(`physicsLimiterSettings.set(${JSON.stringify(key)}, ${JSON.stringify(value)})`)
}

// what is typed or dragged is kept here until it is committed: the state sent every moment would overwrite it
const draft = reactive({})

function shown(key) {
  return draft[key] !== undefined ? draft[key] : state[key]
}

function commit(key, value) {
  delete draft[key]
  const number = Number(value)
  if (value !== "" && Number.isFinite(number)) {
    state[key] = number // shown at once; the game sends the saved value a moment later
    set(key, number)
  }
}

// while a box has the focus the game has to leave the keyboard to it (as it does for its own text boxes)
function typing(on) {
  callLua(`setCEFTyping(${on ? "true" : "false"})`)
}

function openLink() {
  callLua('openWebBrowser("https://github.com/tmaster1000/physics-limiter")')
}

function run(name, arg) {
  callLua(`physicsLimiterSettings.${name}(${arg === undefined ? "" : JSON.stringify(arg)})`)
}

function onState(data) {
  if (!data) return
  Object.assign(state, data)
}

function onTypingLost() {
  if (document.activeElement && document.activeElement.blur) document.activeElement.blur()
}

onMounted(() => {
  events.on("physicsLimiterState", onState)
  events.on("CEFTypingLostFocus", onTypingLost)
  run("open") // the game sends the state while the card is shown
})

onBeforeUnmount(() => {
  events.off("physicsLimiterState", onState)
  events.off("CEFTypingLostFocus", onTypingLost)
  typing(false)
  run("close")
})
</script>

<style scoped>
.np-card {
  box-sizing: border-box;
  width: 100%;
  height: 100%;
  overflow-y: auto;
  padding: 1.2em 1.4em;
  color: #fff;
  font-family: inherit;
}
.np-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
h2,
h3 {
  margin: 0 0 0.6em;
}
.np-section {
  margin-top: 1em;
  padding-top: 0.8em;
  border-top: 1px solid rgba(255, 255, 255, 0.15);
}
.np-off {
  opacity: 0.5;
}
.np-check {
  display: flex;
  align-items: center;
  gap: 0.6em;
  margin: 0.5em 0;
  cursor: pointer;
}
.np-field {
  display: flex;
  align-items: center;
  gap: 0.6em;
  margin: 0.5em 0;
}
.np-label {
  min-width: 8em;
}
.np-field input[type="range"] {
  flex: 1;
}
.np-number {
  width: 5em;
  background: rgba(255, 255, 255, 0.1);
  border: 1px solid rgba(255, 255, 255, 0.25);
  border-radius: 0.25em;
  color: #fff;
  padding: 0.2em 0.4em;
}
.np-unit {
  opacity: 0.7;
  font-size: 0.9em;
}
.np-warning {
  margin: 0 0 0.8em;
  padding: 0.6em 0.8em;
  border-radius: 0.3em;
  background: rgba(255, 170, 0, 0.15);
  border: 1px solid rgba(255, 170, 0, 0.5);
}
.np-job {
  display: flex;
  align-items: center;
  gap: 0.7em;
  margin: 0.4em 0;
}
.np-job progress {
  flex: 1;
}
.np-progress {
  font-size: 0.85em;
  opacity: 0.85;
  white-space: nowrap;
}
.np-done {
  color: #6fd36f;
}
.np-reason {
  margin: 0 0 0.4em;
  font-size: 0.85em;
  opacity: 0.7;
}
.np-footer {
  margin-top: 1em;
  padding-top: 0.8em;
  border-top: 1px solid rgba(255, 255, 255, 0.15);
}
.np-link {
  display: block;
  margin-top: 0.8em;
  font-size: 0.85em;
  color: #fff;
  opacity: 0.7;
}
.np-link:hover {
  opacity: 1;
}
.np-button {
  padding: 0.4em 0.9em;
  border: 1px solid rgba(255, 255, 255, 0.35);
  border-radius: 0.3em;
  background: rgba(255, 255, 255, 0.12);
  color: #fff;
  cursor: pointer;
}
.np-button:hover:not(:disabled) {
  background: rgba(255, 255, 255, 0.22);
}
.np-button:disabled {
  opacity: 0.4;
  cursor: not-allowed;
}
</style>
