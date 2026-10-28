-- Physics Limiter, Copyright (C) 2026 tmaster1000
-- Licensed under the GNU Affero General Public License version 3, see the LICENSE file.
-- BeamMP support: tracks the server positions of deactivated remote vehicles (they run no position sync of their own)
-- by wrapping BeamMP's positionGE.handle. The pose is predicted as BeamMP's positionVE does for a simulated remote
-- vehicle, but without smoothing the velocities and accelerations (a stand-in has no physics to keep calm, and
-- smoothing made the prediction less accurate).

local M = {}

M.maxPredict = 0.3 -- seconds the pose is predicted ahead (or back) at most
M.maxAcc = 100 -- m/s^2, acceleration limit of the data worked out from the packets
M.maxRacc = 50 -- rad/s^2

-- local clock in seconds, read when a packet arrives (summing the frame times drifted from the sender's clock)
local clock = hptimer()
local time = 0
local lastDT = 0
local ownPing = 0
local tracked = {} -- deactivated remote vehicles, by id: the state of BeamMP's positionVE
local resets = {} -- the vehicles their owner reset (repaired) while they were deactivated, by id
local states = {} -- state packets (powertrain modes, engine, electrics) of deactivated remote vehicles, merged
local broken = {} -- the break groups (parts torn off) the owner reported while a vehicle was deactivated, by id: {name = true}
local inputs = {} -- latest inputs by id: throttle 't', gear 'g', steering 's', brake 'b', parking brake 'p'
local posPattern = '"pos":%[%s*([^,%s]+)%s*,%s*([^,%s]+)%s*,%s*([^%]%s]+)%s*%]'
local rotPattern = '"rot":%[%s*([^,%s]+)%s*,%s*([^,%s]+)%s*,%s*([^,%s]+)%s*,%s*([^%]%s]+)%s*%]'
local velPattern = '"vel":%[%s*([^,%s]+)%s*,%s*([^,%s]+)%s*,%s*([^%]%s]+)%s*%]'
local rvelPattern = '"rvel":%[%s*([^,%s]+)%s*,%s*([^,%s]+)%s*,%s*([^%]%s]+)%s*%]'

local function limited(v, length)
  local l = v:length()
  if l > length then return v * (length / l) end
  return v
end

local function newEntry()
  return {
    pos = vec3(), rot = quat(0, 0, 0, 0), vel = vec3(), acc = vec3(), rvel = vec3(), racc = vec3(),
    timer = -1, timeOffset = 0, recTime = 0, count = 0,
    offsetSmoother = newTemporalSmoothingNonLinear(1),
    predictTime = 0
  }
end

local function resetEntry(entry) -- positionVE.onReset
  entry.acc, entry.racc = vec3(), vec3()
  entry.timer = -1
end

local function isOwn(id)
  return MPVehicleGE and MPVehicleGE.isOwn(id) or false
end

local function startTracking(id)
  local vehicle = MPVehicleGE and MPVehicleGE.getVehicleByGameID(id)
  if vehicle and not vehicle.isLocal then tracked[id] = newEntry() end
end

local function stopTracking(id)
  tracked[id] = nil
end

-- nodesGE.handle: break groups that broke off a remote vehicle. BeamMP sends each once, to the vehicle's code, which
-- doesn't run while it is deactivated, so all are kept until its owner resets it.
local function onNodesPacket(rawData)
  local code, serverId, data = string.match(rawData, '^(%a)%:(%d+%-%d+)%:(.*)')
  if code ~= 'g' then return end
  local vehicle = MPVehicleGE.getVehicleByServerID(serverId)
  local id = vehicle and not vehicle.isLocal and vehicle.gameVehicleID
  if not id then return end
  local groups = jsonDecode(data)
  if type(groups) ~= 'table' then return end
  broken[id] = broken[id] or {}
  for _, name in pairs(groups) do broken[id][tostring(name)] = true end
end

-- BeamMP sends these once, to the vehicle's code, which doesn't run while it is deactivated (queued commands are
-- dropped): the latest of each is kept and applied when it is woken
local stateKinds = {
  MPPowertrainGE = {l = {'MPPowertrainVE', 'applyLivePowertrain'}, e = {'MPPowertrainVE', 'applyEngineData'}},
  MPElectricsGE = {e = {'MPElectricsVE', 'applyElectrics'}},
}

local function merge(into, from)
  for key, value in pairs(from) do
    if type(value) == 'table' and type(into[key]) == 'table' then merge(into[key], value) else into[key] = value end
  end
end

local function recordState(moduleName, rawData)
  local code, serverId, data = string.match(rawData, '^(%a)%:(%d+%-%d+)%:({.*})')
  local kind = code and stateKinds[moduleName][code]
  if not kind then return end
  local vehicle = MPVehicleGE.getVehicleByServerID(serverId)
  local id = vehicle and not vehicle.isLocal and vehicle.gameVehicleID
  if not (id and tracked[id]) then return end
  local decoded = jsonDecode(data)
  if type(decoded) ~= 'table' then return end
  local perVehicle = states[id] or {}
  states[id] = perVehicle
  local key = moduleName .. code
  perVehicle[key] = perVehicle[key] or {kind = kind, data = {}}
  merge(perVehicle[key].data, decoded)
end

-- the commands that give a woken vehicle what BeamMP sent it while it was deactivated (a list, or nil); forgotten
local function takeReplayCommands(id)
  local commands = {}
  for _, item in pairs(states[id] or {}) do
    commands[#commands + 1] = string.format('if %s then %s.%s(%%q) end', item.kind[1], item.kind[1], item.kind[2]):format(jsonEncode(item.data))
  end
  states[id] = nil
  local last = inputs[id]
  if last then
    local data = {t = last.throttle, s = last.steering, b = last.brake, p = last.parkingbrake, g = last.gear}
    commands[#commands + 1] = string.format('if MPInputsVE then MPInputsVE.applyInputs(%q) end', jsonEncode(data))
  end
  return commands[1] and commands
end

-- MPVehicleGE.handle: the owner reset the vehicle, so the groups kept for it no longer apply
local function onVehiclePacket(rawData)
  if string.sub(rawData, 1, 1) ~= 'r' then return end
  local serverId = string.match(rawData, '^r%:(%d+%-%d+)%:')
  local vehicle = serverId and MPVehicleGE.getVehicleByServerID(serverId)
  local id = vehicle and not vehicle.isLocal and vehicle.gameVehicleID
  if id then
    broken[id] = nil
    if tracked[id] then resets[id] = true end
  end
end

-- whether the owner reset the vehicle while it was deactivated (it is repaired when woken); forgotten
local function takeReset(id)
  local was = resets[id]
  resets[id] = nil
  return was or false
end

-- the groups kept for a vehicle (a list, or nil); kept, as it can be deactivated and woken again
local function takeBrokenGroups(id)
  local set = broken[id]
  if not set then return end
  local list = {}
  for name in pairs(set) do list[#list + 1] = name end
  return list[1] and list
end

-- positionVE.updateRemoteData
local function onPacket(rawData)
  local serverId, data = string.match(rawData, '^p%:(%d+%-%d+)%:({.*})')
  local vehicle = serverId and MPVehicleGE.getVehicleByServerID(serverId)
  local entry = vehicle and tracked[vehicle.gameVehicleID]
  if not entry then return end

  local x, y, z = string.match(data, posPattern)
  local rx, ry, rz, rw = string.match(data, rotPattern)
  local vx, vy, vz = string.match(data, velPattern)
  local wx, wy, wz = string.match(data, rvelPattern)
  local tim = tonumber(string.match(data, '"tim":%s*([^,}%s]+)'))
  local ping = tonumber(string.match(data, '"ping":%s*([^,}%s]+)'))
  x, y, z, rx, ry, rz, rw = tonumber(x), tonumber(y), tonumber(z), tonumber(rx), tonumber(ry), tonumber(rz), tonumber(rw)
  vx, vy, vz = tonumber(vx) or 0, tonumber(vy) or 0, tonumber(vz) or 0
  wx, wy, wz = tonumber(wx) or 0, tonumber(wy) or 0, tonumber(wz) or 0
  if not (x and y and z and rx and ry and rz and rw) then
    local decoded = jsonDecode(data)
    if not (decoded and decoded.pos and decoded.rot) then return end
    x, y, z = decoded.pos[1], decoded.pos[2], decoded.pos[3]
    rx, ry, rz, rw = decoded.rot[1], decoded.rot[2], decoded.rot[3], decoded.rot[4]
    local vel = decoded.vel or {0, 0, 0}
    vx, vy, vz = vel[1], vel[2], vel[3]
    local rvel = decoded.rvel or {0, 0, 0}
    wx, wy, wz = rvel[1] or 0, rvel[2] or 0, rvel[3] or 0
    tim = tonumber(decoded.tim)
    ping = tonumber(decoded.ping)
  end
  if not tim then return end
  ping = ping or 0

  if entry.timer > tim then
    if tim > entry.timer - 1 then return end
    resetEntry(entry) -- the sender's clock started over (its vehicle was reset)
  end

  local remoteDT = math.max(tim - entry.timer, 0.001)
  local vel, rvel = vec3(vx, vy, vz), vec3(wx, wy, wz)
  entry.pos, entry.rot = vec3(x, y, z), quat(rx, ry, rz, rw)
  entry.acc = limited((vel - entry.vel) / remoteDT, M.maxAcc)
  entry.racc = limited((rvel - entry.rvel) / remoteDT, M.maxRacc)
  entry.vel, entry.rvel = vel, rvel
  entry.timer = tim
  local arrival = clock:stop() / 1000
  entry.timeOffset = arrival - tim - ownPing / 2 - ping / 2 - lastDT
  entry.recTime = arrival
  entry.count = entry.count + 1
  entry.first = entry.first or {pos = entry.pos, rot = entry.rot}
end

-- positionVE.updateGFX: the pose predicted for now from the latest packet
local function predict(entry, dt)
  if entry.timer < 0 then return end
  local offset = entry.offsetSmoother:get(entry.timeOffset, dt)
  if math.abs(offset - entry.timeOffset) > 1 then
    entry.offsetSmoother.state = entry.timeOffset
    offset = entry.timeOffset
  end
  local predictTime = math.min(math.max(time - (entry.timer + offset), -M.maxPredict), M.maxPredict)
  entry.predictTime = predictTime
  local half = 0.5 * predictTime * predictTime
  -- the rotation continues with the rotation velocity only: a noisy reported rotation velocity would shake it through the worked-out angular acceleration
  local turn = entry.rvel * predictTime
  entry.shownPos = entry.pos + entry.vel * predictTime + entry.acc * half
  entry.shownRot = entry.rot * quatFromEuler(turn.x, turn.y, turn.z)
  entry.shownVel = entry.vel + entry.acc * predictTime
  entry.shownRvel = entry.rvel
end

-- predicted pose of a deactivated remote vehicle, or nil
local function getPose(id)
  local entry = tracked[id]
  if entry and entry.shownPos then return entry.shownPos, entry.shownRot end
end

-- the first update after the vehicle was deactivated, to relate server poses to the vehicle's pose at that moment
local function getFirstPose(id)
  local entry = tracked[id]
  return entry and entry.first and entry.first.pos, entry and entry.first and entry.first.rot
end

-- the predicted velocity, or zero once updates have stopped coming (the vehicle is then shown standing)
local stopped = vec3()
local function getVelocity(id)
  local entry = tracked[id]
  if not (entry and entry.shownVel) then return end
  return time - entry.recTime > M.maxPredict and stopped or entry.shownVel
end

-- the predicted rotation velocity (in the vehicle's axes), or zero once updates have stopped
local function getAngularVelocity(id)
  local entry = tracked[id]
  if not (entry and entry.shownRvel) then return end
  return time - entry.recTime > M.maxPredict and stopped or entry.shownRvel
end

local function getUpdateCount(id)
  return tracked[id] and tracked[id].count or 0
end

local function isTracked(id)
  return tracked[id] ~= nil
end

local function onInputsPacket(rawData)
  local serverId, data = string.match(rawData, '^i%:(%d+%-%d+)%:({.*})')
  local vehicle = serverId and MPVehicleGE.getVehicleByServerID(serverId)
  local id = vehicle and not vehicle.isLocal and vehicle.gameVehicleID
  if not id then return end
  local decoded = jsonDecode(data)
  if type(decoded) ~= 'table' then return end
  local entry = inputs[id] or {}
  if tonumber(decoded.t) then entry.throttle = tonumber(decoded.t) end
  if tonumber(decoded.s) then entry.steering = tonumber(decoded.s) end
  if tonumber(decoded.b) then entry.brake = tonumber(decoded.b) end
  if tonumber(decoded.p) then entry.parkingbrake = tonumber(decoded.p) end
  if decoded.g ~= nil then entry.gear = decoded.g end
  inputs[id] = entry
end

-- latest inputs BeamMP received for a remote vehicle, if any: throttle, gear, steering, brake, parking brake
local function getInputs(id)
  local entry = inputs[id]
  if entry then return entry.throttle, entry.gear, entry.steering, entry.brake, entry.parkingbrake end
end

local function installHook()
  if MPInputsGE and MPInputsGE.handle and not MPInputsGE._physicsLimiterHooked then
    local originalHandle = MPInputsGE.handle
    MPInputsGE.handle = function(rawData)
      if physicsLimiterMP and MPVehicleGE then
        local ok, err = pcall(physicsLimiterMP.onInputsPacket, rawData)
        if not ok then log('E', 'physicsLimiterMP', 'Reading an inputs packet failed: ' .. tostring(err)) end
      end
      return originalHandle(rawData)
    end
    MPInputsGE._physicsLimiterHooked = true
    log('I', 'physicsLimiterMP', 'Hooked into BeamMP inputs packets')
  end
  for _, moduleName in ipairs({'MPPowertrainGE', 'MPElectricsGE'}) do
    local module = _G[moduleName]
    if module and module.handle and not module._physicsLimiterHooked then
      local originalHandle = module.handle
      module.handle = function(rawData)
        if physicsLimiterMP and MPVehicleGE then
          local ok, err = pcall(physicsLimiterMP.recordState, moduleName, rawData)
          if not ok then log('E', 'physicsLimiterMP', 'Reading a ' .. moduleName .. ' packet failed: ' .. tostring(err)) end
        end
        return originalHandle(rawData)
      end
      module._physicsLimiterHooked = true
      log('I', 'physicsLimiterMP', 'Hooked into BeamMP ' .. moduleName .. ' packets')
    end
  end
  if MPVehicleGE and MPVehicleGE.handle and not MPVehicleGE._physicsLimiterHooked then
    local originalHandle = MPVehicleGE.handle
    MPVehicleGE.handle = function(rawData)
      if physicsLimiterMP then
        local ok, err = pcall(physicsLimiterMP.onVehiclePacket, rawData)
        if not ok then log('E', 'physicsLimiterMP', 'Reading a vehicle packet failed: ' .. tostring(err)) end
      end
      return originalHandle(rawData)
    end
    MPVehicleGE._physicsLimiterHooked = true
    log('I', 'physicsLimiterMP', 'Hooked into BeamMP vehicle packets')
  end
  if nodesGE and nodesGE.handle and not nodesGE._physicsLimiterHooked then
    local originalHandle = nodesGE.handle
    nodesGE.handle = function(rawData)
      if physicsLimiterMP and MPVehicleGE then
        local ok, err = pcall(physicsLimiterMP.onNodesPacket, rawData)
        if not ok then log('E', 'physicsLimiterMP', 'Reading a node packet failed: ' .. tostring(err)) end
      end
      return originalHandle(rawData)
    end
    nodesGE._physicsLimiterHooked = true
    log('I', 'physicsLimiterMP', 'Hooked into BeamMP break group packets')
  end
  if positionGE and positionGE.setPing and not positionGE._physicsLimiterPingHooked then
    local originalSetPing = positionGE.setPing
    positionGE.setPing = function(ping)
      local p = ping / 1000
      if p < 0.99 or p > 1.01 then ownPing = p end
      return originalSetPing(ping)
    end
    positionGE._physicsLimiterPingHooked = true
  end
  if positionGE and positionGE.handle and not positionGE._physicsLimiterHooked then
    local originalHandle = positionGE.handle
    positionGE.handle = function(rawData)
      if physicsLimiterMP and MPVehicleGE then
        local ok, err = pcall(physicsLimiterMP.onPacket, rawData)
        if not ok then log('E', 'physicsLimiterMP', 'Reading a position packet failed: ' .. tostring(err)) end
      end
      return originalHandle(rawData)
    end
    positionGE._physicsLimiterHooked = true
    log('I', 'physicsLimiterMP', 'Hooked into BeamMP position packets')
  end
end

-- BeamMP places the label of a non-simulated vehicle at its last position packet, updated only about twice a second;
-- the stand-ins' labels follow their predicted pose instead, at the height of a simulated vehicle's label
M.updateLabels = true
local function updateLabels()
  for id, entry in pairs(tracked) do
    if entry.shownPos and not be:getObjectActive(id) then
      local vehicle = MPVehicleGE and MPVehicleGE.getVehicleByGameID(id)
      if vehicle and vehicle.position then
        local height = vehicle.vehicleHeight
        if not height or height == 0 then
          local veh = getObjectByID(id)
          height = veh and veh:getInitialHeight() or 0
        end
        local p = entry.shownPos
        vehicle.position:set(p.x, p.y, p.z + height * 0.65 + 0.2) -- the center of mass is below the middle of the body
      end
    end
  end
end

local function onUpdate(dtReal)
  time = clock:stop() / 1000
  lastDT = dtReal
  installHook()
  for _, entry in pairs(tracked) do predict(entry, dtReal) end
  if M.updateLabels then updateLabels() end
end

local function onVehicleDestroyed(id)
  tracked[id] = nil
  inputs[id] = nil
  broken[id] = nil
  states[id] = nil
  resets[id] = nil
end

local function onClientEndMission()
  table.clear(tracked)
  table.clear(inputs)
  table.clear(broken)
  table.clear(states)
  table.clear(resets)
end

M.isOwn = isOwn
M.startTracking = startTracking
M.stopTracking = stopTracking
M.getPose = getPose
M.getFirstPose = getFirstPose
M.getVelocity = getVelocity
M.getAngularVelocity = getAngularVelocity
M.getUpdateCount = getUpdateCount
M.isTracked = isTracked
M.onPacket = onPacket
M.onInputsPacket = onInputsPacket
M.onNodesPacket = onNodesPacket
M.onVehiclePacket = onVehiclePacket
M.takeReset = takeReset
M.takeBrokenGroups = takeBrokenGroups
M.recordState = recordState
M.takeReplayCommands = takeReplayCommands
M.getInputs = getInputs
M.onUpdate = onUpdate
M.onVehicleDestroyed = onVehicleDestroyed
M.onClientEndMission = onClientEndMission

return M
