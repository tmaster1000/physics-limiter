-- Physics Limiter by tmaster1000
-- Keeps the vehicles nearest the player simulated and deactivates the rest (shown as stand-ins).
-- Console (GE): physicsLimiter.setEnabled(false), physicsLimiter.carsAhead = 3, physicsLimiter.carsBehind = 2

local M = {}
M.dependencies = {'physicsLimiterStandIns', 'physicsLimiterMP', 'physicsLimiterSounds', 'physicsLimiterCollision', 'physicsLimiterParticles', 'physicsLimiterTireSounds', 'physicsLimiterPrebuild', 'physicsLimiterSettings'}

-- nearest vehicles in front of / behind the player (by the direction it faces) that stay simulated; at 0 and 0 only
-- the player, its trailers and vehicles that were hit
M.carsAhead = 4
M.carsBehind = 2
M.activeDistance = 500 -- meters; hard cap, whatever the counts
M.rankMargin = 1 -- a simulated vehicle stays so this many places beyond its count
M.maxSwitchesPerFrame = 1
M.syncFrames = 8 -- BeamMP: frames a woken remote vehicle stays hidden while it syncs
M.maxSyncTime = 1
M.maxHoldTime = 20 -- seconds a vehicle woken by a hit stays simulated at most
-- BeamMP: a woken remote vehicle that moved further than this is placed with the safe teleport (reset, on the ground);
-- its old suspension, wheel spin and damage don't fit the new place
M.resetDistance = 2 -- meters
M.resetAngle = 10 -- degrees

