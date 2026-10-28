-- Physics Limiter, Copyright (C) 2026 tmaster1000
-- Licensed under the GNU Affero General Public License version 3, see the LICENSE file.
-- Hits on deactivated vehicles: when the bounding box of a simulated vehicle reaches the body of a deactivated vehicle
-- (its stand-in), that vehicle has been run into and is simulated again (physicsLimiter.wakeVehicle); it is deactivated
-- again once the hit is over. The body is the box around the vehicle's nodes without the wheels, placed on the stand-in.
-- Console (GE): physicsLimiterCollision.enabled = false

local M = {}
M.dependencies = {'physicsLimiterStandIns', 'physicsLimiterMP'}

M.enabled = true
M.nearDistance = 40 -- meters; a deactivated vehicle is checked when a simulated one is this close
M.minWakeSpeed = 0.2 -- m/s; minimum relative speed for a hit (standing next to each other wakes nothing)
M.minHitSpeed = 1 -- m/s; a hit is over when the touching vehicles move slower than this relative to each other
M.wakeMargin = 0.25 -- meters; a hit is found when a simulated vehicle's bounding box comes this close to the body
-- a hit is over when nothing has touched the vehicle while moving against it for settleTime seconds
M.settleTime = 0.4
M.contactMargin = 0.4 -- meters; vehicles this close are in contact
M.restSpeed = 1 -- m/s; without a server (single player) it also has to be this slow, or it would stop dead in a slide

local bodies = {} -- by vehicle id: {offset = bottom center in jbeam space, size}
local zero = vec3()

-- the body's bounds in jbeam space: every node except the wheels' (tires, hubs, axles)
local function bodyBounds(vdata)
  local wheelNodes = {}
  for _, w in pairs(vdata.wheels or {}) do
    for _, list in ipairs({w.nodes, w.treadNodes}) do
      for _, cid in pairs(list or {}) do wheelNodes[cid] = true end
    end
    if w.node1 then wheelNodes[w.node1] = true end
    if w.node2 then wheelNodes[w.node2] = true end
  end
  local mn, mx = vec3(math.huge, math.huge, math.huge), vec3(-math.huge, -math.huge, -math.huge)
  local count = 0
  for cid, node in pairs(vdata.nodes or {}) do
    if not wheelNodes[cid] and node.pos then
      local p = node.pos
      mn:set(math.min(mn.x, p.x), math.min(mn.y, p.y), math.min(mn.z, p.z))
      mx:set(math.max(mx.x, p.x), math.max(mx.y, p.y), math.max(mx.z, p.z))
      count = count + 1
    end
  end
  if count < 4 then return end
  return mn, mx
end

-- worked out once; nil while the vehicle's data isn't loaded
local function getBody(id)
  local body = bodies[id]
  if body ~= nil then return body or nil end
  local vehData = core_vehicle_manager.getVehicleData(id)
  local vdata = vehData and vehData.vdata
  if not vdata then return end
  local mn, mx = bodyBounds(vdata)
  if not mn then
    bodies[id] = false
    return
  end
  local size = mx - mn
  body = {offset = vec3((mn.x + mx.x) / 2, (mn.y + mx.y) / 2, mn.z),
    size = vec3(math.max(0.2, size.x), math.max(0.2, size.y), math.max(0.2, size.z))}
  bodies[id] = body
  return body
end

local activePositions = {}
local activeBoxes = {} -- bounding boxes of the simulated vehicles, in the order of activePositions
local hitCars = {} -- vehicles woken by a hit, by id: {lastContact, remote}
local rearm = {} -- released after a hit but still overlapped: gentle contact doesn't wake them until it moved away (a hard hit always does)
local time = 0

