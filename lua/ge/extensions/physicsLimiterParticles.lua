-- Physics Limiter, Copyright (C) 2026 tmaster1000
-- Licensed under the GNU Affero General Public License version 3, see the LICENSE file.
-- Exhaust and tire smoke for the stand-ins (a deactivated vehicle emits nothing). The game's particles are single
-- particles spawned by a vehicle's physics, so a small pool of emitter nodes is moved to the nearest smoking stand-ins
-- and switched on for a frame every few frames.

local M = {}

M.enabled = true
M.maxDistance = 80 -- meters from the camera
M.maxExhaust = 6
M.maxTire = 8
M.pulseEvery = 6 -- frames between the pulses of an emitter
M.exhaustThrottle = 0.4
M.ejectionPeriodMS = 8 -- ms of an emitter being on per particle: about one particle per pulse, as the game spawns them
M.exhaustEmitter = 'BNGP_44' -- the game's gray exhaust smoke
M.tireEmitter = 'BNGP_6' -- the game's white tire smoke

local pools = {exhaust = {}, tire = {}}
local nodeData
local counter = 0
local frame = 0
local sources = {exhaust = {}, tire = {}}

local function getNodeData()
  if nodeData ~= nil then return nodeData end
  for _, name in ipairs(scenetree.findClassObjects('ParticleEmitterNodeData') or {}) do
    nodeData = name
    return nodeData
  end
  nodeData = false
  return nodeData
end

-- the game's emitters release a particle every millisecond, meant to be spawned one at a time by a vehicle; a copy
-- with a longer period gives about one particle per pulse (the game's own is used if the copy can't be made)
local emitterCopies = {}
local function singleParticleEmitter(name)
  if emitterCopies[name] then return emitterCopies[name] end
  local copyName = 'physicsLimiter_' .. name
  local ok, err = pcall(function()
    if not scenetree.findObject(copyName) then
      local defs = jsonReadFile('/art/shapes/particles/managedParticleEmitterData.json')
      local def = defs and defs[name]
      if not def then error('no definition of ' .. name) end
      local data = createObject('ParticleEmitterData')
      for key, value in pairs(def) do
        if key ~= 'name' and key ~= 'class' and key ~= 'persistentId' then
          if type(value) == 'table' then value = table.concat(value, ' ') end
          data:setField(key, 0, tostring(value))
        end
      end
      data:setField('ejectionPeriodMS', 0, tostring(M.ejectionPeriodMS))
      data:registerObject(copyName)
    end
    if not scenetree.findObject(copyName) then error('not registered') end
  end)
  if not ok then
    log('W', 'physicsLimiterParticles', 'Making a single-particle copy of ' .. name .. ' failed, using the original: ' .. tostring(err))
    copyName = name
  end
  emitterCopies[name] = copyName
  return copyName
end

local function newNode(emitter)
  local data = getNodeData()
  if not data then return end
  emitter = singleParticleEmitter(emitter)
  local node = createObject('ParticleEmitterNode')
  node:setField('emitter', 0, emitter)
  node:setField('dataBlock', 0, data)
  node:setField('velocity', 0, '1')
  node.canSave = false
  counter = counter + 1
  node:registerObject('physicsLimiterEmitter_' .. counter)
  scenetree.MissionGroup:addObject(node.obj)
  node:setActive(false)
  return {node = node, pos = vec3(0, 0, -1000)}
end

local function deleteAll()
  for _, pool in pairs(pools) do
    for _, emitter in ipairs(pool) do emitter.node:delete() end
    table.clear(pool)
  end
end

local function useEmitter(kind, index, source, emitterName, maxCount)
  local pool = pools[kind]
  local emitter = pool[index]
  if not emitter then
    if index > maxCount then return end
    emitter = newNode(emitterName)
    if not emitter then return end
    pool[index] = emitter
  end
  if emitter.pos:squaredDistance(source.pos) > 0.0001 then
    emitter.node:setPosition(source.pos)
    emitter.pos = source.pos
  end
  emitter.node:setActive((frame + index) % M.pulseEvery == 0)
  emitter.used = true
end

local function sortByDistance(a, b) return a.dist < b.dist end

local function collect(camPos)
  table.clear(sources.exhaust)
  table.clear(sources.tire)
  if not (physicsLimiterMP and physicsLimiterStandIns.getEntries) then return end
  local maxSq = M.maxDistance * M.maxDistance
  for id, entry in pairs(physicsLimiterStandIns.getEntries()) do
    local origin, rot = entry.origin, entry.rot
    if origin and rot and entry.mode == 'full' and entry.placed and not be:getObjectActive(id) then
      local dist = origin:squaredDistance(camPos)
      if dist < maxSq then
        local info = physicsLimiterSounds.getInfo(id)
        local throttle = physicsLimiterMP.getInputs(id)
        local points = info and info.exhaustPoints
        if info and not points and entry.info.box then -- no tailpipe known: the rear of the vehicle
          local box = entry.info.box
          points = {{x = box.center.x, y = box.center.y + box.size.y * 0.5, z = box.center.z - box.size.z * 0.25}}
        end
        if points and (throttle or 0) > M.exhaustThrottle then
          for _, p in ipairs(points) do
            table.insert(sources.exhaust, {pos = origin + rot * vec3(p.x, p.y, p.z), dist = dist})
          end
        end
        if entry.smokeWheels then
          for index in pairs(entry.smokeWheels) do
            local w = entry.info.wheels[index]
            if w then table.insert(sources.tire, {pos = origin + rot * (w.center - vec3(0, 0, w.radius)), dist = dist}) end
          end
        end
      end
    end
  end
end

local function onUpdate()
  frame = frame + 1
  if not M.enabled then
    if pools.exhaust[1] or pools.tire[1] then deleteAll() end
    return
  end
  collect(core_camera.getPosition())
  for _, pool in pairs(pools) do
    for _, emitter in ipairs(pool) do emitter.used = false end
  end
  table.sort(sources.exhaust, sortByDistance)
  table.sort(sources.tire, sortByDistance)
  for i, source in ipairs(sources.exhaust) do useEmitter('exhaust', i, source, M.exhaustEmitter, M.maxExhaust) end
  for i, source in ipairs(sources.tire) do useEmitter('tire', i, source, M.tireEmitter, M.maxTire) end
  for _, pool in pairs(pools) do
    for _, emitter in ipairs(pool) do
      if not emitter.used then emitter.node:setActive(false) end
    end
  end
end

-- nodes from before a Lua reload are found by their name
local function deleteLeftovers()
  for _, name in ipairs(scenetree.findClassObjects('ParticleEmitterNode') or {}) do
    if name:find('^physicsLimiterEmitter_') then
      local node = scenetree.findObject(name)
      if node then node:delete() end
    end
  end
end

local function onExtensionLoaded() deleteLeftovers() end

local function onClientEndMission()
  deleteAll()
  deleteLeftovers()
  nodeData = nil
end

local function onExtensionUnloaded() deleteAll() end

M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onClientEndMission = onClientEndMission

return M