local enabled = false
local time = 0
local deactivated = {}
local syncing = {} -- woken BeamMP remote vehicles still hidden behind their stand-in
local clearances = {} -- height of the reference node above the ground when deactivated
local ignored = {} -- vehicles left alone (the prebuild's)
local held = {} -- vehicles woken by a hit: the time they were woken
local toFreeze = {}
local vehPos = vec3()
local up = vec3(0, 0, 1)

local function isTrailer(id)
  return core_trailerRespawn and core_trailerRespawn.getVehicleTrainHead(id) ~= id
end

local function groundBelow(pos)
  local height = be:getSurfaceHeightBelow(pos + up * 0.5)
  return height and height > -1e5 and height or nil
end

-- BeamMP: moves a deactivated remote vehicle to its server pose, at least as high as when deactivated; with repair
-- (the owner repaired it meanwhile) it goes through the safe teleport, which resets it
local function moveToServerPose(veh, id, repair)
  local pos, rot = physicsLimiterStandIns.getServerRefPose(id)
  if not pos then return false end
  local oldPos = vec3(veh:getPosition())
  local lift = 0
  local clearance = clearances[id]
  local ground = clearance and groundBelow(pos + up * clearance)
  if ground and pos.z < ground + clearance then
    lift = ground + clearance - pos.z
    pos.z = ground + clearance
  end
  local vehRot = quatFromDir(-vec3(veh:getDirectionVector()), vec3(veh:getDirectionVectorUp()))
  local diffRot = vehRot:inversed() * rot
  local turned = math.deg(2 * math.acos(math.min(1, math.abs(diffRot.w))))
  local moved = oldPos:distance(pos)
  local refNode = veh:getRefNodeId()
  local oldVel = vec3(veh:getVelocity())
  local vel = physicsLimiterMP.getVelocity(id) or vec3()
  local method
  if repair or moved > M.resetDistance or turned > M.resetAngle then
    -- safeTeleport turns the rotation it is given by 180 degrees (its callers use the opposite convention)
    spawn.safeTeleport(veh, pos, quat(0, 0, 1, 0) * rot, true, nil, false) -- this also resets (repairs) the vehicle
    veh:applyClusterVelocityScaleAdd(refNode, 1, vel.x, vel.y, vel.z)
    method = 'safe teleport'
  else
    veh:setClusterPosRelRot(refNode, pos.x, pos.y, pos.z, diffRot.x, diffRot.y, diffRot.z, diffRot.w)
    -- change the velocity by the difference only, so the wheels keep spinning
    local add = vel - diffRot * oldVel
    veh:applyClusterVelocityScaleAdd(refNode, 1, add.x, add.y, add.z)
    method = string.format('moved in place, lifted %.2f m (clearance %s)', lift,
      clearance and string.format('%.2f m', clearance) or 'unknown')
  end
  log('I', 'physicsLimiter', string.format('woke %d: moved %.1f m, turned %.0f deg, speed %.1f -> %.1f m/s, %s, center of mass %s',
    id, moved, turned, oldVel:length(), vel:length(), method, physicsLimiterStandIns.hasCog(id) and 'known' or 'unknown'))
  return true
end

local function finishSync(veh, id)
  syncing[id] = nil
  if veh then
    veh:setMeshAlpha(1, '')
    extensions.hook('onPhysicsLimiterSynced', id, veh)
  end
  physicsLimiterStandIns.setWaking(id, nil)
  physicsLimiterStandIns.remove(id)
  physicsLimiterMP.stopTracking(id)
end

local function wake(veh, id)
  extensions.hook('onPhysicsLimiterWaking', id, veh) -- before it is simulated: whoever moved its reported position puts it back
  physicsLimiterSounds.stop(id)
  veh:setActive(1)
  deactivated[id] = nil
  -- BeamMP: moved to its server pose and hidden behind its stand-in until BeamMP's sync has caught up; if its owner
  -- repaired it meanwhile it is reset first
  local repair = physicsLimiterMP.takeReset(id)
  local moved = physicsLimiterMP.isTracked(id) and moveToServerPose(veh, id, repair)
  if repair then
    -- the safe teleport above reset it (once); only without a server pose to move it to does it need a reset of its own
    if not moved then
      veh:requestReset(RESET_PHYSICS)
      veh:resetBrokenFlexMesh()
    end
    log('I', 'physicsLimiter', 'woke ' .. id .. ': repaired, as its owner reset it while it was deactivated')
  end
  -- BeamMP: parts that broke off while deactivated
  local groups = physicsLimiterMP.takeBrokenGroups(id)
  if groups then
    veh:queueLuaCommand(string.format('if nodesVE then nodesVE.applyBreakGroups(%q) end', jsonEncode(groups)))
    log('I', 'physicsLimiter', string.format('woke %d: %d broken part group(s) applied', id, #groups))
  end
  -- BeamMP: powertrain modes, engine, lights and inputs sent while deactivated
  local commands = physicsLimiterMP.takeReplayCommands(id)
  for _, command in ipairs(commands or {}) do veh:queueLuaCommand(command) end
  extensions.hook('onPhysicsLimiterWoke', id, veh)
  if moved then
    veh:queueLuaCommand('if positionVE then positionVE.onReset() end')
    veh:setMeshAlpha(0, '')
    physicsLimiterStandIns.setWaking(id, 0)
    syncing[id] = {frames = 0, updates = physicsLimiterMP.getUpdateCount(id), start = time}
  else
    finishSync(nil, id)
  end
  clearances[id] = nil
end

local function updateSyncing()
  for id, sync in pairs(syncing) do
    sync.frames = sync.frames + 1
    physicsLimiterStandIns.setWaking(id, math.min(1, sync.frames / M.syncFrames))
    local synced = sync.frames >= M.syncFrames and physicsLimiterMP.getUpdateCount(id) > sync.updates
    if synced or time - sync.start > M.maxSyncTime then finishSync(getObjectByID(id), id) end
  end
end

local function freeze(veh, id)
  physicsLimiterStandIns.place(veh, id)
  local pos = vec3(veh:getPosition())
  local ground = groundBelow(pos)
  clearances[id] = ground and clamp(pos.z - ground, 0, 1.5) or nil
  veh:setActive(0)
  physicsLimiterSounds.start(id)
  physicsLimiterMP.startTracking(id)
  deactivated[id] = true
  extensions.hook('onPhysicsLimiterFrozen', id, veh)
end

local function update()
  local playerId = be:getPlayerVehicleID(0)
  local playerVeh = playerId >= 0 and getObjectByID(playerId)
  local focusPos = playerVeh and vec3(playerVeh:getPosition()) or core_camera.getPosition()
  local budget = M.maxSwitchesPerFrame

  local exempt = playerVeh and core_trailerRespawn and core_trailerRespawn.getVehicleTrain(playerId) or {}
  if playerVeh then
    exempt[playerId] = true
    if deactivated[playerId] then
      wake(playerVeh, playerId)
      budget = budget - 1
    end
  end

  local wanted = {}
  if M.carsAhead > 0 or M.carsBehind > 0 then
    local forward = playerVeh and vec3(playerVeh:getDirectionVector()) or vec3(core_camera.getQuat() * vec3(0, 1, 0))
    local maxDistSq = M.activeDistance * M.activeDistance
    local candidates = {}
    for _, veh in ipairs(getAllVehicles()) do
      local id = veh:getId()
      if not exempt[id] and not ignored[id] and not physicsLimiterStandIns.isProp(veh) and not isTrailer(id)
        and not physicsLimiterMP.isOwn(id) then
        local serverPos = deactivated[id] and physicsLimiterMP.getPose(id)
        local offset = (serverPos or vec3(veh:getPositionXYZ())) - focusPos
        local distSq = offset:squaredLength()
        if distSq <= maxDistSq then
          candidates[#candidates + 1] = {id = id, distSq = distSq, ahead = offset:dot(forward) >= 0}
        end
      end
    end
    table.sort(candidates, function(a, b) return a.distSq < b.distSq end)
    local rank = {[true] = 0, [false] = 0}
    for _, c in ipairs(candidates) do
      rank[c.ahead] = rank[c.ahead] + 1
      local count = c.ahead and M.carsAhead or M.carsBehind
      local allowed = count + (deactivated[c.id] and 0 or M.rankMargin)
      if count > 0 and rank[c.ahead] <= allowed then wanted[c.id] = true end
    end
  end
  table.clear(toFreeze)
  for _, veh in ipairs(getAllVehicles()) do
    local id = veh:getId()
    -- props are left alone; own BeamMP vehicles stay active (deactivated they would stop sending their position)
    if not physicsLimiterStandIns.isProp(veh) and not exempt[id] and not ignored[id] and not isTrailer(id)
      and not physicsLimiterMP.isOwn(id) then
      local serverPos = deactivated[id] and physicsLimiterMP.getPose(id)
      if serverPos then vehPos:set(serverPos) else vehPos:set(veh:getPositionXYZ()) end
      if wanted[id] then
        if deactivated[id] and budget > 0 then
          wake(veh, id)
          budget = budget - 1
        elseif not deactivated[id] and not syncing[id] and physicsLimiterStandIns.has(id) then
          physicsLimiterStandIns.remove(id)
          physicsLimiterSounds.stop(id)
        end
      elseif be:getObjectActive(id) and not syncing[id] then
        if held[id] and time - held[id] < M.maxHoldTime then
          -- woken by a hit: stays simulated until physicsLimiterCollision releases it
        else
          held[id] = nil
          table.insert(toFreeze, veh)
        end
      end
    end
  end

  -- the stand-in is built while the vehicle is still active, shown on top of it for a few frames, then the vehicle is
  -- deactivated, so there is no frame without either
  for _, veh in ipairs(toFreeze) do
    local id = veh:getId()
    if not physicsLimiterStandIns.isReady(id) then
      physicsLimiterStandIns.request(veh, id)
      physicsLimiterSounds.request(veh, id)
    elseif not physicsLimiterStandIns.isShown(id) then
      physicsLimiterStandIns.place(veh, id)
    elseif budget > 0 then
      freeze(veh, id)
      budget = budget - 1
    end
  end
end

local function isEnabled()
  return enabled
end

local function isDeactivated(id)
  return deactivated[id] or false
end

-- e.g. when the player enters it or it was hit; with hold it stays simulated until releaseVehicle (or maxHoldTime)
local function wakeVehicle(id, hold)
  local veh = deactivated[id] and getObjectByID(id)
  if veh then
    wake(veh, id)
    held[id] = hold and time or nil
  end
end

local function releaseVehicle(id)
  held[id] = nil
end

local function setEnabled(value)
  enabled = value and true or false
  if enabled then return end
  for id in pairs(deactivated) do
    local veh = getObjectByID(id)
    if veh then wake(veh, id) end
  end
  table.clear(deactivated)
end

-- The switching keys only cycle through active vehicles, so the one that would be entered next is woken first.
local originalSwitchCycle

local function wakeNextVehicle(player, dir)
  player = player or 0
  if player == -1 or not next(deactivated) then return end
  local currentId = be:getPlayerVehicleID(player)
  local order, currentIndex = {}, nil
  for index = 0, be:getObjectCount() - 1 do
    local veh = be:getObject(index)
    local id = veh and veh:getId()
    if veh and veh.jbeam ~= 'unicycle' and veh.playerUsable ~= false and (deactivated[id] or veh:getActive()) then
      order[#order + 1] = id
      if id == currentId then currentIndex = #order end
    end
  end
  local count = #order
  if count < 2 then return end
  currentIndex = currentIndex or (dir > 0 and 0 or 1)
  local id = order[((currentIndex - 1 + dir) % count) + 1]
  if deactivated[id] then
    local veh = getObjectByID(id)
    if veh then wake(veh, id) end
  end
end

local function hookSwitching()
  local switching = extensions.core_input_vehicleSwitching
  if not switching or switching.switchCycleVehicle == M.switchCycleVehicle then return end
  originalSwitchCycle = switching.switchCycleVehicle
  switching.switchCycleVehicle = M.switchCycleVehicle
end

M.switchCycleVehicle = function(player, dir)
  pcall(wakeNextVehicle, player, dir)
  return originalSwitchCycle(player, dir)
end

local function unhookSwitching()
  local switching = extensions.core_input_vehicleSwitching
  if switching and originalSwitchCycle and switching.switchCycleVehicle == M.switchCycleVehicle then
    switching.switchCycleVehicle = originalSwitchCycle
  end
  originalSwitchCycle = nil
end

local function onVehicleSwitched(oldId, newId)
  if deactivated[newId] then wakeVehicle(newId) end
end

local function onExtensionLoaded() -- vehicles deactivated before a Lua reload are woken again when near
  extensions.load('core_input_vehicleSwitching')
  hookSwitching()
  for _, veh in ipairs(getAllVehicles()) do
    if not be:getObjectActive(veh:getId()) and veh.jbeam ~= 'unicycle' then
      deactivated[veh:getId()] = true
    end
  end
end

local function onUpdate(dtReal)
  time = time + dtReal
  hookSwitching()
  if enabled then update() end
  updateSyncing()
end

local function onVehicleDestroyed(id)
  deactivated[id] = nil
  syncing[id] = nil
  clearances[id] = nil
  held[id] = nil
  ignored[id] = nil
end

local function onClientEndMission()
  table.clear(deactivated)
  table.clear(syncing)
  table.clear(clearances)
  table.clear(held)
end

M.isEnabled = isEnabled
M.setEnabled = setEnabled
M.isDeactivated = isDeactivated
M.wakeVehicle = wakeVehicle
M.setIgnored = function(id, value) ignored[id] = value or nil end
M.releaseVehicle = releaseVehicle
M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = unhookSwitching
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleDestroyed = onVehicleDestroyed
M.onClientEndMission = onClientEndMission

return M
