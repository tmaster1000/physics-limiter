-- Physics Limiter, Copyright (C) 2026 tmaster1000
-- Licensed under the GNU Affero General Public License version 3, see the LICENSE file.
-- Settings of Physics Limiter: a pause menu tab shows a Vue card (ui/ui-vue/mods/PhysicsLimiter). Keeps the settings
-- (saved in the user folder), applies them to the other modules, runs the generation jobs and sends the card its state.

local M = {}

M.path = '/settings/physicsLimiter.json'
M.pushInterval = 0.4
M.neededBytes = 4 * 1024 ^ 3 -- the stand-ins of the game and the mods take about 3 GB

local defaults = {enabled = false, carsAhead = 4, carsBehind = 2, physicsDistance = 500, sounds = true, effects = true, targetFps = 60, visibleDistance = 0}
local limits = {carsAhead = {0, 30}, carsBehind = {0, 30}, physicsDistance = {10, 1000}, targetFps = {0, 360}, visibleDistance = {0, 20000}}
local settings = {}
local applied = false
local windowOpen = false
local pushTimer = 0
local registered = false
local wasBuilding = false
local originalVisibleDistance
local checkTimer

local function load()
  local saved = jsonReadFile(M.path)
  for key, value in pairs(defaults) do
    local saving
    if type(saved) == 'table' then saving = saved[key] end
    if type(saving) == type(value) then settings[key] = saving else settings[key] = value end
    if limits[key] then settings[key] = clamp(settings[key], limits[key][1], limits[key][2]) end
  end
end

local function save()
  jsonWriteFile(M.path, settings, true)
end

-- the level's render distance; 0 leaves the map's own
local function applyVisibleDistance()
  local info = scenetree.theLevelInfo and Sim.upcast(scenetree.theLevelInfo)
  if not info then return end
  local wanted = settings.visibleDistance
  if wanted > 0 then
    originalVisibleDistance = originalVisibleDistance or info.visibleDistance
    info.visibleDistance = wanted
    info:postApply()
  elseif originalVisibleDistance then
    info.visibleDistance = originalVisibleDistance
    info:postApply()
    originalVisibleDistance = nil
  end
end

local function apply()
  if physicsLimiter then
    physicsLimiter.carsAhead = settings.carsAhead
    physicsLimiter.carsBehind = settings.carsBehind
    physicsLimiter.activeDistance = settings.physicsDistance
    if physicsLimiter.isEnabled() ~= settings.enabled then physicsLimiter.setEnabled(settings.enabled) end
  end
  if physicsLimiterSounds then physicsLimiterSounds.enabled = settings.sounds end
  if physicsLimiterTireSounds then physicsLimiterTireSounds.enabled = settings.sounds end
  if physicsLimiterParticles then physicsLimiterParticles.enabled = settings.effects end
  if physicsLimiterStandIns then physicsLimiterStandIns.targetFps = settings.targetFps end
  applyVisibleDistance()
  applied = physicsLimiter ~= nil and physicsLimiterStandIns ~= nil
end

local function freeBytes()
  local space = Engine.Platform and Engine.Platform.getDiskFreeSpace and Engine.Platform.getDiskFreeSpace()
  return space and space.user or math.huge
end

local function gigabytes(bytes)
  return string.format('%.0f GB', bytes / 1024 ^ 3)
end

-- which vehicle models have their stand-in; looked up when the window opens, a level has loaded or a job ends
local coverage
local function getCoverage()
  if coverage then return coverage end
  if not (physicsLimiterStandIns and physicsLimiterPrebuild) then return {total = 0, done = 0, failed = 0} end -- not loaded yet
  coverage = {total = 0, done = 0, failed = 0}
  local ok, models = pcall(function() return core_vehicles.getModelList().models end)
  if not (ok and models) then return coverage end
  for name, model in pairs(models) do
    local skipped = physicsLimiterPrebuild.skip[name] or model.Type == 'Prop'
    if not skipped and physicsLimiterPrebuild.hasFiles(name) then
      if physicsLimiterStandIns.hasTemplate(name) then
        coverage.total, coverage.done = coverage.total + 1, coverage.done + 1
      elseif physicsLimiterPrebuild.failed[name] then
        coverage.failed = coverage.failed + 1
      else
        coverage.total = coverage.total + 1
      end
    end
  end
  return coverage
end

