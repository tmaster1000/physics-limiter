-- Physics Limiter by tmaster1000
-- Stand-ins for vehicles deactivated by physicsLimiter: a static copy of the vehicle's visible parts in their undamaged
-- shape, the body merged into one object and each wheel's tire and rim into one, so the wheels roll and steer. Built once
-- per model (when its first vehicle spawns, or ahead of time by physicsLimiterPrebuild) and saved; a livery is a copy of
-- the mesh files with the livery's material names. A stand-in's objects are created a few at a time while the vehicle is
-- still active.

local M = {}
M.dependencies = {'physicsLimiterMerge', 'physicsLimiterMeshSource'}

M.boxFolder = '/temp/physicsLimiterBox/'
M.skinFolder = '/temp/physicsLimiterSkins/' -- copies of meshes using a vehicle's livery materials
M.frameBudget = 1.5
M.maxDistance = 500
M.visibilityPerFrame = 1
M.visibilityInterval = 0.05
M.targetFps = 60 -- stand-ins beyond the nearest ones are drawn as a box while the frame rate is below this; 0 turns it off
M.minFull = 4
M.rankMargin = 2 -- a stand-in changes between full and box only when this many places past the limit (no flicker)
M.controlInterval = 0.5
M.showFramesBeforeFreeze = 2 -- frames the stand-in is shown together with the still active vehicle
M.maxSteerAngle = 30 -- degrees the front wheels of a stand-in turn at full steering, if the model's own can't be worked out
M.suspension = true
M.suspensionDistance = 60
M.maxTravel = 0.15
M.suspensionRate = 14
M.tireCompression = 0.015 -- meters a parked car's tires are pressed together by its weight
M.burnoutSpeed = 4 -- m/s; a driven wheel with full throttle below this speed spins faster than the ground moves
M.burnoutWheelSpeed = 40
M.driftSlip = 3 -- m/s sideways at which the rear wheels of a moving vehicle smoke (the front ones at 2.5 times that)
M.driftMinSpeed = 6

local vehicleInfo = {} -- by vehicle id: {parts = {{path, placement, wheel, wheelCenter}}, wheels, refPos, cog}, the
-- parts and wheels being its model's template
local entries = {} -- by vehicle id: {info, objs, paint, placed, hidden, pos, origin, rot}

local keepers = {} -- one hidden object per loaded mesh, so the engine keeps the mesh in memory, by path
local counter = 0
local visibilityTimer = 0
local identityRot = quat(0, 0, 0, 1)
local zero = vec3()
local cameraPos = vec3()
local fullCount = math.huge -- the nearest stand-ins drawn in full, the rest in range as a box
local inRange = 0
local frameSum, frameCount, controlTimer, clock = 0, 0, 0, 0
local control = {steps = 0, reduced = false, holdUntil = 0}
local boxPath, boxMaterialLoaded
local frameMs

local function colorString(c)
  local ok, str = pcall(function() return string.format('%f %f %f %f', c.x, c.y, c.z, c.w) end)
  return ok and str or nil
end

local function newStatic(path, name)
  local static = createObject('TSStatic')
  static:setField('shapeName', 0, path)
  static:setField('decalType', 0, 'None')
  static:setField('collisionType', 0, 'None')
  static:setField('dynamic', 0, '1') -- otherwise it is drawn as never moving, which makes moving stand-ins step
  static.canSave = false
  counter = counter + 1
  static:registerObject(name .. counter)
  return static
end

local function keep(path)
  if not keepers[path] then
    local keeper = newStatic(path, 'physicsLimiterKeeper_')
    keeper:setHidden(true)
    scenetree.MissionGroup:addObject(keeper.obj)
    keepers[path] = keeper
  end
  return keepers[path]
end

