-- Physics Limiter by tmaster1000
-- Builds the stand-in templates of all vehicle models ahead of time: from the data of each model's default configuration,
-- without spawning anything, so it works in single player and in a BeamMP session alike. Models that have a template are
-- skipped, so an interrupted run can be repeated.
-- Console (GE): extensions.load('physicsLimiterPrebuild'); physicsLimiterPrebuild.start(); physicsLimiterPrebuild.status()

local M = {}
M.dependencies = {'physicsLimiterStandIns', 'physicsLimiterMeshSource'}

M.skip = {unicycle = true, spikestrip = true} -- not vehicles that drive

local running, cancelled = false, false
local failedModels = {} -- models that could not be built, until the next full run
local progress = {total = 0, done = 0, skipped = 0, failed = {}, current = nil}

-- a model whose folder has no vehicle data (e.g. one that only exists in the model list) can't be built
local function hasFiles(model)
  return #(FS:findFiles('/vehicles/' .. model .. '/', '*.jbeam', -1, true, false) or {}) > 0
end

local function modelNames()
  local names = {}
  local ok, list = pcall(function() return core_vehicles.getModelList().models end)
  for name in pairs(ok and list or {}) do
    if not M.skip[name] and not (list[name] and list[name].Type == 'Prop') and hasFiles(name) then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end

local function status()
  return string.format('%s: %d of %d models built (%d already had a template), now %s, failed: %s',
    running and 'running' or 'idle', progress.done, progress.total, progress.skipped, tostring(progress.current),
    #progress.failed > 0 and table.concat(progress.failed, ', ') or 'none')
end

local function stop()
  cancelled = true
end

-- options.rebuild: the saved templates are deleted first, so all models are built again (after a game update)
local function start(options)
  if running then return 'already running' end
  running, cancelled = true, false
  progress = {total = 0, done = 0, skipped = 0, failed = {}, current = nil}
  core_jobsystem.create(function(job)
    if physicsLimiterMeshSource then physicsLimiterMeshSource.refresh() end
    if options and options.rebuild then
      physicsLimiterStandIns.clearTemplates()
      table.clear(failedModels)
    end
    local ok, err = pcall(function()
      local names = modelNames()
      progress.total = #names
      for _, model in ipairs(names) do
        if cancelled then break end
        progress.current = model
        if physicsLimiterStandIns.hasTemplate(model) then
          progress.skipped = progress.skipped + 1
          progress.done = progress.done + 1
        else
          local timer = hptimer()
          local built = physicsLimiterStandIns.buildModelTemplate(model)
          log('I', 'physicsLimiterPrebuild', string.format('%s: %s in %.0f ms', model, built and 'built' or 'failed', timer:stop()))
          if built then
            progress.done = progress.done + 1
            failedModels[model] = nil
          else
            table.insert(progress.failed, model)
            failedModels[model] = true
          end
        end
        job.sleep(0)
      end
    end)
    if not ok then log('E', 'physicsLimiterPrebuild', 'Stopped: ' .. tostring(err)) end
    progress.current = nil
    running = false
    log('I', 'physicsLimiterPrebuild', status())
  end)
  return 'started'
end

-- for the settings window: {running, done, total, current, failed}
local function getProgress()
  return {running = running, done = progress.done, total = progress.total, current = progress.current, failed = #progress.failed}
end

M.getProgress = getProgress
M.hasFiles = hasFiles
M.failed = failedModels
M.start = start
M.stop = stop
M.status = status

return M
