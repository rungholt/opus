_G.requireInjector()

local Util = require('util')

_G.kernel = {
  UID = 0,
  hooks = { },
  routines = { },
  terminal = _G.term.current(),
  window = _G.term.current(),
}

local fs     = _G.fs
local kernel = _G.kernel
local os     = _G.os
local shell  = _ENV.shell
local term   = _G.term

local focusedRoutineEvents = Util.transpose {
  'char', 'key', 'key_up',
  'mouse_click', 'mouse_drag', 'mouse_scroll', 'mouse_up',
  'paste', 'terminate',
}

_G.debug = function(pattern, ...)
  local oldTerm = term.redirect(kernel.window)
  Util.print(pattern, ...)
  term.redirect(oldTerm)
end

-- any function that runs in a kernel hook does not run in
-- a separate coroutine or have a window. an error in a hook
-- function will crash the system.
function kernel.hook(event, fn)
  if type(event) == 'table' then
    for _,v in pairs(event) do
      kernel.hook(v, fn)
    end
  else
    if not kernel.hooks[event] then
      kernel.hooks[event] = { }
    end
    table.insert(kernel.hooks[event], fn)
  end
end

-- you can only unhook from within the function that hooked
function kernel.unhook(event, fn)
  local eventHooks = kernel.hooks[event]
  if eventHooks then
    Util.removeByValue(eventHooks, fn)
    if #eventHooks == 0 then
      kernel.hooks[event] = nil
    end
  end
end

local Routine = { }

function Routine:resume(event, ...)
  if not self.co or coroutine.status(self.co) == 'dead' then
    return
  end

  if not self.filter or self.filter == event or event == "terminate" then
    local previousTerm = term.redirect(self.terminal)

    local previous = kernel.running
    kernel.running = self -- stupid shell set title
    local ok, result = coroutine.resume(self.co, event, ...)
    kernel.running = previous

    self.terminal = term.current()
    term.redirect(previousTerm)

    if ok then
      self.filter = result
    else
      _G.printError(result)
    end
    if coroutine.status(self.co) == 'dead' then
      Util.removeByValue(kernel.routines, self)
      if #kernel.routines > 0 then
        os.queueEvent('kernel_focus', kernel.routines[1].uid)
      end
      if self.haltOnExit then
        kernel.halt()
      end
    end
    return ok, result
  end
end

function kernel.getFocused()
  return kernel.routines[1]
end

function kernel.getCurrent()
  return kernel.running
end

function kernel.newRoutine(args)
  kernel.UID = kernel.UID + 1

  args = args or { }

  local routine = setmetatable(args, { __index = Routine })
  routine.uid = kernel.UID
  routine.timestamp = os.clock()
  routine.env = args.env or Util.shallowCopy(shell.getEnv())
  routine.terminal = args.terminal or kernel.terminal
  routine.window = args.window or kernel.window

  return routine
end

function kernel.launch(routine)
  routine.co = routine.co or coroutine.create(function()
    local result, err

    if routine.fn then
      result, err = Util.runFunction(routine.env, routine.fn, table.unpack(routine.args or { } ))
    elseif routine.path then
      result, err = Util.run(routine.env, routine.path, table.unpack(routine.args or { } ))
    else
      err = 'kernel: invalid routine'
    end

    if not result and err and err ~= 'Terminated' then
      _G.printError(tostring(err))
    end
  end)

  table.insert(kernel.routines, routine)

  local s, m = routine:resume()

  return not s and s or routine.uid, m
end

function kernel.run(args)
  local routine = kernel.newRoutine(args)
  kernel.launch(routine)
  return routine
end

function kernel.raise(uid)
  local routine = Util.find(kernel.routines, 'uid', uid)

  if routine then
    local previous = kernel.routines[1]
    if routine ~= previous then
      Util.removeByValue(kernel.routines, routine)
      table.insert(kernel.routines, 1, routine)
    end
    os.queueEvent('kernel_focus', routine.uid, previous and previous.uid)
    return true
  end
  return false
end

function kernel.lower(uid)
  local routine = Util.find(kernel.routines, 'uid', uid)

  if routine and #kernel.routines > 1 then
    if routine == kernel.routines[1] then
      local nextRoutine = kernel.routines[2]
      if nextRoutine then
        kernel.raise(nextRoutine.uid)
      end
    end

    Util.removeByValue(kernel.routines, routine)
    table.insert(kernel.routines, routine)
    return true
  end
  return false
end

function kernel.find(uid)
  return Util.find(kernel.routines, 'uid', uid)
end

function kernel.halt()
  os.queueEvent('kernel_halt')
end

function kernel.event(event, eventData)
  local stopPropagation

  local eventHooks = kernel.hooks[event]
  if eventHooks then
    for i = #eventHooks, 1, -1 do
      stopPropagation = eventHooks[i](event, eventData)
      if stopPropagation then
        break
      end
    end
  end

  if not stopPropagation then
    if focusedRoutineEvents[event] then
      local active = kernel.routines[1]
      if active then
        active:resume(event, table.unpack(eventData))
      end
    else
      -- Passthrough to all processes
      for _,routine in pairs(Util.shallowCopy(kernel.routines)) do
        routine:resume(event, table.unpack(eventData))
      end
    end
  end
end

function kernel.start()
  local s, m = pcall(function()
    repeat
      local eventData = { os.pullEventRaw() }
      local event = table.remove(eventData, 1)
      kernel.event(event, eventData)
    until event == 'kernel_halt' or not kernel.routines[1]
  end)

  kernel.window.setVisible(true)
  if not s then
    print('\nCrash detected\n')
    _G.printError(m)
  end
  term.redirect(kernel.terminal)
end

local function loadExtensions(runLevel)
  local dir = 'sys/extensions'
  local files = fs.list(dir)
  table.sort(files)
  for _,file in ipairs(files) do
    local level, name = file:match('(%d).(%S+).lua')
--print(name)
    if tonumber(level) <= runLevel then
      local s, m = shell.run(fs.combine(dir, file))
      if not s then
        error(m)
      end
      --os.sleep(0)
    end
  end
end

local args = { ... }
loadExtensions(args[1] and tonumber(args[1]) or 7)