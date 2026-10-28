-- Physics Limiter by tmaster1000
-- Engine sound for the stand-ins (a deactivated vehicle is silent): its own engine and exhaust sound events are played
-- by separate sound sources at the stand-in. BeamMP doesn't send the rpm, so it is estimated from the speed, the gear
-- and the gearbox, with the throttle as the load.

local M = {}

M.enabled = true
M.maxDistance = 250
M.rpmSmoothing = 6 -- 1/s
M.shiftTime = 0.5

local infos = {} -- engine data sent by the vehicle before it was deactivated, by id
local requested = {}
local sounds = {} -- deactivated vehicles with engine sound, by id: {info, rpm, load, gear, shiftTimer, sources}
local eventNames = {} -- sound event of a blend file, by path
local distanceTimer = 0
local mat = MatrixF(true)
local counter = 0

-- sent to the vehicle: its engine, gearbox, wheel and driving data, sent back to setInfo
local vehicleQuery = [[
local e = powertrain.getDevicesByType("combustionEngine")[1] or powertrain.getDevicesByType("electricMotor")[1]
local info = {}
if e then
  local sc = e.soundConfiguration or {}
  local main = sc.engine or sc.motor
  info.engine, info.exhaust = main and main.blendFile, sc.exhaust and sc.exhaust.blendFile
  info.idle, info.max, info.engineNode = e.idleRPM, e.maxRPM, e.engineNodeID
  local ends = e.thermals and e.thermals.exhaustEndNodes
  if ends then
    info.exhaustPoints = {}
    for _, n in ipairs(ends) do
      local nd = n.finish and v.data.nodes[n.finish]
      if nd and nd.pos and #info.exhaustPoints < 2 then info.exhaustPoints[#info.exhaustPoints + 1] = {x = nd.pos.x, y = nd.pos.y, z = nd.pos.z} end
    end
  end
  info.rpm = (e.outputAV1 or 0) * 9.5493
  local gearbox = powertrain.getDevicesByCategory("gearbox")[1]
  if gearbox and type(gearbox.gearRatios) == "table" then
    info.forward, info.reverse = {}, gearbox.gearRatios[-1]
    for i = 1, gearbox.maxGearIndex or 0 do info.forward[i] = gearbox.gearRatios[i] end
    info.gearIndex = gearbox.gearIndex
  end
  local radius, count = 0, 0
  for _, wd in pairs(wheels.wheelRotators or {}) do
    if wd.radius then radius, count = radius + wd.radius, count + 1 end
  end
  info.radius = count > 0 and radius / count or nil
  local wheelSpeed = electrics.values.wheelspeed or 0
  if info.radius and gearbox and gearbox.gearRatio and gearbox.gearRatio ~= 0 and math.abs(wheelSpeed) > 3 then
    info.finalDrive = math.abs((e.outputAV1 or 0) * info.radius / wheelSpeed / gearbox.gearRatio)
  end
  info.throttle, info.gear = electrics.values.throttle, electrics.values.gear
end
obj:queueGameEngineLua("if physicsLimiterSounds then physicsLimiterSounds.setInfo(%d, " .. serialize(info) .. ") end")
]]

local function getEventName(file)
  if eventNames[file] == nil then
    local blend = jsonReadFile(file)
    eventNames[file] = blend and blend.eventName or false
  end
  return eventNames[file]
end

local function request(veh, id)
  if requested[id] then return end
  requested[id] = true
  infos[id] = nil
  veh:queueLuaCommand(string.format(vehicleQuery, id))
end

