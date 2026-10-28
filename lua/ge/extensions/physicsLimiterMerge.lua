-- Physics Limiter, Copyright (C) 2026 tmaster1000
-- Licensed under the GNU Affero General Public License version 3, see the LICENSE file.
-- Merges stand-in parts (the texts of their meshes) into one mesh file, so a vehicle's body is one object instead of one per part. By default every
-- part's geometry is kept under its own node; with options.byMaterial there is one geometry per material, the
-- placements baked into the vertices (far fewer draws), and the smallest parts are left out.

local M = {}

M.folder = '/temp/physicsLimiterMerged/'

local function between(text, open, close)
  local _, e = text:find(open, 1, true)
  local c = e and text:find(close, e + 1, true)
  if c then return text:sub(e + 1, c - 1) end
end

-- 4x4 row-major matrices, as COLLADA writes them
local function identityMatrix()
  return {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
end

local function multiply(a, b)
  local out = {}
  for r = 0, 3 do
    for c = 1, 4 do
      local v = 0
      for k = 1, 4 do v = v + a[r * 4 + k] * b[(k - 1) * 4 + c] end
      out[r * 4 + c] = v
    end
  end
  return out
end

local function placementMatrix(place)
  if not place then return {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1} end
  local ax, ay, az = place.rot * vec3(1, 0, 0), place.rot * vec3(0, 1, 0), place.rot * vec3(0, 0, 1)
  local s, p = place.scale, place.pos
  return {
    ax.x * s.x, ay.x * s.y, az.x * s.z, p.x,
    ax.y * s.x, ay.y * s.y, az.y * s.z, p.y,
    ax.z * s.x, ay.z * s.y, az.z * s.z, p.z,
    0, 0, 0, 1
  }
end

-- the geometries without vertex colors, which stand-ins don't use (COLOR inputs, their index entries and arrays)
local function stripColors(geometries)
  local pieces, pos = {}, 1
  while true do
    local s, e, kind = geometries:find('<(%a+) material="[^"]*"[^>]*>', pos)
    local closeStart = s and geometries:find('</' .. kind .. '>', e + 1, true)
    if not closeStart then break end
    pieces[#pieces + 1] = geometries:sub(pos, e)
    local body = geometries:sub(e + 1, closeStart - 1)
    local stride, colorOffsets, otherOffsets = 0, {}, {}
    for input in body:gmatch('<input[^>]*>') do
      local offset = tonumber(input:match('offset="(%d+)"')) or 0
      stride = math.max(stride, offset + 1)
      if input:find('semantic="COLOR"', 1, true) then colorOffsets[offset] = true else otherOffsets[offset] = true end
    end
    local drop, dropped = {}, false
    for offset in pairs(colorOffsets) do
      if not otherOffsets[offset] then drop[offset], dropped = true, true end
    end
    body = body:gsub('<input[^>]-semantic="COLOR"[^>]*>%s*', '')
    if dropped then
      body = body:gsub('offset="(%d+)"', function(o)
        o = tonumber(o)
        local shift = 0
        for d in pairs(drop) do if d < o then shift = shift + 1 end end
        return 'offset="' .. (o - shift) .. '"'
      end)
      local pStart, pEnd = body:find('<p>', 1, true)
      local pClose = pEnd and body:find('</p>', pEnd + 1, true)
      if pClose then
        local kept, k = {}, 0
        for n in body:sub(pEnd + 1, pClose - 1):gmatch('%S+') do
          if not drop[k % stride] then kept[#kept + 1] = n end
          k = k + 1
        end
        body = body:sub(1, pEnd) .. table.concat(kept, ' ') .. body:sub(pClose)
      end
    end
    pieces[#pieces + 1] = body
    pos = closeStart
  end
  pieces[#pieces + 1] = geometries:sub(pos)
  return (table.concat(pieces):gsub('<source id="[^"]*%-colors[^"]*"[^>]*>.-</source>%s*', ''))
end

-- a mesh's pieces, with unique ids (materials, effects and images keep theirs: they're the vehicle's)
local function readPart(text, index, place, skinnedNames)
  if not text then return end
  local prefix = 'p' .. index .. '_'
  local geometries = between(text, '<library_geometries>', '</library_geometries>')
  local scene = text:match('<visual_scene[^>]*>(.*)</visual_scene>')
  local node = scene and scene:match('<node.*</node>')
  if not (geometries and node) then return end
  geometries = stripColors(geometries):gsub(' id="', ' id="' .. prefix):gsub('source="#', 'source="#' .. prefix)

  -- the node: unique id and name without a trailing number (it would be read as a detail level), and the matrix that
  -- places it on the vehicle: its own transforms, then the file's unit and up axis (the merged file is in meters,
  -- Z up), then the part's placement
  local fileMatrix = identityMatrix()
  local head = node:match('^<node[^>]*>(.-)<instance_geometry') or ''
  for tag, values in head:gmatch('<(%a+)[^>]*>([^<]*)</%a+>') do
    local v = {}
    for n in values:gmatch('%S+') do v[#v + 1] = tonumber(n) end
    local m
    if tag == 'matrix' and #v == 16 then
      m = v
    elseif tag == 'translate' and #v == 3 then
      m = {1, 0, 0, v[1], 0, 1, 0, v[2], 0, 0, 1, v[3], 0, 0, 0, 1}
    elseif tag == 'scale' and #v == 3 then
      m = {v[1], 0, 0, 0, 0, v[2], 0, 0, 0, 0, v[3], 0, 0, 0, 0, 1}
    elseif tag == 'rotate' and #v == 4 then
      local axis = vec3(v[1], v[2], v[3]):normalized()
      local c, s = math.cos(math.rad(v[4])), math.sin(math.rad(v[4]))
      local x, y, z, t = axis.x, axis.y, axis.z, 1 - c
      m = {t * x * x + c, t * x * y - s * z, t * x * z + s * y, 0,
        t * x * y + s * z, t * y * y + c, t * y * z - s * x, 0,
        t * x * z - s * y, t * y * z + s * x, t * z * z + c, 0, 0, 0, 0, 1}
    end
    if m then fileMatrix = multiply(fileMatrix, m) end
  end
  local unit = tonumber(text:match('<unit[^>]-meter="([^"]*)"')) or 1
  local upAxis = text:match('<up_axis>%s*(%a_UP)%s*</up_axis>') or 'Z_UP'
  local toZUp = upAxis == 'Y_UP' and {1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1}
    or upAxis == 'X_UP' and {0, 0, -1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1} or identityMatrix()
  local unitMatrix = {unit, 0, 0, 0, 0, unit, 0, 0, 0, 0, unit, 0, 0, 0, 0, 1}
  fileMatrix = multiply(multiply(toZUp, unitMatrix), fileMatrix)
  local matrixText = '<matrix sid="transform">' .. table.concat(multiply(placementMatrix(place), fileMatrix), ' ') .. '</matrix>'
  for _, tag in ipairs({'matrix', 'translate', 'rotate', 'scale'}) do
    node = node:gsub('<' .. tag .. '[^>]*>[^<]*</' .. tag .. '>', '')
  end
  node = node:gsub('^<node[^>]*>', '<node id="' .. prefix .. 'mesh" name="' .. prefix .. 'mesh" type="NODE">' .. matrixText, 1)
  node = node:gsub('url="#', 'url="#' .. prefix)

  local materials = between(text, '<library_materials>', '</library_materials>') or ''
  for name, skinned in pairs(skinnedNames) do
    materials = materials:gsub('name="' .. name:gsub('%p', '%%%0') .. '"', 'name="' .. skinned .. '"')
  end
  return {
    root = text:match('<COLLADA[^>]*>'),
    geometries = geometries, node = node, materials = materials,
    effects = between(text, '<library_effects>', '</library_effects>') or '',
    images = between(text, '<library_images>', '</library_images>') or ''
  }
end

-- the elements of a library, once per id
local function addUnique(list, seen, library, tag)
  for element in library:gmatch('<' .. tag .. '[ >].-</' .. tag .. '>') do
    local id = element:match('id="([^"]*)"')
    if id and not seen[id] then
      seen[id] = true
      list[#list + 1] = element
    end
  end
end

-- ===== by material =====
-- The triangles of all parts that share a material are joined into one geometry (one draw) with the placements
-- applied to positions and normals; parts whose bounding box is smaller than dropSmallerThan meters are left out.

M.dropSmallerThan = 0.12 -- meters, the diagonal of a part's bounding box

local function parseNumbers(text)
  local t, n = {}, 0
  for s in text:gmatch('%S+') do
    n = n + 1
    t[n] = tonumber(s)
  end
  return t, n
end

-- the matrix that places a part's node on the vehicle (the same as readPart puts in the node)
local function nodeMatrix(text, node, place)
  local fileMatrix = identityMatrix()
  local head = node:match('^<node[^>]*>(.-)<instance_geometry') or ''
  for tag, values in head:gmatch('<(%a+)[^>]*>([^<]*)</%a+>') do
    local v = {}
    for n in values:gmatch('%S+') do v[#v + 1] = tonumber(n) end
    local m
    if tag == 'matrix' and #v == 16 then
      m = v
    elseif tag == 'translate' and #v == 3 then
      m = {1, 0, 0, v[1], 0, 1, 0, v[2], 0, 0, 1, v[3], 0, 0, 0, 1}
    elseif tag == 'scale' and #v == 3 then
      m = {v[1], 0, 0, 0, 0, v[2], 0, 0, 0, 0, v[3], 0, 0, 0, 0, 1}
    elseif tag == 'rotate' and #v == 4 then
      local axis = vec3(v[1], v[2], v[3]):normalized()
      local c, s = math.cos(math.rad(v[4])), math.sin(math.rad(v[4]))
      local x, y, z, t = axis.x, axis.y, axis.z, 1 - c
      m = {t * x * x + c, t * x * y - s * z, t * x * z + s * y, 0,
        t * x * y + s * z, t * y * y + c, t * y * z - s * x, 0,
        t * x * z - s * y, t * y * z + s * x, t * z * z + c, 0, 0, 0, 0, 1}
    end
    if m then fileMatrix = multiply(fileMatrix, m) end
  end
  local unit = tonumber(text:match('<unit[^>]-meter="([^"]*)"')) or 1
  local upAxis = text:match('<up_axis>%s*(%a_UP)%s*</up_axis>') or 'Z_UP'
  local toZUp = upAxis == 'Y_UP' and {1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1}
    or upAxis == 'X_UP' and {0, 0, -1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1} or identityMatrix()
  local unitMatrix = {unit, 0, 0, 0, 0, unit, 0, 0, 0, 0, unit, 0, 0, 0, 0, 1}
  fileMatrix = multiply(multiply(toZUp, unitMatrix), fileMatrix)
  return multiply(placementMatrix(place), fileMatrix)
end

-- a geometry's sources and triangles: {sources = {id = {data, stride}}, vertices = {id = position source id},
-- prims = {{material = symbol, offsets..., corners = flat list of index tuples}}}; nil if it has anything unusual
local function parseGeometry(geometry)
  local mesh = geometry:match('<mesh>(.*)</mesh>')
  if not mesh then return end
  local sources = {}
  for id, body in mesh:gmatch('<source%s[^>]*%f[%w]id="([^"]*)"[^>]*>(.-)</source>') do
    local array = body:match('<float_array[^>]*>([^<]*)</float_array>')
    if array then sources[id] = {data = parseNumbers(array), stride = tonumber(body:match('<accessor[^>]-stride="(%d+)"')) or 3} end
  end
  local vertices = {}
  for id, body in mesh:gmatch('<vertices%s[^>]*%f[%w]id="([^"]*)"[^>]*>(.-)</vertices>') do
    vertices[id] = body:match('semantic="POSITION"[^>]-source="#([^"]*)"')
  end
  local prims = {}
  for kind, attrs, body in mesh:gmatch('<(%a+)%s+([^>]*material="[^>]*)>(.-)</%1>') do
    if kind ~= 'triangles' and kind ~= 'polylist' then return end
    local prim = {material = attrs:match('material="([^"]*)"'), sets = {}}
    local stride = 1
    for tag in body:gmatch('<input [^>]*>') do
      local semantic = tag:match('semantic="([^"]*)"')
      local source = (tag:match('source="#([^"]*)"') or '')
      local offset = tonumber(tag:match('offset="(%d+)"')) or 0
      local set = tonumber(tag:match('%sset="(%d+)"')) or 0 -- (with the space: "offset" ends in "set")
      stride = math.max(stride, offset + 1)
      if semantic == 'VERTEX' then prim.vertex = {source = vertices[source], offset = offset}
      elseif semantic == 'NORMAL' then prim.normal = {source = source, offset = offset}
      elseif semantic == 'TEXCOORD' and set <= 1 then prim.sets[set] = {source = source, offset = offset} end
    end
    if not (prim.vertex and prim.vertex.source and sources[prim.vertex.source]) then return end
    local p = parseNumbers(body:match('<p>([^<]*)</p>') or '')
    local triangles = {}
    if kind == 'triangles' then
      local count = math.floor(#p / stride)
      for c = 0, count - 1 do triangles[#triangles + 1] = c end
      prim.cornerList = triangles
    else
      local vcount = parseNumbers(body:match('<vcount>([^<]*)</vcount>') or '')
      local corner = 0
      for _, k in ipairs(vcount) do
        for i = 1, k - 2 do
          triangles[#triangles + 1] = corner
          triangles[#triangles + 1] = corner + i
          triangles[#triangles + 1] = corner + i + 1
        end
        corner = corner + k
      end
      prim.cornerList = triangles
    end
    prim.p, prim.stride = p, stride
    prims[#prims + 1] = prim
  end
  if not prims[1] then return end
  return {sources = sources, prims = prims}
end

-- where a mesh text lies on the vehicle once placed: {count, lo, hi, check (sample points), triangles}
local function bounds(text, place)
  local libraryGeometries = between(text, '<library_geometries>', '</library_geometries>')
  local scene = text:match('<visual_scene[^>]*>(.*)</visual_scene>')
  local node = scene and scene:match('<node.*</node>')
  if not (libraryGeometries and node) then return end
  local m = nodeMatrix(text, node, place)
  local points, count = {}, 0
  local lo, hi = {math.huge, math.huge, math.huge}, {-math.huge, -math.huge, -math.huge}
  local triangles = 0
  for geometry in libraryGeometries:gmatch('<geometry[%s>].-</geometry>') do
    local vertices = geometry:match('<vertices[^>]*>(.-)</vertices>')
    local sourceId = vertices and vertices:match('semantic="POSITION"[^>]-source="#([^"]*)"')
    local array
    if sourceId then
      local pattern = '<source%s[^>]*%f[%w]id="' .. sourceId:gsub('%p', '%%%0') .. '"[^>]*>(.-)</source>'
      local body = geometry:match(pattern)
      array = body and body:match('<float_array[^>]*>([^<]*)</float_array>')
    end
    if array then
      local d = parseNumbers(array)
      for i = 1, #d - 2, 3 do
        local x, y, z = d[i], d[i + 1], d[i + 2]
        local px, py, pz = m[1] * x + m[2] * y + m[3] * z + m[4], m[5] * x + m[6] * y + m[7] * z + m[8], m[9] * x + m[10] * y + m[11] * z + m[12]
        count = count + 1
        points[count] = {px, py, pz}
        if px < lo[1] then lo[1] = px end
        if px > hi[1] then hi[1] = px end
        if py < lo[2] then lo[2] = py end
        if py > hi[2] then hi[2] = py end
        if pz < lo[3] then lo[3] = pz end
        if pz > hi[3] then hi[3] = pz end
      end
    end
    for n in geometry:gmatch('<triangles[^>]-count="(%d+)"') do triangles = triangles + tonumber(n) end
    for n in geometry:gmatch('<polylist[^>]-count="(%d+)"') do triangles = triangles + tonumber(n) end
  end
  if count == 0 then return end
  local check = {}
  for i = 1, count, math.max(1, math.floor(count / 8)) do check[#check + 1] = vec3(points[i][1], points[i][2], points[i][3]) end
  return {count = count, lo = vec3(lo[1], lo[2], lo[3]), hi = vec3(hi[1], hi[2], hi[3]), check = check, triangles = triangles}
end

local function letters(n) -- a name without digits (a trailing number in a node name would be read as a detail level)
  local s = ''
  repeat
    s = string.char(97 + n % 26) .. s
    n = math.floor(n / 26)
  until n == 0
  return s
end

-- the groups by material: {materialId = {positions, normals, uv0, uv1, indices, vertexCount, triangleCount, lookup}}
local function addPart(groups, order, text, node, geometryText, instanceMaterials, matrix, dropBelow)
  local geometry = parseGeometry(geometryText)
  if not geometry then return false end
  local m = matrix
  local lo, hi = {math.huge, math.huge, math.huge}, {-math.huge, -math.huge, -math.huge}
  for _, prim in ipairs(geometry.prims) do
    local source = geometry.sources[prim.vertex.source]
    local d = source.data
    for i = 1, #d - 2, source.stride do
      local x, y, z = d[i], d[i + 1], d[i + 2]
      local px, py, pz = m[1] * x + m[2] * y + m[3] * z + m[4], m[5] * x + m[6] * y + m[7] * z + m[8], m[9] * x + m[10] * y + m[11] * z + m[12]
      if px < lo[1] then lo[1] = px end
      if px > hi[1] then hi[1] = px end
      if py < lo[2] then lo[2] = py end
      if py > hi[2] then hi[2] = py end
      if pz < lo[3] then lo[3] = pz end
      if pz > hi[3] then hi[3] = pz end
    end
    break
  end
  local diagonal = math.sqrt((hi[1] - lo[1]) ^ 2 + (hi[2] - lo[2]) ^ 2 + (hi[3] - lo[3]) ^ 2)
  if dropBelow and diagonal < dropBelow then return true, true end
  -- the normal matrix: the cofactors of the upper 3x3, signed by its determinant (a mirrored part also flips its triangles)
  local a, b, c, d, e, f, g, h, i = m[1], m[2], m[3], m[5], m[6], m[7], m[9], m[10], m[11]
  local det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
  local sign = det < 0 and -1 or 1
  local n11, n12, n13 = (e * i - f * h) * sign, -(d * i - f * g) * sign, (d * h - e * g) * sign
  local n21, n22, n23 = -(b * i - c * h) * sign, (a * i - c * g) * sign, -(a * h - b * g) * sign
  local n31, n32, n33 = (b * f - c * e) * sign, -(a * f - c * d) * sign, (a * e - b * d) * sign
  local flip = det < 0
  for _, prim in ipairs(geometry.prims) do
    local materialId = instanceMaterials[prim.material] or prim.material
    local group = groups[materialId]
    if not group then
      group = {positions = {}, normals = {}, uv0 = {}, uv1 = {}, indices = {}, vertexCount = 0, triangleCount = 0}
      groups[materialId] = group
      order[#order + 1] = materialId
    end
    local source = geometry.sources[prim.vertex.source]
    local normalSource = prim.normal and geometry.sources[prim.normal.source]
    local uvSource0 = prim.sets[0] and geometry.sources[prim.sets[0].source]
    local uvSource1 = prim.sets[1] and geometry.sources[prim.sets[1].source]
    local lookup = {}
    local p, stride = prim.p, prim.stride
    local corners = prim.cornerList
    local function vertexOf(corner)
      local base = corner * stride
      local vi = p[base + prim.vertex.offset + 1]
      local ni = normalSource and p[base + prim.normal.offset + 1] or -1
      local t0 = uvSource0 and p[base + prim.sets[0].offset + 1] or -1
      local t1 = uvSource1 and p[base + prim.sets[1].offset + 1] or -1
      local key = vi .. ',' .. ni .. ',' .. t0 .. ',' .. t1
      local index = lookup[key]
      if index then return index end
      index = group.vertexCount
      group.vertexCount = index + 1
      lookup[key] = index
      local x, y, z = source.data[vi * source.stride + 1], source.data[vi * source.stride + 2], source.data[vi * source.stride + 3]
      local pos = group.positions
      local k = #pos
      pos[k + 1] = string.format('%.6g', m[1] * x + m[2] * y + m[3] * z + m[4])
      pos[k + 2] = string.format('%.6g', m[5] * x + m[6] * y + m[7] * z + m[8])
      pos[k + 3] = string.format('%.6g', m[9] * x + m[10] * y + m[11] * z + m[12])
      local nx, ny, nz = 0, 0, 1
      if ni >= 0 then
        local sx, sy, sz = normalSource.data[ni * normalSource.stride + 1], normalSource.data[ni * normalSource.stride + 2], normalSource.data[ni * normalSource.stride + 3]
        nx, ny, nz = n11 * sx + n12 * sy + n13 * sz, n21 * sx + n22 * sy + n23 * sz, n31 * sx + n32 * sy + n33 * sz
        local len = math.sqrt(nx * nx + ny * ny + nz * nz)
        if len > 1e-12 then nx, ny, nz = nx / len, ny / len, nz / len else nx, ny, nz = 0, 0, 1 end
      end
      local nrm = group.normals
      k = #nrm
      nrm[k + 1], nrm[k + 2], nrm[k + 3] = string.format('%.5g', nx), string.format('%.5g', ny), string.format('%.5g', nz)
      local uv = group.uv0
      k = #uv
      if t0 >= 0 then uv[k + 1], uv[k + 2] = string.format('%.6g', uvSource0.data[t0 * 2 + 1]), string.format('%.6g', uvSource0.data[t0 * 2 + 2])
      else uv[k + 1], uv[k + 2] = '0', '0' end
      uv = group.uv1
      k = #uv
      if t1 >= 0 then uv[k + 1], uv[k + 2] = string.format('%.6g', uvSource1.data[t1 * 2 + 1]), string.format('%.6g', uvSource1.data[t1 * 2 + 2])
      else uv[k + 1], uv[k + 2] = '0', '0' end
      return index
    end
    local indices = group.indices
    for t = 1, #corners, 3 do
      local i1, i2, i3 = vertexOf(corners[t]), vertexOf(corners[t + 1]), vertexOf(corners[t + 2])
      local k = #indices
      if flip then indices[k + 1], indices[k + 2], indices[k + 3] = i1, i3, i2 else indices[k + 1], indices[k + 2], indices[k + 3] = i1, i2, i3 end
      group.triangleCount = group.triangleCount + 1
    end
  end
  return true, false
end

local function groupXml(index, materialId, group)
  local id = 'g' .. letters(index)
  local function source(suffix, array, stride, params)
    local param = {}
    for _, name in ipairs(params) do param[#param + 1] = '<param name="' .. name .. '" type="float"/>' end
    return string.format('<source id="%s-%s"><float_array id="%s-%s-a" count="%d">%s</float_array><technique_common><accessor source="#%s-%s-a" count="%d" stride="%d">%s</accessor></technique_common></source>',
      id, suffix, id, suffix, #array, table.concat(array, ' '), id, suffix, math.floor(#array / stride), stride, table.concat(param))
  end
  return table.concat({
    '<geometry id="', id, '" name="', id, '"><mesh>',
    source('pos', group.positions, 3, {'X', 'Y', 'Z'}), source('nrm', group.normals, 3, {'X', 'Y', 'Z'}),
    source('uv0', group.uv0, 2, {'S', 'T'}), source('uv1', group.uv1, 2, {'S', 'T'}),
    '<vertices id="', id, '-vtx"><input semantic="POSITION" source="#', id, '-pos"/></vertices>',
    '<triangles material="', materialId, '" count="', group.triangleCount, '">',
    '<input semantic="VERTEX" source="#', id, '-vtx" offset="0"/><input semantic="NORMAL" source="#', id, '-nrm" offset="0"/>',
    '<input semantic="TEXCOORD" source="#', id, '-uv0" offset="0" set="0"/><input semantic="TEXCOORD" source="#', id, '-uv1" offset="0" set="1"/>',
    '<p>', table.concat(group.indices, ' '), '</p></triangles></mesh></geometry>'})
end

-- writes the merged file with one geometry per material; parts that can't be handled this way are added as they are
local function buildByMaterial(name, parts, skinnedNames, dropBelow)
  local path = M.folder .. name .. '.dae'
  local timer = hptimer()
  local root
  local groups, order = {}, {}
  local geometries, nodes, materials, effects, images = {}, {}, {}, {}, {}
  local seenMaterials, seenEffects, seenImages = {}, {}, {}
  local baked, dropped, kept = 0, 0, 0
  for index, part in ipairs(parts) do
    local text = part.text
    local libraryGeometries = text and between(text, '<library_geometries>', '</library_geometries>')
    local scene = text and text:match('<visual_scene[^>]*>(.*)</visual_scene>')
    local node = scene and scene:match('<node.*</node>')
    local handled, wasDropped = false, false
    if libraryGeometries and node and select(2, node:gsub('<node[ >]', '')) == 1 then
      local matrix = nodeMatrix(text, node, part.placement)
      local ok, a, b = pcall(function()
        local used, anyDropped = true, false
        local count = 0
        for url, body in node:gmatch('<instance_geometry%s[^>]*url="#([^"]*)"[^>]*>(.-)</instance_geometry>') do
          count = count + 1
          local instanceMaterials = {}
          for tag in body:gmatch('<instance_material%s[^>]*>') do
            local symbol, target = tag:match('symbol="([^"]*)"'), tag:match('target="#([^"]*)"')
            if symbol and target then instanceMaterials[symbol] = target end
          end
          local geometryText = libraryGeometries:match('<geometry id="' .. url:gsub('%p', '%%%0') .. '".->.-</geometry>')
          if not geometryText then return false end
          local handledPart, dropPart = addPart(groups, order, text, node, geometryText, instanceMaterials, matrix, dropBelow)
          if not handledPart then return false end
          anyDropped = anyDropped or dropPart
        end
        return count > 0, anyDropped
      end)
      handled, wasDropped = ok and a, ok and b
    end
    local libs
    if handled then
      baked = baked + 1
      if wasDropped then dropped = dropped + 1 else kept = kept + 1 end
    else
      local ok, piece = pcall(readPart, part.text, index, part.placement, skinnedNames)
      if ok and piece then
        geometries[#geometries + 1] = piece.geometries
        nodes[#nodes + 1] = piece.node
        libs = piece
      end
    end
    if text and (handled and not wasDropped or libs) then
      libs = libs or {
        materials = between(text, '<library_materials>', '</library_materials>') or '',
        effects = between(text, '<library_effects>', '</library_effects>') or '',
        images = between(text, '<library_images>', '</library_images>') or ''
      }
      if handled then
        for skinName, skinned in pairs(skinnedNames) do
          libs.materials = libs.materials:gsub('name="' .. skinName:gsub('%p', '%%%0') .. '"', 'name="' .. skinned .. '"')
        end
      end
      root = root or text:match('<COLLADA[^>]*>')
      addUnique(materials, seenMaterials, libs.materials, 'material')
      addUnique(effects, seenEffects, libs.effects, 'effect')
      addUnique(images, seenImages, libs.images, 'image')
    end
  end
  if not (order[1] or nodes[1]) then return end
  local mergedNodes = {}
  local instances = {}
  for index, materialId in ipairs(order) do
    local group = groups[materialId]
    geometries[#geometries + 1] = groupXml(index, materialId, group)
    instances[#instances + 1] = string.format('<instance_geometry url="#g%s"><bind_material><technique_common><instance_material symbol="%s" target="#%s"/></technique_common></bind_material></instance_geometry>',
      letters(index), materialId, materialId)
  end
  if instances[1] then
    mergedNodes[1] = '<node id="standinMesh" name="standinMesh" type="NODE"><matrix sid="transform">1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1</matrix>' .. table.concat(instances) .. '</node>'
  end
  local text = table.concat({
    '<?xml version="1.0" encoding="utf-8"?>',
    root or '<COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">',
    '<asset><unit name="meter" meter="1"/><up_axis>Z_UP</up_axis></asset>',
    '<library_effects>', table.concat(effects), '</library_effects>',
    '<library_images>', table.concat(images), '</library_images>',
    '<library_materials>', table.concat(materials), '</library_materials>',
    '<library_geometries>', table.concat(geometries), '</library_geometries>',
    '<library_visual_scenes><visual_scene id="Scene" name="Scene">', table.concat(mergedNodes), table.concat(nodes), '</visual_scene></library_visual_scenes>',
    '<scene><instance_visual_scene url="#Scene"/></scene>',
    '</COLLADA>'
  }, '\n')
  FS:directoryCreate(M.folder)
  if not writeFile(path, text) then return end
  local triangles = 0
  for _, group in pairs(groups) do triangles = triangles + group.triangleCount end
  log('I', 'physicsLimiterMerge', string.format('%s: %d parts (%d left out as small, %d as they are) merged into %d geometries by material, %d triangles, %.1f MB, %.0f ms',
    name, kept, dropped, #parts - baked, #order, triangles, #text / 1048576, timer:stop()))
  return path
end

-- writes the merged file of the parts ({{path, placement}}) as M.folder .. name .. '.dae', with the livery's materials
-- (skinnedNames: material name -> livery material name); returns its path
local function build(name, parts, skinnedNames, options)
  if options and options.byMaterial then
    local ok, path = pcall(buildByMaterial, name, parts, skinnedNames, options.dropSmallerThan)
    if ok and path then return path end
    log('W', 'physicsLimiterMerge', name .. ': merging by material failed, merged as parts: ' .. tostring(path))
  end
  local path = M.folder .. name .. '.dae'
  local timer = hptimer()
  local root
  local geometries, nodes, materials, effects, images = {}, {}, {}, {}, {}
  local seenMaterials, seenEffects, seenImages = {}, {}, {}
  for index, part in ipairs(parts) do
    local ok, piece = pcall(readPart, part.text, index, part.placement, skinnedNames)
    if ok and piece then
      root = root or piece.root
      geometries[#geometries + 1] = piece.geometries
      nodes[#nodes + 1] = piece.node
      addUnique(materials, seenMaterials, piece.materials, 'material')
      addUnique(effects, seenEffects, piece.effects, 'effect')
      addUnique(images, seenImages, piece.images, 'image')
    end
  end
  if not nodes[1] then return end
  local text = table.concat({
    '<?xml version="1.0" encoding="utf-8"?>',
    root or '<COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">',
    '<asset><unit name="meter" meter="1"/><up_axis>Z_UP</up_axis></asset>', -- each part's own is in its matrix
    '<library_effects>', table.concat(effects), '</library_effects>',
    '<library_images>', table.concat(images), '</library_images>',
    '<library_materials>', table.concat(materials), '</library_materials>',
    '<library_geometries>', table.concat(geometries), '</library_geometries>',
    '<library_visual_scenes><visual_scene id="Scene" name="Scene">', table.concat(nodes), '</visual_scene></library_visual_scenes>',
    '<scene><instance_visual_scene url="#Scene"/></scene>',
    '</COLLADA>'
  }, '\n')
  FS:directoryCreate(M.folder)
  if not writeFile(path, text) then return end
  log('I', 'physicsLimiterMerge', string.format('%s: %d parts merged into one mesh, %.1f MB, %.0f ms', name, #nodes, #text / 1048576, timer:stop()))
  return path
end

M.build = build
M.bounds = bounds

return M