-- what the window shows: the settings, and whether the generation can be started (or why not) and its progress
local function getState()
  local state = {}
  for key in pairs(defaults) do state[key] = settings[key] end
  local templates = physicsLimiterPrebuild and physicsLimiterPrebuild.getProgress() or {}
  local models = getCoverage()

  local reason
  if freeBytes() < M.neededBytes then reason = 'Not enough free disk space (needs ' .. gigabytes(M.neededBytes) .. ')' end

  if templates.running then
    wasBuilding = true
  elseif wasBuilding then
    wasBuilding, coverage = false, nil
  end
  state.templates = {running = templates.running == true, done = templates.done or 0, total = templates.total or 0,
    current = templates.current, ready = models.done == models.total, modelsDone = models.done, modelsTotal = models.total,
    missing = models.total - models.done, failed = models.failed, disabledReason = reason}
  return state
end

local function push()
  guihooks.trigger('physicsLimiterState', getState())
end

-- value: a boolean or number; keys and ranges as in the defaults
local function set(key, value)
  local default = defaults[key]
  if default == nil or type(value) ~= type(default) then return end
  if type(value) == 'number' then
    local range = limits[key]
    value = clamp(value, range[1], range[2])
  end
  settings[key] = value
  save()
  apply()
  push()
end

local function reset()
  for key, value in pairs(defaults) do settings[key] = value end
  save()
  apply()
  push()
end

-- onlyMissing: only the models that have no stand-in yet, otherwise all (replacing the existing ones)
local function start(onlyMissing)
  if getState().templates.disabledReason then return end
  extensions.load('physicsLimiterPrebuild')
  physicsLimiterPrebuild.start({rebuild = not onlyMissing})
  push()
end

local function cancel()
  if physicsLimiterPrebuild then physicsLimiterPrebuild.stop() end
end

local function deleteGenerated()
  if physicsLimiterPrebuild and physicsLimiterPrebuild.getProgress().running then return end
  physicsLimiterStandIns.deleteGenerated()
  coverage = nil
  push()
end

local function open()
  coverage = nil
  windowOpen = true
  pushTimer = 0
  push()
end

local function close()
  windowOpen = false
end

-- the pause menu's tab for this mod, with its card
local TAB_ID, BUTTON_ID = 'physicsLimiter', 'physicsLimiter.settings'

local function registerTab()
  extensions.load('ui_pause_actions')
  if not (ui_pause_actions and ui_pause_actions.registerModTab) then return end
  ui_pause_actions.registerModTab({id = TAB_ID, label = 'Physics Limiter', icon = 'car'})
  ui_pause_actions.registerModButton({id = BUTTON_ID, tabId = TAB_ID, label = 'Settings', icon = 'adjust',
    componentName = '/ui/ui-vue/mods/PhysicsLimiter/PhysicsLimiterCard.vue'})
  registered = true
end

local function unregisterTab()
  if ui_pause_actions and ui_pause_actions.unregisterModTab then ui_pause_actions.unregisterModTab(TAB_ID) end
  registered = false
end

local function tellMissing()
  local missing = getCoverage().total - getCoverage().done
  if missing > 0 and settings.enabled then
    guihooks.trigger('toastrMsg', {type = 'warning', title = 'Physics Limiter', config = {timeOut = 8000},
      msg = missing .. ' vehicles have no stand-ins yet and will be hidden when out of range. Generate them in the Physics Limiter tab of the pause menu.'})
  end
end

local function onUpdate(dtReal)
  if checkTimer then
    checkTimer = checkTimer - dtReal
    if checkTimer <= 0 then
      checkTimer = nil
      tellMissing()
    end
  end
  if not applied then apply() end
  if not registered then registerTab() end
  if windowOpen then
    pushTimer = pushTimer - dtReal
    if pushTimer <= 0 then
      pushTimer = M.pushInterval
      push()
    end
  end
end

local function onLoadingScreenFadeout()
  originalVisibleDistance = nil
  applyVisibleDistance()
  coverage = nil
  checkTimer = 3 -- the vehicles of a server's mods are known by now
end

local function onClientEndMission()
  originalVisibleDistance = nil
end

local function onExtensionUnloaded()
  settings.visibleDistance = 0
  applyVisibleDistance()
  unregisterTab()
end

local function onExtensionLoaded()
  load()
  if FS:fileExists('/lua/ge/extensions/physicsLimiterServerEvents.lua') then extensions.load('physicsLimiterServerEvents') end -- optional
  registerTab()
end

M.getState = getState
M.set = set
M.reset = reset
M.start = start
M.cancel = cancel
M.deleteGenerated = deleteGenerated
M.open = open
M.close = close
M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onLoadingScreenFadeout = onLoadingScreenFadeout
M.onClientEndMission = onClientEndMission

return M
