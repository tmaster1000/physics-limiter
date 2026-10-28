-- Physics Limiter by tmaster1000
-- Finds a vehicle's meshes in the game's .dae files and cuts each out as a small COLLADA text of its own, for
-- physicsLimiterMerge. The meshes of a model are looked for in its own folder, then in the folder of the shared meshes.

local M = {}

local daeByFolder

local function vehicleFolderOf(path) -- '/vehicles/<folder>/.../x.dae' -> '<folder>'
  return path:match('^/[vV][eE][hH][iI][cC][lL][eE][sS]/([^/]+)/')
end

local function listFiles()
  if daeByFolder then return daeByFolder end
  daeByFolder = {}
  for _, path in ipairs(FS:findFiles('/vehicles/', '*.dae', -1, true, false) or {}) do
    local folder = vehicleFolderOf(path)
    if folder then
      daeByFolder[folder] = daeByFolder[folder] or {}
      table.insert(daeByFolder[folder], path)
    end
  end
  for _, files in pairs(daeByFolder) do table.sort(files) end
  return daeByFolder
end

local function decodeXml(text)
  return (text:gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&quot;', '"'):gsub('&apos;', "'"):gsub('&amp;', '&'))
end

-- the text of an element with all that is in it, or of an empty one
local function section(text, tag)
  local s = text:find('<' .. tag .. '[%s>/]')
  if not s then return end
  local openEnd = text:find('>', s, true)
  if not openEnd then return end
  if text:sub(openEnd - 1, openEnd - 1) == '/' then return text:sub(s, openEnd) end
  local closeTag = '</' .. tag .. '>'
  local e = text:find(closeTag, openEnd, true)
  return e and text:sub(s, e + #closeTag - 1)
end

-- the elements directly in the first visual scene, as text
local function topLevelNodes(body)
  local nodes = {}
  local pos, depth, startPos = 1, 0, 1
  while true do
    local s, _, slash = body:find('<(/?)node[%s>/]', pos)
    if not s then break end
    local tagEnd = body:find('>', s, true)
    if not tagEnd then break end
    if slash == '/' then
      depth = depth - 1
      if depth == 0 then nodes[#nodes + 1] = body:sub(startPos, tagEnd) end
    else
      if depth == 0 then startPos = s end
      if body:sub(tagEnd - 1, tagEnd - 1) == '/' then
        if depth == 0 then nodes[#nodes + 1] = body:sub(s, tagEnd) end
      else
        depth = depth + 1
      end
    end
    pos = tagEnd + 1
  end
  return nodes
end

-- the wanted meshes of a .dae, each as the text of a .dae of its own: found[name] = text
local function cutOut(text, wanted, found)
  local rootOpen = text:match('<COLLADA[^>]*>')
  local vsStart = text:find('<visual_scene[%s>]')
  if not (rootOpen and vsStart) then return end
  local vsOpenEnd = text:find('>', vsStart, true)
  local vsOpen = text:sub(vsStart, vsOpenEnd)
  local vsEnd = text:find('</visual_scene>', vsOpenEnd, true)
  if not vsEnd then return end

  local chosen, needed = {}, {}
  for _, node in ipairs(topLevelNodes(text:sub(vsOpenEnd + 1, vsEnd - 1))) do
    local openTag = node:match('^<node[^>]*>')
    local name = openTag and (openTag:match('%sname="([^"]*)"') or openTag:match('%sid="([^"]*)"'))
    name = name and decodeXml(name)
    if name and wanted[name] and not found[name] then
      local ids = {}
      for id in node:gmatch('<instance_geometry%s[^>]-url="#([^"]*)"') do
        ids[#ids + 1] = id
        needed[id] = true
      end
      if ids[1] then chosen[#chosen + 1] = {name = name, node = node, ids = ids} end
    end
  end
  if not chosen[1] then return end

  local geometries = {}
  local pos = 1
  while true do
    local s = text:find('<geometry[%s>]', pos)
    if not s then break end
    local e = text:find('</geometry>', s, true)
    if not e then break end
    local id = text:sub(s, text:find('>', s, true)):match('%sid="([^"]*)"')
    if id and needed[id] then geometries[id] = text:sub(s, e + 10) end
    pos = e + 11
  end

  local shared = {}
  for _, tag in ipairs({'asset', 'library_effects', 'library_images', 'library_materials'}) do
    shared[#shared + 1] = section(text, tag)
  end
  local sceneElement = section(text, 'scene') or ''
  for _, item in ipairs(chosen) do
    local geometryText, seen, usable = {}, {}, true
    for _, id in ipairs(item.ids) do
      if not geometries[id] then usable = false break end
      if not seen[id] then
        seen[id] = true
        geometryText[#geometryText + 1] = geometries[id]
      end
    end
    if usable then
      found[item.name] = table.concat({'<?xml version="1.0" encoding="utf-8"?>\n', rootOpen, table.concat(shared),
        '<library_geometries>', table.concat(geometryText), '</library_geometries><library_visual_scenes>', vsOpen, item.node,
        '</visual_scene></library_visual_scenes>', sceneElement, '</COLLADA>'})
    end
  end
end

local function nodeNames(text)
  local names = {}
  for tag in text:gmatch('<node[^>]*>') do
    local name = tag:match('%sname="([^"]*)"') or tag:match('%sid="([^"]*)"')
    if name then names[decodeXml(name)] = true end
  end
  return names
end

-- the meshes shared by the vehicles are in the folder 'common'; which file has which is looked up once
local commonFiles
local function commonFileOf(name)
  if not commonFiles then
    commonFiles = {}
    for _, path in ipairs(listFiles().common or {}) do
      local text = readFile(path)
      for found in pairs(text and nodeNames(text) or {}) do commonFiles[found] = commonFiles[found] or path end
    end
  end
  return commonFiles[name]
end

-- wanted: {mesh name = true}; returns {mesh name = text} for the meshes found, in the model's folder or in 'common'
local function find(model, wanted)
  local found = {}
  local function cutFrom(path, text)
    text = text or readFile(path)
    if not text then return end
    local ok, err = pcall(cutOut, text, wanted, found)
    if not ok then log('W', 'physicsLimiterMeshSource', path .. ': ' .. tostring(err)) end
  end

  for _, path in ipairs(listFiles()[model] or {}) do
    local text = readFile(path)
    local present = text and nodeNames(text) or {}
    for name in pairs(wanted) do
      if not found[name] and present[name] then
        cutFrom(path, text)
        break
      end
    end
  end

  local paths = {}
  for name in pairs(wanted) do
    local path = not found[name] and commonFileOf(name)
    if path then paths[path] = true end
  end
  for path in pairs(paths) do cutFrom(path) end
  return found
end

M.find = find
M.refresh = function() daeByFolder, commonFiles = nil, nil end

return M