-- a unit cube with a material that takes the vehicle's paint colour; a far stand-in is this, scaled to the vehicle's size
local function ensureBox()
  if boxPath then return boxPath end
  local daePath, materialPath = M.boxFolder .. '_box.dae', M.boxFolder .. '_box.materials.json'
  FS:directoryCreate(M.boxFolder)
  if not FS:fileExists(materialPath) then
    jsonWriteFile(materialPath, {['physicsLimiter.box'] = {name = 'physicsLimiter.box', mapTo = 'physicsLimiter.box', class = 'Material',
      Stages = {{instanceDiffuse = true, baseColorFactor = {1, 1, 1, 1}, metallicFactor = 0.5, roughnessFactor = 0.4,
        clearCoatFactor = 1, clearCoatRoughnessFactor = 0.06}, {}, {}, {}}, version = 1}}, true)
  end
  if not FS:fileExists(daePath) then
    local faces = {
      {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}, {{-1, 0, 0}, {0, 0, 1}, {0, 1, 0}}, {{0, 1, 0}, {0, 0, 1}, {1, 0, 0}},
      {{0, -1, 0}, {1, 0, 0}, {0, 0, 1}}, {{0, 0, 1}, {1, 0, 0}, {0, 1, 0}}, {{0, 0, -1}, {0, 1, 0}, {1, 0, 0}}}
    local pos, nrm, uv, tri = {}, {}, {}, {}
    for f, face in ipairs(faces) do
      local n, u, v = face[1], face[2], face[3]
      for _, c in ipairs({{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}) do
        for a = 1, 3 do pos[#pos + 1] = string.format('%g', 0.5 * (n[a] + c[1] * u[a] + c[2] * v[a])) end
        nrm[#nrm + 1] = string.format('%d %d %d', n[1], n[2], n[3])
        uv[#uv + 1] = string.format('%d %d', (c[1] + 1) / 2, (c[2] + 1) / 2)
      end
      local b = (f - 1) * 4
      tri[#tri + 1] = string.format('%d %d %d %d %d %d', b, b + 1, b + 2, b, b + 2, b + 3)
    end
    local function source(id, values, stride, count, names)
      return string.format('<source id="%s"><float_array id="%s-array" count="%d">%s</float_array><technique_common><accessor source="#%s-array" count="24" stride="%d">%s</accessor></technique_common></source>',
        id, id, count, values, id, stride, names)
    end
    writeFile(daePath, table.concat({
      '<?xml version="1.0" encoding="utf-8"?>',
      '<COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">',
      '<asset><unit name="meter" meter="1"/><up_axis>Z_UP</up_axis></asset>',
      '<library_effects><effect id="boxeffect"><profile_COMMON><technique sid="common"><phong><diffuse><color>1 1 1 1</color></diffuse></phong></technique></profile_COMMON></effect></library_effects>',
      '<library_materials><material id="boxmaterial" name="physicsLimiter.box"><instance_effect url="#boxeffect"/></material></library_materials>',
      '<library_geometries><geometry id="gbox" name="gbox"><mesh>',
      source('gboxpos', table.concat(pos, ' '), 3, 72, '<param name="X" type="float"/><param name="Y" type="float"/><param name="Z" type="float"/>'),
      source('gboxnrm', table.concat(nrm, ' '), 3, 72, '<param name="X" type="float"/><param name="Y" type="float"/><param name="Z" type="float"/>'),
      source('gboxuv', table.concat(uv, ' '), 2, 48, '<param name="S" type="float"/><param name="T" type="float"/>'),
      '<vertices id="gboxvert"><input semantic="POSITION" source="#gboxpos"/></vertices>',
      '<triangles material="boxsymbol" count="12"><input semantic="VERTEX" source="#gboxvert" offset="0"/><input semantic="NORMAL" source="#gboxnrm" offset="0"/><input semantic="TEXCOORD" source="#gboxuv" offset="0" set="0"/><p>',
      table.concat(tri, ' '), '</p></triangles></mesh></geometry></library_geometries>',
      '<library_visual_scenes><visual_scene id="Scene" name="Scene"><node id="standinBox" name="standinBox" type="NODE"><instance_geometry url="#gbox"><bind_material><technique_common><instance_material symbol="boxsymbol" target="#boxmaterial"/></technique_common></bind_material></instance_geometry></node></visual_scene></library_visual_scenes>',
      '<scene><instance_visual_scene url="#Scene"/></scene>',
      '</COLLADA>'}, '\n'))
  end
  if not boxMaterialLoaded then
    boxMaterialLoaded = true
    if loadJsonMaterialsFile then loadJsonMaterialsFile(materialPath) end
  end
  boxPath = daePath
  return boxPath
end

-- a livery is a set of materials named '<material>.skin.<livery>'; meshes refer to the plain material, so a copy of the mesh file with those materials renamed is made for it
local materialNameCache = {}
local function materialNamesOf(path) -- (read from the file: loading the mesh to ask it would take a while)
  if not materialNameCache[path] then
    local names = {}
    local library = (readFile(path) or ''):match('<library_materials>(.-)</library_materials>') or ''
    for name in library:gmatch('<material [^>]-name="([^"]*)"') do names[#names + 1] = name end
    materialNameCache[path] = names
  end
  return materialNameCache[path]
end

local function getSkinnedPath(path, model, skinnedNames)
  local remap, suffixes, seen = {}, {}, {}
  for _, name in ipairs(materialNamesOf(path)) do
    local skinned = skinnedNames[name]
    if skinned then
      remap[name] = skinned
      local suffix = skinned:sub(#name + 1)
      if not seen[suffix] then
        seen[suffix] = true
        table.insert(suffixes, suffix)
      end
    end
  end
  if not suffixes[1] then return path end
  table.sort(suffixes)

  -- the copy is named by the time the mesh file was written, so a rebuilt mesh gets a new copy (the old ones are removed)
  local stat = FS:stat(path)
  local folder = M.skinFolder .. model .. '/'
  local prefix = path:match('([^/]+)%.dae$') .. table.concat(suffixes):gsub('[^%w_.-]', '_')
  local skinPath = folder .. prefix .. '.' .. tostring(stat and stat.modtime or 0) .. '.dae'
  if not FS:fileExists(skinPath) then
    local pattern = '^' .. prefix:gsub('%p', '%%%0') .. '%.%d+%.dae$'
    for _, old in ipairs(FS:findFiles(folder, '*.dae', 0, true, false) or {}) do
      if old ~= skinPath and old:match('([^/]+)$'):match(pattern) then FS:removeFile(old) end
    end
    local text = readFile(path)
    if not text then return path end
    local libStart, libEnd = text:find('<library_materials>', 1, true), text:find('</library_materials>', 1, true)
    if not (libStart and libEnd) then return path end
    local lib = text:sub(libStart, libEnd)
    for name, skinned in pairs(remap) do
      lib = lib:gsub('name="' .. name:gsub('%p', '%%%0') .. '"', 'name="' .. skinned .. '"')
    end
    FS:directoryCreate(M.skinFolder .. model .. '/')
    if not writeFile(skinPath, text:sub(1, libStart - 1) .. lib .. text:sub(libEnd + 1)) then return path end
  end
  return skinPath
end

-- a part's placement on the vehicle from its jbeam definition (pos, rot as +Z +X +Y intrinsic euler degrees, scale), the same
-- transformation the game applies to the mesh before binding it to the nodes
local function placement(flexbody)
  if not (flexbody.pos or flexbody.rot or flexbody.scale) then return end
  local function v(t, d) return t and vec3(tonumber(t.x) or d, tonumber(t.y) or d, tonumber(t.z) or d) or vec3(d, d, d) end
  local rotDeg = v(flexbody.rot, 0)
  local rot = quatFromAxisAngle(vec3(0, 1, 0), math.rad(rotDeg.y))
    * quatFromAxisAngle(vec3(1, 0, 0), math.rad(rotDeg.x))
    * quatFromAxisAngle(vec3(0, 0, 1), math.rad(rotDeg.z))
  return {pos = v(flexbody.pos, 0), rot = rot, scale = v(flexbody.scale, 1)}
end

-- the wheels: axle center and direction, radius, width, whether they steer
local function findWheels(vdata)
  local wheels = {}
  local nodes = vdata and vdata.nodes
  for _, wd in pairs(vdata and vdata.wheels or {}) do
    local n1, n2 = nodes[wd.node1], nodes[wd.node2]
    if n1 and n2 then
      local p1, p2 = vec3(n1.pos.x, n1.pos.y, n1.pos.z), vec3(n2.pos.x, n2.pos.y, n2.pos.z)
      local axis = (p2 - p1):normalized()
      if axis.x < 0 then axis = -axis end -- rolling forward (-y) is then a positive rotation about it
      table.insert(wheels, {
        center = (p1 + p2) * 0.5, axis = axis, radius = math.max(wd.radius or wd.hubRadius or 0.35, 0.1),
        rimRadius = math.max(wd.hubRadius or (wd.radius or 0.35) * 0.6, 0.05),
        width = math.max(wd.tireWidth or 0, wd.hubWidth or 0, 0.2)
      })
    end
  end
  local frontY
  for _, w in ipairs(wheels) do frontY = math.min(frontY or w.center.y, w.center.y) end
  for _, w in ipairs(wheels) do w.front = w.center.y < frontY + 0.5 end -- the jbeam front is -y
  return wheels
end

-- the wheel a part is the tire, rim or hubcap of (the center of its mesh lies on the wheel's axle, and it is at least
-- as big as the rim; brakes and the like are smaller), the center it turns about and its diameter
local function wheelPartOf(candidate, wheels)
  local center = vec3()
  for _, p in ipairs(candidate.check) do center = center + p end
  center = center * (1 / math.max(1, #candidate.check))
  local best, bestAlong
  for index, w in ipairs(wheels) do
    local rel = center - w.center
    local along = math.abs(rel:dot(w.axis))
    if (rel - w.axis * rel:dot(w.axis)):length() < 0.3 and along < w.width + 0.25 and (not bestAlong or along < bestAlong) then
      best, bestAlong = index, along
    end
  end
  if not best then return end
  local lo, hi = candidate.lo, candidate.hi
  local w = wheels[best]
  local meshCenter = (lo + hi) * 0.5
  local rel = meshCenter - w.center
  local diameter = math.max(hi.y - lo.y, hi.z - lo.z)
  if (rel - w.axis * rel:dot(w.axis)):length() < 0.08 and diameter < 2 * w.radius + 0.15 and diameter > 1.8 * w.rimRadius then
    -- turned about the center of its own mesh: the axle nodes can be a few centimeters off it, which wobbles
    return best, meshCenter, diameter
  end
end

-- a vehicle model's stand-in template (shared by every vehicle of that model and livery): the body and per wheel its tire
-- and rim, each merged into one mesh; built from the model's default configuration, without spawning a vehicle
-- the model's parts that have a mesh: {text, placement, lo, hi (bounds on the vehicle), check (sample points), triangles}
local function gatherCandidates(model, vdata)
  local wanted, flexbodies = {}, {}
  for _, flexbody in pairs(vdata and vdata.flexbodies or {}) do
    local mesh = flexbody.originalMesh or flexbody.mesh
    local nodes = flexbody['_group_nodes']
    if mesh and (not nodes or #nodes > 0) then -- the game makes no mesh of a flexbody without nodes
      wanted[mesh] = true
      flexbodies[#flexbodies + 1] = {flexbody = flexbody, mesh = mesh}
    end
  end
  local texts = physicsLimiterMeshSource.find(model, wanted)
  local candidates = {}
  for _, item in ipairs(flexbodies) do
    local text = texts[item.mesh]
    local place = placement(item.flexbody)
    local box = text and physicsLimiterMerge.bounds(text, place)
    if box then
      table.insert(candidates, {text = text, placement = place, check = box.check, count = box.count, lo = box.lo, hi = box.hi,
        triangles = box.triangles})
    end
  end
  return candidates
end

-- the wheels' parts (by wheel) and all the vehicle's other parts
local function classify(candidates, wheels)
  local others, onWheels = {}, {}
  for _, candidate in ipairs(candidates) do
    local wheel, wheelCenter, diameter = wheelPartOf(candidate, wheels)
    if wheel then
      onWheels[wheel] = onWheels[wheel] or {}
      table.insert(onWheels[wheel], {candidate = candidate, center = wheelCenter, diameter = diameter})
    else
      table.insert(others, candidate)
    end
  end
  return others, onWheels
end

-- the biggest parts that fit in the triangle budget
local function limitTriangles(parts, budget)
  table.sort(parts, function(a, b) return (a.hi - a.lo):length() > (b.hi - b.lo):length() end)
  local kept, total = {}, 0
  for _, part in ipairs(parts) do
    if total + part.triangles <= budget then
      kept[#kept + 1] = part
      total = total + part.triangles
    end
  end
  return kept
end

local function buildTemplate(model, key, vdata, skinnedNames)
  local info = {parts = {}, wheels = findWheels(vdata)}

  local candidates = gatherCandidates(model, vdata)
  local body, onWheels = classify(candidates, info.wheels)
  body = limitTriangles(body, physicsLimiterMerge.triangleBudget)
  -- per wheel the tire and the rim (the biggest part on its axle, and the biggest of the rest; hubcaps sit inside),
  -- merged into one object that turns about the tire's center
  for wheel, list in pairs(onWheels) do
    table.sort(list, function(a, b) return a.diameter > b.diameter end)
    local merged = physicsLimiterMerge.build(key .. '_wheel' .. wheel, {list[1].candidate, list[2] and list[2].candidate}, skinnedNames)
    if not merged then return end
    table.insert(info.parts, {path = merged, wheel = wheel, wheelCenter = list[1].center})
    info.hasWheelParts = true
  end
  -- all the other parts are merged into one object
  if body[1] then
    local merged = physicsLimiterMerge.build(key .. '_body', body, skinnedNames,
      {byMaterial = true, dropSmallerThan = physicsLimiterMerge.dropSmallerThan})
    if not merged then return end
    table.insert(info.parts, 1, {path = merged})
  end
  return info
end

-- templates are saved per model and livery, so they are built only once
local templateVersion = 5
local templates = {}

local function templateFile(key)
  return physicsLimiterMerge.folder .. key .. '.json'
end

local function saveTemplate(key, info)
  local function v(p) return p and {p.x, p.y, p.z} end
  local function q(r) return r and {r.x, r.y, r.z, r.w} end
  local data = {version = templateVersion, hasWheelParts = info.hasWheelParts, parts = {}, wheels = {}}
  for _, w in ipairs(info.wheels) do
    table.insert(data.wheels, {center = v(w.center), axis = v(w.axis), radius = w.radius, rimRadius = w.rimRadius, width = w.width, front = w.front})
  end
  for _, part in ipairs(info.parts) do
    local p = part.placement
    table.insert(data.parts, {path = part.path, wheel = part.wheel, wheelCenter = v(part.wheelCenter),
      placement = p and {pos = v(p.pos), rot = q(p.rot), scale = v(p.scale)}})
  end
  FS:directoryCreate(physicsLimiterMerge.folder)
  jsonWriteFile(templateFile(key), data)
end

local function loadTemplate(key)
  local data = jsonReadFile(templateFile(key))
  if not (data and data.version == templateVersion and data.parts) then return end
  local function v(t) return t and vec3(t[1], t[2], t[3]) end
  local info = {parts = {}, wheels = {}, hasWheelParts = data.hasWheelParts}
  for _, w in ipairs(data.wheels or {}) do
    table.insert(info.wheels, {center = v(w.center), axis = v(w.axis), radius = w.radius, rimRadius = w.rimRadius, width = w.width, front = w.front})
  end
  for _, part in ipairs(data.parts) do
    local p = part.placement
    if not FS:fileExists(part.path) then return end -- removed from the cache: built again
    table.insert(info.parts, {path = part.path, wheel = part.wheel, wheelCenter = v(part.wheelCenter),
      placement = p and {pos = v(p.pos), rot = quat(p.rot[1], p.rot[2], p.rot[3], p.rot[4]), scale = v(p.scale)}})
  end
  return info
end

-- what is worked out per vehicle from its own data when it spawns (nothing of it is saved with the template, as a
-- model's configurations differ): per template wheel how far it turns at full steering and whether the engine drives it
local function nodePos(vdata, cid)
  local n = cid and vdata.nodes and vdata.nodes[cid]
  return n and n.pos and vec3(n.pos.x, n.pos.y, n.pos.z)
end

-- how far (radians) a wheel turns when the steering hydros are at their limits: one end of the hydro (R) is tied to the
-- wheel's steering arm (A) by a tie rod; at a limit R has moved, and the arm turns about the steering axis to keep the
-- tie rod's length
local function steerLimit(vdata, wd, center)
  local up, down = nodePos(vdata, wd.steerAxisUp), nodePos(vdata, wd.steerAxisDown)
  if not (up and down) then return end
  local axis = (up - down):normalized()
  local function axisDistance(p)
    local r = p - down
    return (r - axis * r:dot(axis)):length()
  end
  local hydroBeams, hydroEnds = {}, {}
  for _, h in pairs(vdata.hydros or {}) do
    if h.inputSource == 'steering' or h.inputSource == 'steering_input' then
      local beam = vdata.beams and vdata.beams[h.beamCID]
      if beam then
        hydroBeams[h.beamCID] = true
        hydroEnds[beam.id1], hydroEnds[beam.id2] = {hydro = h, other = beam.id2}, {hydro = h, other = beam.id1}
      end
    end
  end
  -- the tie rod: a beam from a hydro end to a node on the wheel's knuckle
  local best, bestDist
  for cid, beam in pairs(vdata.beams or {}) do
    if not hydroBeams[cid] then
      for _, pair in ipairs({{beam.id1, beam.id2}, {beam.id2, beam.id1}}) do
        local end_, arm = hydroEnds[pair[1]], pair[2]
        if end_ then
          local ra, aa = nodePos(vdata, pair[1]), nodePos(vdata, arm)
          if ra and aa and arm ~= wd.steerAxisUp and arm ~= wd.steerAxisDown and axisDistance(aa) > 0.03
            and axisDistance(aa) < 0.4 and aa:distance(center) < 0.8 then
            local d = ra:distance(center)
            if not bestDist or d < bestDist then best, bestDist = {rack = pair[1], arm = arm, hydro = end_.hydro, other = end_.other}, d end
          end
        end
      end
    end
  end
  if not best then return end
  local R, F, A = nodePos(vdata, best.rack), nodePos(vdata, best.other), nodePos(vdata, best.arm)
  local fixed = R - F
  local hydroLength = fixed:length()
  if hydroLength < 1e-3 then return end
  local direction = fixed * (1 / hydroLength)
  local tie = A:distance(R)
  local r = A - down
  local function armAt(theta)
    local c, sn = math.cos(theta), math.sin(theta)
    return down + r * c + axis:cross(r) * sn + axis * (axis:dot(r) * (1 - c))
  end
  local function angleFor(ratio)
    local moved = R + direction * (hydroLength * ((ratio or 1) - 1))
    local first = armAt(0):distance(moved) - tie
    if math.abs(first) < 1e-6 then return 0 end
    local found
    for dir = 1, -1, -2 do
      local prev = first
      for i = 1, 140 do
        local e = armAt(dir * math.rad(i * 0.5)):distance(moved) - tie
        if (e > 0) ~= (prev > 0) then
          local angle = math.rad((i - 1 + prev / (prev - e)) * 0.5)
          if not found or angle < found then found = angle end
          break
        end
        prev = e
      end
    end
    return found
  end
  local h = best.hydro
  local out, inn = angleFor(h.outLimit), angleFor(h.inLimit)
  local angle = out and inn and (out + inn) * 0.5 or out or inn
  if angle and angle >= math.rad(8) and angle <= math.rad(55) then return angle end
end

local steerCache = {}

local function vehicleExtras(vdata, wheels, model)
  local extras = {wheels = {}}
  local vehicleWheels = {}
  for _, wd in pairs(vdata.wheels or {}) do
    local a, b = nodePos(vdata, wd.node1), nodePos(vdata, wd.node2)
    if a and b then table.insert(vehicleWheels, {wd = wd, center = (a + b) * 0.5}) end
  end
  for index, w in ipairs(wheels) do
    local best, bestDist
    for _, vw in ipairs(vehicleWheels) do
      local d = vw.center:distance(w.center)
      if d < 0.35 and (not bestDist or d < bestDist) then best, bestDist = vw, d end
    end
    if best then
      local key = model .. ':' .. index
      if steerCache[key] == nil then
        local ok, steer = pcall(steerLimit, vdata, best.wd, best.center)
        steerCache[key] = ok and steer or false
      end
      extras.wheels[index] = {steer = steerCache[key] or nil, driven = (tonumber(best.wd.propulsed) or 0) > 0}
    end
  end
  return extras
end

-- a coarse shape of a vehicle (a couple of hundred triangles) that is drawn in place of its stand-in when it is far away
-- or the frame rate target needs it: the outline of the body along its length (top, bottom and width of each slice,
-- the wheels filling the bottom where they are), lofted into one mesh in the vehicle's own space; built once per model
M.proxySlices = 24
local proxyVersion = 1

local function proxyMesh(vdata, wheels)
  local wheelNodes = {}
  for _, w in pairs(vdata.wheels or {}) do
    for _, list in ipairs({w.nodes, w.treadNodes}) do
      for _, cid in pairs(list or {}) do wheelNodes[cid] = true end
    end
    if w.node1 then wheelNodes[w.node1] = true end
    if w.node2 then wheelNodes[w.node2] = true end
  end
  local points, minY, maxY, sumX = {}, math.huge, -math.huge, 0
  for cid, node in pairs(vdata.nodes or {}) do
    local p = node.pos
    if p and not wheelNodes[cid] then
      points[#points + 1] = p
      minY, maxY, sumX = math.min(minY, p.y), math.max(maxY, p.y), sumX + p.x
    end
  end
  local slices = M.proxySlices
  if #points < 20 or maxY - minY < 1 then return end
  local cx = sumX / #points
  local step = (maxY - minY) / slices
  local top, bottom, half = {}, {}, {}
  for _, p in ipairs(points) do
    local i = math.min(slices, math.floor((p.y - minY) / step) + 1)
    top[i] = math.max(top[i] or -math.huge, p.z)
    bottom[i] = math.min(bottom[i] or math.huge, p.z)
    half[i] = math.max(half[i] or 0, math.abs(p.x - cx))
  end
  local filled = {}
  for i = 1, slices do filled[i] = top[i] ~= nil end
  for i = 1, slices do
    if not filled[i] then
      local a, b = i - 1, i + 1
      while a >= 1 and not filled[a] do a = a - 1 end
      while b <= slices and not filled[b] do b = b + 1 end
      local pa, pb = a >= 1 and a or b, b <= slices and b or a
      top[i], bottom[i], half[i] = (top[pa] + top[pb]) / 2, (bottom[pa] + bottom[pb]) / 2, (half[pa] + half[pb]) / 2
    end
  end
  for _, w in ipairs(wheels or {}) do
    local first = math.max(1, math.floor((w.center.y - w.radius * 0.8 - minY) / step) + 1)
    local last = math.min(slices, math.floor((w.center.y + w.radius * 0.8 - minY) / step) + 1)
    for i = first, last do
      bottom[i] = math.min(bottom[i], w.center.z - w.radius)
      half[i] = math.max(half[i], math.abs(w.center.x - cx) + (w.width or 0.2) / 2)
    end
  end
  local function smooth(values)
    local out = {}
    for i = 1, slices do out[i] = (values[math.max(1, i - 1)] + values[i] * 2 + values[math.min(slices, i + 1)]) / 4 end
    return out
  end
  top, half = smooth(top), smooth(half)
  local function ring(k)
    local a, b = math.max(1, k), math.min(slices, k + 1)
    local t, bo, h = (top[a] + top[b]) / 2, (bottom[a] + bottom[b]) / 2, (half[a] + half[b]) / 2 + 0.02
    t = math.max(t, bo + 0.15)
    local y = minY + k * step
    return {vec3(cx - h, y, bo), vec3(cx + h, y, bo), vec3(cx + h, y, t), vec3(cx - h, y, t)}
  end
  local verts, norms, indices = {}, {}, {}
  local function quad(a, b, c, d, outward)
    local normal = (b - a):cross(c - a)
    if normal:dot(outward) < 0 then
      a, b, c, d = d, c, b, a
      normal = (b - a):cross(c - a)
    end
    normal = normal:normalized()
    local base = #verts
    for _, p in ipairs({a, b, c, d}) do
      verts[#verts + 1] = p
      norms[#norms + 1] = normal
    end
    indices[#indices + 1] = string.format('%d %d %d %d %d %d', base, base + 1, base + 2, base, base + 2, base + 3)
  end
  local rings = {}
  for k = 0, slices do rings[k] = ring(k) end
  for k = 0, slices - 1 do
    local p, q = rings[k], rings[k + 1]
    quad(p[1], p[2], q[2], q[1], vec3(0, 0, -1))
    quad(p[4], p[3], q[3], q[4], vec3(0, 0, 1))
    quad(p[1], p[4], q[4], q[1], vec3(-1, 0, 0))
    quad(p[2], p[3], q[3], q[2], vec3(1, 0, 0))
  end
  quad(rings[0][1], rings[0][2], rings[0][3], rings[0][4], vec3(0, -1, 0))
  quad(rings[slices][1], rings[slices][2], rings[slices][3], rings[slices][4], vec3(0, 1, 0))
  local pos, nrm, uv = {}, {}, {}
  for i, p in ipairs(verts) do
    pos[#pos + 1] = string.format('%.4f %.4f %.4f', p.x, p.y, p.z)
    nrm[#nrm + 1] = string.format('%.4f %.4f %.4f', norms[i].x, norms[i].y, norms[i].z)
    uv[#uv + 1] = '0 0'
  end
  local count = #verts
  local function source(id, values, stride, names)
    return string.format('<source id="%s"><float_array id="%s-array" count="%d">%s</float_array><technique_common><accessor source="#%s-array" count="%d" stride="%d">%s</accessor></technique_common></source>',
      id, id, count * stride, table.concat(values, ' '), id, count, stride, names)
  end
  local xyz = '<param name="X" type="float"/><param name="Y" type="float"/><param name="Z" type="float"/>'
  return table.concat({
    '<?xml version="1.0" encoding="utf-8"?>',
    '<COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">',
    '<asset><unit name="meter" meter="1"/><up_axis>Z_UP</up_axis></asset>',
    '<library_effects><effect id="boxeffect"><profile_COMMON><technique sid="common"><phong><diffuse><color>1 1 1 1</color></diffuse></phong></technique></profile_COMMON></effect></library_effects>',
    '<library_materials><material id="boxmaterial" name="physicsLimiter.box"><instance_effect url="#boxeffect"/></material></library_materials>',
    '<library_geometries><geometry id="gproxy" name="gproxy"><mesh>',
    source('gproxypos', pos, 3, xyz), source('gproxynrm', nrm, 3, xyz),
    source('gproxyuv', uv, 2, '<param name="S" type="float"/><param name="T" type="float"/>'),
    '<vertices id="gproxyvert"><input semantic="POSITION" source="#gproxypos"/></vertices>',
    string.format('<triangles material="boxsymbol" count="%d"><input semantic="VERTEX" source="#gproxyvert" offset="0"/><input semantic="NORMAL" source="#gproxynrm" offset="0"/><input semantic="TEXCOORD" source="#gproxyuv" offset="0" set="0"/><p>', #indices * 2),
    table.concat(indices, ' '), '</p></triangles></mesh></geometry></library_geometries>',
    '<library_visual_scenes><visual_scene id="Scene" name="Scene"><node id="standinProxy" name="standinProxy" type="NODE"><instance_geometry url="#gproxy"><bind_material><technique_common><instance_material symbol="boxsymbol" target="#boxmaterial"/></technique_common></bind_material></instance_geometry></node></visual_scene></library_visual_scenes>',
    '<scene><instance_visual_scene url="#Scene"/></scene>',
    '</COLLADA>'}, '\n')
end

-- the proxy's file for a vehicle's model (made once per model and kept with the templates), or nil
local function ensureProxy(model, vdata, wheels)
  local path = physicsLimiterMerge.folder .. 'proxy' .. proxyVersion .. '_' .. (model:gsub('[^%w_.-]', '_')) .. '.dae'
  if FS:fileExists(path) then return path end
  local text = proxyMesh(vdata, wheels)
  if not text then return end
  FS:directoryCreate(physicsLimiterMerge.folder)
  if writeFile(path, text) then return path end
end

-- the box of a vehicle in its jbeam space: all its nodes and the wheels' tires; {center, size}
local function computeBox(vdata, wheels)
  local lo, hi
  for _, node in pairs(vdata.nodes or {}) do
    local p = node.pos
    if p then
      if not lo then
        lo, hi = vec3(p.x, p.y, p.z), vec3(p.x, p.y, p.z)
      else
        lo.x, lo.y, lo.z = math.min(lo.x, p.x), math.min(lo.y, p.y), math.min(lo.z, p.z)
        hi.x, hi.y, hi.z = math.max(hi.x, p.x), math.max(hi.y, p.y), math.max(hi.z, p.z)
      end
    end
  end
  if not lo then return end
  for _, w in ipairs(wheels or {}) do
    lo.y, hi.y = math.min(lo.y, w.center.y - w.radius), math.max(hi.y, w.center.y + w.radius)
    lo.z, hi.z = math.min(lo.z, w.center.z - w.radius), math.max(hi.z, w.center.z + w.radius)
  end
  local size = hi - lo
  return {center = (lo + hi) * 0.5, size = vec3(math.max(size.x, 0.2), math.max(size.y, 0.2), math.max(size.z, 0.2))}
end

-- the vehicle uses its model's template (loading its meshes, which takes a moment only the first time in a session)
local function useTemplate(id, template)
  local veh = getObjectByID(id)
  if not veh then return end
  local vehData = core_vehicle_manager.getVehicleData(id)
  local vdata = vehData and vehData.vdata
  local refPos
  if vdata and vdata.refNodes and vdata.refNodes[0] then
    local p = vdata.nodes[vdata.refNodes[0].ref].pos
    refPos = vec3(p.x, p.y, p.z)
  end
  for _, part in ipairs(template.parts) do keep(part.path) end
  local old = vehicleInfo[id]
  vehicleInfo[id] = {parts = template.parts, wheels = template.wheels, hasWheelParts = template.hasWheelParts,
    refPos = refPos, cog = old and old.cog}
  if vdata then
    local okBox, box = pcall(computeBox, vdata, template.wheels)
    vehicleInfo[id].box = okBox and box or nil
    local okProxy, proxyPath = pcall(ensureProxy, tostring(veh.jbeam), vdata, template.wheels)
    vehicleInfo[id].proxyPath = okProxy and proxyPath or nil
    -- until BeamMP's own center of mass arrives (setCog), the mass-weighted center of the nodes stands in for it
    if not vehicleInfo[id].cog and refPos and vdata.nodes then
      local sum, mass = vec3(), 0
      for _, node in pairs(vdata.nodes) do
        local weight = tonumber(node.nodeWeight) or 0
        if node.pos and weight > 0 then
          sum = sum + vec3(node.pos.x, node.pos.y, node.pos.z) * weight
          mass = mass + weight
        end
      end
      if mass > 0 then vehicleInfo[id].cog = sum / mass - refPos end
    end
    local ok, extras = pcall(vehicleExtras, vdata, template.wheels, tostring(veh.jbeam))
    if ok then
      vehicleInfo[id].extras = extras
      local steer = {}
      for index in ipairs(template.wheels) do
        local e = extras.wheels[index]
        steer[#steer + 1] = e and e.steer and string.format('%.0f', math.deg(e.steer)) or '-'
      end
      log('I', 'physicsLimiterStandIns', string.format('%s: steering lock per wheel (deg) %s', tostring(veh.jbeam), table.concat(steer, ' ')))
    else
      log('W', 'physicsLimiterStandIns', 'Working out the wheels of vehicle ' .. id .. ' failed: ' .. tostring(extras))
    end
  end
end

-- the template with the materials of a livery: copies of its mesh files with the livery's material names (made once)
local function skinTemplate(template, model, skinnedNames)
  local parts = {}
  for i, part in ipairs(template.parts) do
    local copy = {}
    for k, v in pairs(part) do copy[k] = v end
    copy.path = getSkinnedPath(part.path, model, skinnedNames)
    parts[i] = copy
  end
  return {parts = parts, wheels = template.wheels, hasWheelParts = template.hasWheelParts}
end

local function templateKey(model)
  return (model:gsub('[^%w_.-]', '_'))
end

-- the vehicle data of a model's default configuration, loaded like a spawn does it but without spawning
local function loadModelData(model)
  local dir = '/vehicles/' .. model .. '/'
  local ok, info = pcall(core_vehicles.getModel, model)
  local default = ok and info and info.model and info.model.default_pc
  extensions.load('core_vehicle_partmgmt')
  local config = core_vehicle_partmgmt.buildConfigFromString(dir, default and ('vehicles/' .. model .. '/' .. default .. '.pc') or nil)
  local bundle = config and require('jbeam/loader').loadJbeam(-1, nil, {dir, '/vehicles/common/'}, config)
  if not (bundle and bundle.vdata) then return end
  -- a spawn moves the flexbodies by the node offsets of their parts here, before it hands them to the engine
  require('jbeam/sections/meshs').process(-1, nil, bundle.vdata)
  return bundle.vdata
end

-- builds and saves the template of a model that has none (physicsLimiterPrebuild does this for all models); true if it has one
local function buildModelTemplate(model)
  local key = templateKey(model)
  templates[key] = templates[key] or loadTemplate(key)
  if templates[key] then return true end
  local ok, result = pcall(function()
    local vdata = loadModelData(model)
    local info = vdata and buildTemplate(model, key, vdata, {})
    if not (info and info.parts[1]) then return false end
    saveTemplate(key, info)
    templates[key] = info
    return true
  end)
  if not ok then log('W', 'physicsLimiterStandIns', 'Building the template of ' .. model .. ' failed: ' .. tostring(result)) end
  return ok and result == true
end

-- finds the stand-in template of a vehicle's model; a livery gets a copy of the merged meshes
local function preload(veh, id)
  local model = tostring(veh.jbeam)
  local skinnedNames, suffixes, seen = {}, {}, {}
  for _, name in ipairs(veh:getMaterialNames() or {}) do
    local base, suffix = name:match('^(.-)(%.skin%..*)$')
    if base then
      skinnedNames[base] = name
      if not seen[suffix] then seen[suffix] = true; table.insert(suffixes, suffix) end
    end
  end
  table.sort(suffixes)
  local key = templateKey(model)
  templates[key] = templates[key] or loadTemplate(key)
  if not templates[key] then return end
  local template = templates[key]
  if suffixes[1] then
    local skinKey = key .. table.concat(suffixes):gsub('[^%w_.-]', '_')
    templates[skinKey] = templates[skinKey] or skinTemplate(template, model, skinnedNames)
    template = templates[skinKey]
  end
  useTemplate(id, template)
end

local function carTransform(veh, info)
  local pos = vec3(veh:getPosition())
  local rot = quatFromDir(-vec3(veh:getDirectionVector()), vec3(veh:getDirectionVectorUp()))
  local origin = info.refPos and pos - rot * info.refPos or pos
  return pos, origin, rot
end

-- props (barriers, cones, ...) are left alone by the whole mod: the vehicles are the cars, trucks and trailers
local propCache = {}
local function isProp(veh)
  local model = tostring(veh.jbeam)
  local cached = propCache[model]
  if cached == nil then
    local ok, info = pcall(core_vehicles.getModel, model)
    cached = ok and info and info.model and info.model.Type == 'Prop' or false
    propCache[model] = cached
  end
  return cached
end

local function request(veh, id)
  if entries[id] or isProp(veh) then return end
  if not (vehicleInfo[id] and vehicleInfo[id].parts[1]) then
    preload(veh, id)
    if not (vehicleInfo[id] and vehicleInfo[id].parts[1]) then return end
  end
  -- the same paint fields the vehicle has: three colors, and metallic / roughness / clearcoat per color
  local paint = {}
  for i, color in ipairs({veh.color, veh.colorPalette0, veh.colorPalette1}) do
    local value = colorString(color)
    if value then table.insert(paint, {field = i == 1 and 'instanceColor' or ('instanceColor' .. (i - 1)), index = 0, value = value}) end
  end
  local ok, metallic = pcall(function() return veh:getMetallicPaintData() end)
  for i, data in ipairs(ok and metallic or {}) do
    if i <= 3 then
      table.insert(paint, {field = 'metallicPaintData', index = i - 1, value = string.format('%s %s %s %s',
        data.metallic or 0, data.roughness or 0.5, data.clearcoat or 0, data.clearcoatRoughness or 0)})
    end
  end
  veh:queueLuaCommand(string.format('if velocityVE and velocityVE.cogRel then local c = velocityVE.cogRel '
    .. 'obj:queueGameEngineLua("if physicsLimiterStandIns then physicsLimiterStandIns.setCog(%d," .. c.x .. "," .. c.y .. "," .. c.z .. ") end") end', id))
  entries[id] = {info = vehicleInfo[id], objs = {}, paint = paint}
end

local function has(id)
  return entries[id] ~= nil
end

local function isReady(id)
  local entry = entries[id]
  return entry and #entry.objs == #entry.info.parts
end

local function remove(id)
  local entry = entries[id]
  if not entry then return end
  for _, obj in ipairs(entry.objs) do obj:delete() end
  if entry.box then entry.box:delete() end
  entry.removed = true
  entries[id] = nil
end

-- creates the hidden objects of pending stand-ins, within frameBudget milliseconds
local function updatePending()
  local timer = hptimer()
  for _, entry in pairs(entries) do
    local parts = entry.info.parts
    while #entry.objs < #parts do
      if timer:stop() > M.frameBudget then return end
      local part = parts[#entry.objs + 1]
      local static = newStatic(part.path, 'physicsLimiterStandIn_')
      -- off by default for a static object, and then its paint (instanceColor fields) is not used: the game turns it on
      -- for the objects that take instance colors
      static.useInstanceRenderData = true
      static:setField('useInstanceRenderData', 0, 'true')
      for _, p in ipairs(entry.paint) do
        pcall(static.setField, static, p.field, p.index, p.value)
      end
      if part.placement then static.scale = part.placement.scale end
      static:setHidden(true)
      scenetree.MissionGroup:addObject(static.obj)
      table.insert(entry.objs, static)
    end
    if entry.info.box and not entry.box then
      if timer:stop() > M.frameBudget then return end
      local boxPath = ensureBox()
      local static = newStatic(entry.info.proxyPath or boxPath, 'physicsLimiterStandInBox_')
      static.useInstanceRenderData = true
      static:setField('useInstanceRenderData', 0, 'true')
      for _, p in ipairs(entry.paint) do
        pcall(static.setField, static, p.field, p.index, p.value)
      end
      if not entry.info.proxyPath then static.scale = entry.info.box.size end
      static:setHidden(true)
      scenetree.MissionGroup:addObject(static.obj)
      entry.box = static
    end
  end
end
-- places the stand-in's objects on the vehicle pose: a point of a part's mesh file is placed on the vehicle, turned
-- with its wheel, then moved by the vehicle; a quaternion product a * b turns by a first, then by b
local function placeBox(entry, origin, rot)
  local pos = entry.info.proxyPath and origin or origin + rot * entry.info.box.center
  entry.box:setPosRot(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
end

local function placeParts(entry, origin, rot)
  if entry.mode == 'box' then return placeBox(entry, origin, rot) end
  if entry.mode == 'hidden' then return end
  local wheelRots = entry.wheelRots
  local wheelOffsets = entry.wheelOffsets
  for index, obj in ipairs(entry.objs) do
    local part = entry.info.parts[index]
    local place = part.placement
    local localPos, localRot = place and place.pos or zero, place and place.rot or identityRot
    local wheelRot = wheelRots and part.wheel and wheelRots[part.wheel]
    if wheelRot then
      local c = part.wheelCenter
      localPos, localRot = c + wheelRot * (localPos - c), localRot * wheelRot
    end
    local offset = wheelOffsets and part.wheel and wheelOffsets[part.wheel]
    if offset and offset ~= 0 then localPos = localPos + vec3(0, 0, offset) end
    local pos = origin + rot * localPos
    local partRot = localRot * rot
    obj:setPosRot(pos.x, pos.y, pos.z, partRot.x, partRot.y, partRot.z, partRot.w)
  end
end

-- places the stand-in on the vehicle's current pose and shows it; called once a few frames before the vehicle is
-- deactivated (a newly shown object is only drawn from the next frame on), and again in the frame it is deactivated
local function place(veh, id)
  local entry = entries[id]
  if not entry then return end
  local vehPos, origin, rot = carTransform(veh, entry.info)
  placeParts(entry, origin, rot)
  if not entry.placed then
    for _, obj in ipairs(entry.objs) do obj:setHidden(false) end
    entry.shownFrames = 0
    entry.mode = 'full'
  end
  entry.placed = true
  entry.pos, entry.origin, entry.rot = vehPos, origin, rot
end

-- gear as BeamMP sends it (electrics.values.gear): -1 for a reverse gear, 0 for neutral / park, 1 for a driving gear
local function gearDirection(gear)
  if gear == nil then return 0 end
  if type(gear) == 'number' then return gear < 0 and -1 or (gear > 0 and 1 or 0) end
  local g = tostring(gear)
  if g:sub(1, 1) == 'R' then return -1 end
  if g == 'N' or g == 'P' or g == '0' or g == '' then return 0 end
  return 1
end

-- BeamMP: the wheels roll with the server speed (spinning at low speed with full throttle, rear wheels locked by the
-- parking brake) and the steering wheels turn with the steering input; returns whether they turned this frame
local function updateWheels(id, entry, rot, dt)
  local info = entry.info
  if not info.hasWheelParts then return false end
  local vel = physicsLimiterMP.getVelocity(id) or zero
  local speed = vel:dot(rot * vec3(0, -1, 0))
  local lateral = math.abs(vel:dot(rot * vec3(1, 0, 0)))
  local drifting = lateral > M.driftSlip and vel:length() > M.driftMinSpeed
  local throttle, gear, steering, _, parking = physicsLimiterMP.getInputs(id)
  steering = steering or 0
  local direction = gearDirection(gear)
  local burning = direction ~= 0 and (throttle or 0) > 0.9 and math.abs(speed) < M.burnoutSpeed
  local locked = (parking or 0) > 0.5
  if math.abs(speed) < 0.01 and entry.wheelRots and steering == entry.lastSteering and not burning and not drifting
    and locked == entry.lastLocked then
    entry.smokeWheels = nil
    return false
  end
  entry.lastSteering, entry.lastLocked = steering, locked
  local extras = info.extras and info.extras.wheels
  entry.wheelSpin = entry.wheelSpin or {}
  entry.wheelRots = entry.wheelRots or {}
  local smoke -- the wheels that smoke: spinning driven wheels at low speed, locked rear wheels while moving
  for index, w in ipairs(info.wheels) do
    local extra = extras and extras[index]
    local av = speed / w.radius
    if burning and extra and extra.driven then
      local burn = M.burnoutWheelSpeed * (throttle or 0) * (1 - math.abs(speed) / M.burnoutSpeed) * direction
      if math.abs(burn) > math.abs(av) then av = burn end
    end
    if locked and not w.front and math.abs(speed) > 0.3 then av = 0 end
    if (burning and extra and extra.driven) or (locked and not w.front and math.abs(speed) > 3)
      or (drifting and (not w.front or lateral > M.driftSlip * 2.5)) then
      smoke = smoke or {}
      smoke[index] = true
    end
    entry.wheelSpin[index] = ((entry.wheelSpin[index] or 0) + av * dt) % (2 * math.pi)
    local spin = quatFromAxisAngle(w.axis, -entry.wheelSpin[index]) -- the game's quaternions turn vectors the other way
    if w.front then
      local lock = extra and extra.steer or math.rad(M.maxSteerAngle)
      entry.wheelRots[index] = spin * quatFromAxisAngle(vec3(0, 0, 1), -steering * lock)
    else
      entry.wheelRots[index] = spin
    end
  end
  entry.smokeWheels = smoke
  return true
end

-- the wheels follow the ground under them relative to the body (compression and droop); seen only near the camera
local function updateSuspension(entry, origin, rot, dt, moving)
  local info = entry.info
  if not (M.suspension and info.hasWheelParts) then return false end
  if origin:squaredDistance(cameraPos) > M.suspensionDistance * M.suspensionDistance then
    if entry.wheelOffsets then
      entry.wheelOffsets, entry.suspTargets = nil, nil
      return true
    end
    return false
  end
  entry.suspTimer = (entry.suspTimer or 0) - dt
  local targets = entry.suspTargets
  if entry.suspTimer <= 0 or not targets then
    entry.suspTimer = moving and 0.03 or 0.5
    targets = targets or {}
    entry.suspTargets = targets
    local cosUp = math.max(0.3, (rot * vec3(0, 0, 1)).z)
    for index, w in ipairs(info.wheels) do
      local hub = origin + rot * w.center
      local ground = be:getSurfaceHeightBelow(hub + vec3(0, 0, 0.5))
      targets[index] = ground and ground > -1e5
        and clamp((ground + w.radius - M.tireCompression - hub.z) / cosUp, -M.maxTravel, M.maxTravel) or 0
    end
  end
  entry.wheelOffsets = entry.wheelOffsets or {}
  local f = math.min(1, dt * M.suspensionRate)
  local changed = false
  for index, target in pairs(targets) do
    local old = entry.wheelOffsets[index] or 0
    local new = old + (target - old) * f
    if math.abs(new - old) > 1e-4 then changed = true end
    entry.wheelOffsets[index] = new
  end
  return changed
end

-- where the vehicle's origin is relative to the server position (its center of mass), in the vehicle's axes: from the
-- center of mass once BeamMP has reported it, until then from the first server pose if the vehicle was at it when deactivated
local function originOffset(entry)
  local cog = entry.info.cog
  if cog then return -(cog + (entry.info.refPos or zero)) end
  return entry.mpOriginOffset
end

-- BeamMP: the stand-in of a deactivated remote vehicle follows its (smoothed) server pose
local function followServer(id, entry, dt)
  local firstPos, firstRot = physicsLimiterMP.getFirstPose(id)
  if not firstPos then return end
  -- the server position right after deactivation belongs to the position it was deactivated in (an offset taken from a slightly older update would tilt the stand-in for good)
  if not entry.info.cog and not entry.mpOriginOffset then entry.mpOriginOffset = firstRot:inversed() * (entry.origin - firstPos) end
  -- the pose BeamMP's own prediction gives for now (physicsLimiterMP)
  local pos, serverRot = physicsLimiterMP.getPose(id)
  if not pos then return end
  entry.smoothPose = {pos = pos, rot = serverRot}
  local full = entry.mode == 'full'
  local wheelsTurned = full and updateWheels(id, entry, serverRot, dt)
  local origin = pos + serverRot * originOffset(entry)
  local moving = (physicsLimiterMP.getVelocity(id) or zero):squaredLength() > 0.25
  if full and updateSuspension(entry, origin, serverRot, dt, moving) then wheelsTurned = true end

  local last = entry.lastServerPose
  if not wheelsTurned and last and last.pos:squaredDistance(pos) < 1e-6
    and math.abs(last.rot.x * serverRot.x + last.rot.y * serverRot.y + last.rot.z * serverRot.z + last.rot.w * serverRot.w) > 0.999999 then
    return
  end
  entry.lastServerPose = {pos = pos, rot = serverRot}
  placeParts(entry, origin, serverRot)
  entry.pos, entry.origin, entry.rot = origin, origin, serverRot
end

-- BeamMP: where the vehicle's reference node is now by its latest server pose; the server position is the center of
-- mass, which BeamMP's own teleports subtract the same way
local function getServerRefPose(id)
  local entry = entries[id]
  local offset = entry and originOffset(entry)
  if not offset then return end
  local pos, rot = physicsLimiterMP.getPose(id)
  if not pos then return end
  local cog = entry.info.cog
  if cog then return pos - rot * cog, rot end
  return pos + rot * offset + rot * (entry.info.refPos or zero), rot
end

-- center of mass relative to the reference node, in vehicle space (from BeamMP's velocityVE, sent by the vehicle)
local function setCog(id, x, y, z)
  if vehicleInfo[id] then vehicleInfo[id].cog = vec3(x, y, z) end
end

-- the vehicle is active again but hidden until it has synced (progress 0 to 1, nil when done); its stand-in keeps
-- following the server meanwhile
local function setWaking(id, progress)
  local entry = entries[id]
  if entry then entry.waking = progress end
end

-- where a placed stand-in is: the origin of the vehicle's jbeam space and its rotation
local function getPose(id)
  local entry = entries[id]
  if entry and entry.placed then return entry.origin, entry.rot end
end

local function isShown(id)
  local entry = entries[id]
  return entry and entry.placed and entry.shownFrames >= M.showFramesBeforeFreeze
end

-- stand-ins change between full, box and hidden a few per frame, nearest first, so a row of cars crossing a limit
-- together doesn't land on one frame
local visibilityQueue = {}
local hiddenOverride = {} -- vehicles whose stand-in is not drawn, whatever the distance (set from outside), by id
local noHits = {} -- vehicles that take no part in hits (set from outside), by id

local function setMode(entry, mode)
  if entry.removed or entry.mode == mode then return end
  entry.mode = mode
  for _, obj in ipairs(entry.objs) do obj:setHidden(mode ~= 'full') end
  if entry.box then entry.box:setHidden(mode ~= 'box') end
  if mode ~= 'hidden' then placeParts(entry, entry.origin, entry.rot) end
end

local function updateVisibility()
  local camPos = core_camera.getPosition()
  local maxDistSq = M.maxDistance * M.maxDistance
  local list = {}
  for id, entry in pairs(entries) do
    -- an active vehicle (still being replaced, or waking) stays as it is
    if entry.placed and entry.mode and not be:getObjectActive(id) then
      entry.visibilityDist = entry.pos:squaredDistance(camPos)
      entry.visibilityHidden = hiddenOverride[id]
      list[#list + 1] = entry
    end
  end
  table.sort(list, function(a, b) return a.visibilityDist < b.visibilityDist end)
  table.clear(visibilityQueue)
  inRange = 0
  for rank, entry in ipairs(list) do
    local want
    if entry.visibilityHidden or entry.visibilityDist > maxDistSq then
      want = 'hidden'
    else
      inRange = inRange + 1
      if not entry.box then
        want = 'full'
      else
        want = rank <= fullCount + (entry.mode == 'full' and M.rankMargin or -M.rankMargin) and 'full' or 'box'
      end
    end
    entry.wantMode = want
    if want ~= entry.mode then table.insert(visibilityQueue, entry) end
  end
  table.sort(visibilityQueue, function(a, b) return a.visibilityDist > b.visibilityDist end) -- popped from the end
end

local function applyVisibility()
  for _ = 1, M.visibilityPerFrame do
    local entry = table.remove(visibilityQueue)
    if not entry then return end
    if entry.placed and not entry.removed then setMode(entry, entry.wantMode) end
  end
end

-- keeps the frame rate at targetFps by changing how many of the nearest stand-ins are drawn in full: fewer when the
-- frames take longer than the target, more when they are clearly faster; when drawing fewer doesn't speed the frames up
-- (the stand-ins aren't what limits them) the count goes back and the adjustment waits
local function adjustFullCount()
  local ms = frameCount > 0 and frameSum / frameCount * 1000 or nil
  frameSum, frameCount = 0, 0
  frameMs = ms
  if not ms or M.targetFps <= 0 then
    fullCount, control.reduced, control.steps = math.huge, false, 0
    return
  end
  local target = 1000 / M.targetFps
  local current = math.min(fullCount, inRange)
  if ms > target * 1.05 then
    if clock < control.holdUntil or current <= M.minFull then
      control.reduced = false
      return
    end
    if control.reduced then
      -- after several reductions the frames have to be faster than before the first one (a single step is lost in the
      -- noise of the frame times), or the stand-ins are not what limits them
      control.steps = control.steps + 1
      if control.steps >= 4 and ms > control.baseMs * 0.97 then
        fullCount, control.holdUntil, control.steps, control.reduced = control.restore, clock + 15, 0, false
        return
      end
    else
      control.restore, control.baseMs, control.steps = fullCount, ms, 0
    end
    control.reduced = true
    fullCount = math.max(M.minFull, math.floor(current * 0.85))
  else
    control.reduced, control.steps = false, 0
    if ms < target * 0.9 and fullCount < inRange then
      fullCount = math.ceil(current * 1.1) + 1
      if fullCount >= inRange then fullCount = math.huge end
    end
  end
end

-- what the frame-rate target is doing: {full, box, hidden, fullLimit, frameMs}
local function getStatus()
  local status = {full = 0, box = 0, hidden = 0, fullLimit = fullCount, frameMs = frameMs}
  for _, entry in pairs(entries) do
    if entry.mode then status[entry.mode] = status[entry.mode] + 1 end
  end
  return status
end

local function onUpdate(dtReal)
  if core_camera then cameraPos = core_camera.getPosition() end
  clock = clock + dtReal
  if dtReal < 0.25 then frameSum, frameCount = frameSum + dtReal, frameCount + 1 end
  controlTimer = controlTimer - dtReal
  if controlTimer <= 0 then
    controlTimer = M.controlInterval
    adjustFullCount()
  end
  for id, entry in pairs(entries) do
    if entry.placed then
      entry.shownFrames = entry.shownFrames + 1
      if physicsLimiterMP and (entry.waking or not be:getObjectActive(id)) then followServer(id, entry, dtReal) end
    end
  end
  updatePending()
  visibilityTimer = visibilityTimer - dtReal
  if visibilityTimer <= 0 then
    visibilityTimer = M.visibilityInterval
    updateVisibility()
  end
  applyVisibility()
end
local function preloadSafe(veh, id)
  if isProp(veh) then return end
  local ok, err = pcall(preload, veh, id)
  if not ok then log('W', 'physicsLimiterStandIns', 'Preloading failed for vehicle ' .. tostring(id) .. ': ' .. tostring(err)) end
end

local function onVehicleSpawned(id)
  local veh = getObjectByID(id)
  if veh then preloadSafe(veh, id) end
end

-- deletes all saved templates, their merged meshes and the livery copies, so everything is built again
local function clearTemplates()
  for _, folder in ipairs({physicsLimiterMerge.folder, M.skinFolder}) do
    for _, path in ipairs(FS:findFiles(folder, '*.*', -1, true, false) or {}) do FS:removeFile(path) end
  end
  table.clear(templates)
  table.clear(materialNameCache)
end

local function hasTemplate(model)
  local key = templateKey(model)
  templates[key] = templates[key] or loadTemplate(key)
  return templates[key] ~= nil
end

local function onExtensionLoaded()
  for _, name in ipairs(scenetree.findClassObjects('TSStatic') or {}) do -- left over from before a Lua reload
    if name:find('^physicsLimiterStandIn_') or name:find('^physicsLimiterStandInBox_') or name:find('^physicsLimiterKeeper_') then
      local obj = scenetree.findObject(name)
      if obj then obj:delete() end
    end
  end
  for _, veh in ipairs(getAllVehicles()) do preloadSafe(veh, veh:getId()) end
end

local function onVehicleDestroyed(id)
  hiddenOverride[id], noHits[id] = nil, nil
  remove(id)
  vehicleInfo[id] = nil
end

local function onClientEndMission()
  table.clear(hiddenOverride)
  table.clear(noHits)
  table.clear(entries)
  table.clear(vehicleInfo)
  table.clear(keepers) -- their objects are removed with the level
end

M.request = request
M.hasTemplate = hasTemplate
M.clearTemplates = clearTemplates
M.buildModelTemplate = buildModelTemplate
M.has = has
M.isReady = isReady
M.place = place
M.isShown = isShown
M.remove = remove
M.getServerRefPose = getServerRefPose
M.setCog = setCog
M.getPose = getPose
M.hasCog = function(id) return vehicleInfo[id] and vehicleInfo[id].cog ~= nil or false end
M.setWaking = setWaking
M.onUpdate = onUpdate
M.setHiddenOverride = function(id, value) hiddenOverride[id] = value or nil end
M.isHiddenOverride = function(id) return hiddenOverride[id] or false end
M.setNoHits = function(id, value) noHits[id] = value or nil end
M.isNoHits = function(id) return noHits[id] or false end
M.isProp = isProp
M.getEntries = function() return entries end -- read only; for physicsLimiterParticles
M.getStatus = getStatus
M.onVehicleSpawned = onVehicleSpawned
M.onExtensionLoaded = onExtensionLoaded
M.onVehicleDestroyed = onVehicleDestroyed
M.onClientEndMission = onClientEndMission

return M

