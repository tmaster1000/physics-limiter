-- Physics Limiter, Copyright (C) 2026 tmaster1000
-- Licensed under the GNU Affero General Public License version 3, see the LICENSE file.
-- Tire screech for the stand-ins (a deactivated vehicle makes no sound): the game's own skid sound, played by a small
-- pool of sound emitters on the nearest sliding stand-ins. BeamMP doesn't send wheel slip, so it is worked out from
-- the sideways speed (a drift) and from wheels shown as spinning or locked (burnout, parking brake).

local M = {}

M.enabled = true
M.maxDistance = 150 -- meters from the camera
M.maxSources = 8
M.minSideSpeed = 2 -- m/s sideways at which the tires start to screech
M.fullSideSpeed = 8 -- m/s sideways for the full volume
M.minSpeed = 5 -- m/s; slower than this a sliding vehicle is not drifting
M.spinVolume = 0.6
M.volume = 1
M.fadeRate = 8 -- 1/s, how fast a source follows its target volume
M.event = 'event:>Surfaces>skid_rigid_v2'
-- the event's constant parameters (a vehicle sets them from its tires); middle values for a normal road tire
M.parameters = {c_tirPrpVolSkd = 0.6, c_tirPrpPitch = 0.6, c_tirPrpSoft = 0.5}

local pool = {}
local counter = 0
local sources = {}
local warned = false

local function newEmitter()
  local emitter = createObject('SFXEmitter')
  emitter = emitter and Sim.upcast(emitter)
  if not emitter then
    if not warned then
      warned = true
      log('W', 'physicsLimiterTireSounds', 'Could not create a sound emitter')
    end
    return
  end
  emitter:setTransform(MatrixF(true))
  emitter:setField('track', 0, M.event)
  emitter.canSave = false
  counter = counter + 1
  emitter:registerObject('physicsLimiterTireSound_' .. counter)
  emitter:play()
  if emitter.setParameter then
    for name, value in pairs(M.parameters) do pcall(emitter.setParameter, emitter, name, value) end
  end
  emitter:setVolumePitchCT(0, 1, 0.5, 0)
  return {emitter = emitter, volume = 0, pitch = 1, color = 0.5}
end

local function deleteAll()
  for _, source in ipairs(pool) do
    if simObjectExists(source.emitter) then
      source.emitter:setVolumePitchCT(0, 1, 0.5, 0)
      source.emitter:delete()
    end
  end
  table.clear(pool)
end

-- the volume, pitch and colour (slip) a stand-in's tires make, or nil
local function screech(id, entry)
  local vel = physicsLimiterMP.getVelocity(id)
  if not vel then return end
  local speed = vel:length()
  local volume = 0
  local slip = 0
  if speed > M.minSpeed then
    local side = math.abs(vel:dot(entry.rot * vec3(1, 0, 0)))
    slip = clamp((side - M.minSideSpeed) / (M.fullSideSpeed - M.minSideSpeed), 0, 1)
    volume = slip
  end
  if entry.smokeWheels then volume = math.max(volume, M.spinVolume) end
  if volume < 0.02 then return end
  return volume, clamp(0.55 + speed / 80, 0.5, 1), 0.5 + 0.3 * slip
end

local function collect(camPos)
  table.clear(sources)
  if not physicsLimiterMP then return end
  local maxSq = M.maxDistance * M.maxDistance
  for id, entry in pairs(physicsLimiterStandIns.getEntries()) do
    local origin, rot = entry.origin, entry.rot
    if origin and rot and entry.placed and entry.mode ~= 'hidden' and not be:getObjectActive(id) then
      local pos = entry.info.box and origin + rot * entry.info.box.center or origin
      local dist = pos:squaredDistance(camPos)
      if dist < maxSq then
        local volume, pitch, color = screech(id, entry)
        if volume then table.insert(sources, {pos = pos, dist = dist, volume = volume, pitch = pitch, color = color}) end
      end
    end
  end
  table.sort(sources, function(a, b) return a.dist < b.dist end)
end

local function onUpdate(dtReal)
  if not M.enabled then
    if pool[1] then deleteAll() end
    return
  end
  collect(core_camera.getPosition())
  local f = math.min(1, dtReal * M.fadeRate)
  for i = 1, math.min(#sources, M.maxSources) do
    local target = sources[i]
    local source = pool[i] or newEmitter()
    pool[i] = source
    if source then
      source.target = target
    end
  end
  for i, source in ipairs(pool) do
    local target = source.target
    local wanted = target and target.volume * M.volume or 0
    source.volume = source.volume + (wanted - source.volume) * f
    if source.volume < 0.01 then source.volume = 0 end
    if target then
      source.emitter:setPosition(target.pos)
      source.pitch, source.color = target.pitch, target.color
    end
    source.emitter:setVolumePitchCT(source.volume, source.pitch, source.color, 0)
    source.target = nil
  end
end

-- emitters from before a Lua reload are found by their name
local function deleteLeftovers()
  for _, name in ipairs(scenetree.findClassObjects('SFXEmitter') or {}) do
    if name:find('^physicsLimiterTireSound_') then
      local emitter = scenetree.findObject(name)
      if emitter then
        pcall(emitter.setVolumePitchCT, emitter, 0, 1, 0.5, 0)
        emitter:delete()
      end
    end
  end
end

local function onExtensionLoaded() deleteLeftovers() end
local function onClientEndMission()
  deleteAll()
  deleteLeftovers()
end

M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = deleteAll
M.onClientEndMission = onClientEndMission

return M