-- a vehicle that has just spawned may not have set up its powertrain yet and answers without an engine: it is asked
-- again while active (watched from its spawn on, so deactivation isn't delayed) until it has one
local watching = {}
local watchTimer = 0

local function watch(id)
  local veh = getObjectByID(id)
  if not veh then return end
  requested[id] = true
  watching[id] = {tries = 0}
  veh:queueLuaCommand(string.format(vehicleQuery, id))
end

local function updateWatching(dtReal)
  watchTimer = watchTimer - dtReal
  if watchTimer > 0 then return end
  watchTimer = 0.5
  for id, w in pairs(watching) do
    local veh = getObjectByID(id)
    local info = infos[id]
    if not veh or not be:getObjectActive(id) or (info and info.engine) or w.tries >= 20 then
      watching[id] = nil
    elseif requested[id] then
      w.tries = w.tries + 1
      veh:queueLuaCommand(string.format(vehicleQuery, id))
    else
      watching[id] = nil
    end
  end
end

local function finishInfo(id, info)
  local vdata = core_vehicle_manager.getVehicleData(id)
  local nodes = vdata and vdata.vdata and vdata.vdata.nodes
  local node = nodes and info.engineNode and nodes[info.engineNode]
  info.enginePos = node and vec3(node.pos.x, node.pos.y, node.pos.z) or vec3()
  local ref = nodes and vdata.vdata.refNodes and vdata.vdata.refNodes[0] and nodes[vdata.vdata.refNodes[0].ref]
  info.refPos = ref and vec3(ref.pos.x, ref.pos.y, ref.pos.z) or vec3()
  infos[id] = info
end

local function setInfo(id, info)
  if not requested[id] then return end
  finishInfo(id, info)
end

-- the same information from the vehicle's data on this side, for a vehicle that couldn't answer (a deactivated vehicle
-- doesn't run its code, so it can't be asked once it is deactivated); whether the engine is running isn't known then
local function infoFromVehicleData(id)
  local vehData = core_vehicle_manager.getVehicleData(id)
  local vd = vehData and vehData.vdata
  if not (vd and vd.powertrain) then return end
  local device
  for _, wanted in ipairs({'combustionEngine', 'electricMotor'}) do
    for _, d in pairs(vd.powertrain) do
      if type(d) == 'table' and d.type == wanted then device = device or d end
    end
  end
  local params = device and vd[device.name]
  if type(params) ~= 'table' then return end
  local function blend(name)
    local config = name and vd[name]
    return type(config) == 'table' and config.sampleName
      and ((config.sampleFolder or 'art/sound/blends/') .. config.sampleName .. '.sfxBlend2D.json') or nil
  end
  local info = {engine = blend(params.soundConfig) or blend(params.soundConfigMotor), exhaust = blend(params.soundConfigExhaust),
    unknownState = true}
  if not info.engine then return end
  info.idle = tonumber(params.idleRPM) or 0
  info.max = tonumber(params.maxRPM) or tonumber(params.revLimiterRPM)
  if not info.max and type(params.torque) == 'table' and params.torque[#params.torque] then info.max = tonumber(params.torque[#params.torque][1]) end
  info.rpm = info.idle
  local radius, count = 0, 0
  for _, wd in pairs(vd.wheels or {}) do
    if type(wd) == 'table' and tonumber(wd.radius) then radius, count = radius + wd.radius, count + 1 end
  end
  info.radius = count > 0 and radius / count or nil
  for _, d in pairs(vd.powertrain) do
    if type(d) == 'table' and type(d.type) == 'string' then
      local p = vd[d.name]
      if type(p) == 'table' then
        if d.type:find('Gearbox$') and not info.forward and type(p.gearRatios) == 'table' then
          info.reverse = tonumber(p.gearRatios[1]) and math.abs(p.gearRatios[1])
          info.forward = {}
          for i = 3, #p.gearRatios do info.forward[#info.forward + 1] = tonumber(p.gearRatios[i]) end
        elseif d.type == 'differential' and not info.finalDrive and tonumber(p.gearRatio) then
          info.finalDrive = p.gearRatio
        end
      end
    end
  end
  if not (info.forward and info.forward[1]) then info.forward, info.reverse = nil, nil end
  return info
end

-- the vehicle's own sound settings (gains, muffling, EQ) are meant for its engine sound system and mute the plain
-- sound event, so the event is played with its defaults
local function createSource(file, pos)
  local eventName = file and getEventName(file)
  if not eventName then return end
  local sourceId = Engine.Audio.createSource('AudioDefaultLoop3D', eventName)
  local source = sourceId and scenetree.findObjectById(sourceId)
  if not source then return end
  counter = counter + 1
  source:setName('physicsLimiterSound_' .. counter) -- so stopLeftovers can find it after a Lua reload
  mat:setPosition(pos)
  source:setTransform(mat)
  source:play(1, 1)
  return source
end

local function deleteSources(sound)
  for _, source in pairs(sound.sources or {}) do
    source:stop(-1) -- deleting alone leaves the sound playing
    source:delete()
  end
  sound.sources = nil
end

-- the vehicle is being deactivated: it gets engine sound if its engine was running
local function start(id)
  requested[id] = nil
  local info = infos[id]
  if not (info and info.engine) then
    local fromData = infoFromVehicleData(id)
    if fromData then
      finishInfo(id, fromData)
      info = fromData
    end
  end
  if not (info and info.engine and info.idle) then return end
  local gear = 1
  if info.gearIndex and info.gearIndex > 0 then gear = info.gearIndex end
  -- an engine that was off (or isn't known to be running) stays silent until the vehicle moves or gets throttle (then
  -- it is taken to be running)
  sounds[id] = {info = info, rpm = info.rpm, load = info.throttle or 0, gear = gear, shiftTimer = 0,
    off = info.unknownState or info.rpm <= info.idle * 0.5}
end

local function stop(id)
  requested[id] = nil
  local sound = sounds[id]
  if not sound then return end
  deleteSources(sound)
  sounds[id] = nil
end

local function wheelRpm(info, speed, ratio)
  return speed / info.radius * math.abs(ratio) * (info.finalDrive or 3.5) * 9.5493
end

-- the rpm the engine would have at this speed, throttle and gear ('gear' as in electrics.values.gear)
local function targetRpm(sound, speed, throttle, gearValue, dt)
  local info = sound.info
  local idle, max = info.idle, info.max or info.idle * 8
  local free = idle + (max - idle) * 0.8 * throttle -- revving freely, in neutral or slipping at low speed
  if not (info.radius and info.forward and info.forward[1]) then
    return speed > 1 and idle + (max - idle) * (0.25 + 0.5 * throttle) or free
  end
  local gearText = tostring(gearValue or 'D')
  local fixed = tonumber(gearText) or tonumber(gearText:match('^%a(%d+)$') or '')
  local rpm
  if (gearText == 'N' or gearText == 'P') and speed < 3 then -- moving, the gear is more likely outdated
    return free
  elseif gearText == 'R' then
    rpm = wheelRpm(info, speed, info.reverse or info.forward[1])
  elseif fixed and info.forward[fixed] then
    rpm = wheelRpm(info, speed, info.forward[fixed])
  else -- automatic: estimated shifts, later with more throttle, and down again (kickdown) when it is pressed
    sound.shiftTimer = sound.shiftTimer - dt
    local gear = math.min(sound.gear, #info.forward)
    rpm = wheelRpm(info, speed, info.forward[gear])
    if sound.shiftTimer <= 0 then
      local up = idle + (max - idle) * (0.25 + 0.5 * throttle)
      local down = idle + (max - idle) * (0.12 + 0.35 * throttle)
      if gear < #info.forward and rpm > up then
        gear, sound.shiftTimer = gear + 1, M.shiftTime
      elseif gear > 1 and rpm < down and wheelRpm(info, speed, info.forward[gear - 1]) < up * 0.85 then
        gear, sound.shiftTimer = gear - 1, M.shiftTime -- only if the lower gear won't shift right back up
      end
    end
    sound.gear = gear
    rpm = wheelRpm(info, speed, info.forward[gear])
  end
  if rpm < free and speed < 5 then rpm = free * (1 - speed / 5) + rpm * speed / 5 end
  return math.min(math.max(rpm, idle), max)
end

local function updateSound(id, sound, dt)
  local origin, rot = physicsLimiterStandIns.getPose(id)
  if not origin then return end
  local info = sound.info
  local vel = physicsLimiterMP and physicsLimiterMP.getVelocity(id)
  local speed = vel and vel:length() or 0
  local throttle, gear = nil, nil
  if physicsLimiterMP then throttle, gear = physicsLimiterMP.getInputs(id) end
  throttle = clamp(throttle or info.throttle or 0, 0, 1)
  gear = gear or info.gear

  local f = math.min(1, dt * M.rpmSmoothing)
  sound.rpm = sound.rpm + (targetRpm(sound, speed, throttle, gear, dt) - sound.rpm) * f
  sound.load = sound.load + (throttle - sound.load) * f
  local positions = {engine = origin + rot * info.enginePos, exhaust = origin + rot * info.refPos}
  for part, source in pairs(sound.sources) do
    source:setParameter('RPM', sound.rpm)
    source:setParameter('Load', sound.load)
    mat:setPosition(positions[part])
    source:setTransform(mat)
  end
end

-- sources only exist for deactivated vehicles near the camera
local function updateDistances()
  local camPos = core_camera.getPosition()
  if not M.enabled then
    for _, sound in pairs(sounds) do
      if sound.sources then deleteSources(sound) end
    end
    return
  end
  for id, sound in pairs(sounds) do
    local origin, rot = physicsLimiterStandIns.getPose(id)
    local dist = origin and origin:distance(camPos) or math.huge
    if sound.off and physicsLimiterMP then
      local vel = physicsLimiterMP.getVelocity(id)
      local throttle = physicsLimiterMP.getInputs(id)
      if (vel and vel:length() > 0.5) or (throttle or 0) > 0.05 then sound.off = false end
    end
    if sound.off or physicsLimiterStandIns.isHiddenOverride(id) then
      if sound.sources then deleteSources(sound) end
    elseif not sound.sources and dist < M.maxDistance then
      local info = sound.info
      sound.sources = {
        engine = createSource(info.engine, origin + rot * info.enginePos),
        exhaust = createSource(info.exhaust, origin + rot * info.refPos)
      }
    elseif sound.sources and dist > M.maxDistance + 25 then
      deleteSources(sound)
    end
  end
end

local function onVehicleSpawned(id)
  local veh = getObjectByID(id)
  if not veh or physicsLimiterStandIns.isProp(veh) then return end
  watch(id)
end

local function onUpdate(dtReal, dtSim)
  updateWatching(dtReal)
  distanceTimer = distanceTimer - dtReal
  if distanceTimer <= 0 then
    distanceTimer = 0.5
    updateDistances()
  end
  for id, sound in pairs(sounds) do
    if sound.sources then updateSound(id, sound, dtSim) end
  end
end

local function onVehicleDestroyed(id)
  stop(id)
  infos[id] = nil
end

-- the sources keep playing when only deleted, and aren't part of the level: they are stopped when it ends, and the
-- ones from before a Lua reload (which this module no longer knows) are found by their name
local function stopLeftovers()
  for _, name in ipairs(scenetree.findClassObjects('SFXFMODEventSource') or {}) do
    if name:find('^physicsLimiterSound_') then
      local source = scenetree.findObject(name)
      if source then
        pcall(source.stop, source, -1)
        source:delete()
      end
    end
  end
end

local function onExtensionLoaded()
  stopLeftovers()
end

local function onClientEndMission()
  for id in pairs(sounds) do stop(id) end
  stopLeftovers()
  table.clear(infos)
  table.clear(requested)
end

M.getInfo = function(id) return infos[id] end -- for physicsLimiterParticles
M.request = request
M.setInfo = setInfo
M.start = start
M.stop = stop
M.onUpdate = onUpdate
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleDestroyed = onVehicleDestroyed
M.onClientEndMission = onClientEndMission
M.onExtensionLoaded = onExtensionLoaded

return M
