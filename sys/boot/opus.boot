local fs = _G.fs

-- override bios function to include the actual filename
function _G.loadfile(filename, env)
    -- Support the previous `loadfile(filename, env)` form instead.
    if type(mode) == "table" and env == nil then
        mode, env = nil, mode
    end

    local file = fs.open(filename, "r")
    if not file then return nil, "File not found" end

    local func, err = load(file.readAll(), '@' .. filename, mode, env)
    file.close()
    return func, err
end

local sandboxEnv = setmetatable({ }, { __index = _G })
for k,v in pairs(_ENV) do
	sandboxEnv[k] = v
end

local function run(file, ...)
	local env = setmetatable({ }, { __index = _G })
	for k,v in pairs(sandboxEnv) do
		env[k] = v
	end

	local s, m = loadfile(file, env)
	if s then
		return s(...)
	end
	error('Error loading ' .. file .. '\n' .. m)
end

_G._syslog = function() end
_G.OPUS_BRANCH = 'develop-1.8'

-- Install require shim
_G.requireInjector = run('sys/modules/opus/injector.lua')

local s, m = pcall(run, 'sys/apps/shell.lua', 'sys/kernel.lua', ...)

if not s then
	print('\nError loading Opus OS\n')
	_G.printError(m .. '\n')
end

if fs.restore then
	fs.restore()
end