local function updateHitCars()
  for id, hit in pairs(hitCars) do
    local own
    for i = 1, #activePositions do
      if activeBoxes[i].id == id then own = activeBoxes[i] break end
    end
    if not own then -- deactivated or gone
      hitCars[id] = nil
    else
      local m = M.contactMargin
      local ax, ay, az = own.x + own.x:normalized() * m, own.y + own.y:normalized() * m, own.z + own.z:normalized() * m
      local contact = false
      for i = 1, #activePositions do
        local other = activeBoxes[i]
        -- touching and still moving against each other: the vehicle can still be deformed (resting against it doesn't)
        if other.id ~= id and (other.velocity - own.velocity):length() > M.minHitSpeed
          and overlapsOBB_OBB(own.center, ax, ay, az, other.center, other.x, other.y, other.z) then
          contact = true
          break
        end
      end
      if contact then
        hit.lastContact = time
      elseif time - hit.lastContact >= M.settleTime and (hit.remote or own.velocity:length() < M.restSpeed) then
        log('I', 'physicsLimiterCollision', string.format('vehicle %d: hit over, deactivated again', id))
        hitCars[id] = nil
        rearm[id] = true
        physicsLimiter.releaseVehicle(id)
      end
    end
  end
end

local function update()
  table.clear(activePositions)
  local vehicles = getAllVehicles()
  for _, veh in ipairs(vehicles) do
    local id = veh:getId()
    if be:getObjectActive(id) and not physicsLimiterStandIns.isProp(veh) and not physicsLimiterStandIns.isNoHits(id) then
      activePositions[#activePositions + 1] = vec3(veh:getPositionXYZ())
      local obb = activeBoxes[#activePositions] or {}
      activeBoxes[#activePositions] = obb
      obb.id = id
      obb.velocity = vec3(veh:getVelocity())
      obb.center = vec3(be:getObjectOOBBCenterXYZ(id))
      obb.x, obb.y, obb.z = vec3(be:getObjectOOBBHalfAxisXYZ(id, 0)), vec3(be:getObjectOOBBHalfAxisXYZ(id, 1)), vec3(be:getObjectOOBBHalfAxisXYZ(id, 2))
    end
  end
  updateHitCars()
  if not M.enabled or not physicsLimiter or activePositions[1] == nil then
    return
  end
  local nearSq = M.nearDistance * M.nearDistance
  for _, veh in ipairs(vehicles) do
    local id = veh:getId()
    if physicsLimiter.isDeactivated(id) and not physicsLimiterStandIns.isNoHits(id) then
      local origin, rot = physicsLimiterStandIns.getPose(id)
      local body = origin and getBody(id)
      if body then
        local near = false
        for _, p in ipairs(activePositions) do
          if p:squaredDistance(origin) < nearSq then near = true break end
        end
        if near then
          local center = origin + rot * (body.offset + vec3(0, 0, body.size.z / 2))
          local m = M.wakeMargin -- the vehicle wakes just before the two touch, so it isn't woken inside the other one
          local hx, hy, hz = rot * vec3(body.size.x / 2 + m, 0, 0), rot * vec3(0, body.size.y / 2 + m, 0), rot * vec3(0, 0, body.size.z / 2 + m)
          local velocity = physicsLimiterMP.isTracked(id) and physicsLimiterMP.getVelocity(id) or zero
          local stillOverlapping = false
          for i = 1, #activePositions do
            local other = activeBoxes[i]
            -- vehicles standing next to each other don't wake each other: they have to be moving relative to each other
            local relativeSpeed = (other.velocity - velocity):length()
            local overlapping = overlapsOBB_OBB(center, hx, hy, hz, other.center, other.x, other.y, other.z)
            stillOverlapping = stillOverlapping or overlapping
            -- gentle contact doesn't wake a released vehicle again (it would wake and deactivate over and over)
            if overlapping and relativeSpeed > M.minWakeSpeed and (not rearm[id] or relativeSpeed > M.minHitSpeed) then
              rearm[id] = nil
              log('I', 'physicsLimiterCollision', string.format('vehicle %d run into (a simulated vehicle at %.1f m, %.1f m/s relative): simulated again',
                id, other.center:distance(center), relativeSpeed))
              hitCars[id] = {lastContact = time, remote = physicsLimiterMP.isTracked(id)}
              physicsLimiter.wakeVehicle(id, true)
              break
            end
          end
          if rearm[id] and not stillOverlapping then rearm[id] = nil end
        elseif rearm[id] then
          rearm[id] = nil
        end
      end
    end
  end
end

local function onUpdate(dtReal)
  time = time + dtReal
  update()
end

local function onVehicleSpawned(id)
  bodies[id] = nil -- spawned again (config change): the new body
end

local function onVehicleDestroyed(id)
  bodies[id] = nil
  hitCars[id] = nil
  rearm[id] = nil
end

local function onClientEndMission()
  table.clear(bodies)
  table.clear(hitCars)
end

M.onUpdate = onUpdate
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleDestroyed = onVehicleDestroyed
M.onClientEndMission = onClientEndMission

return M
