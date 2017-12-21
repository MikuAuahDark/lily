-- LOVE Async Loading Library
-- Copyright (c) 2039 Dark Energy Processor
-- 
-- This software is provided 'as-is', without any express or implied
-- warranty. In no event will the authors be held liable for any damages
-- arising from the use of this software.
-- 
-- Permission is granted to anyone to use this software for any purpose,
-- including commercial applications, and to alter it and redistribute it
-- freely, subject to the following restrictions:
-- 
-- 1. The origin of this software must not be misrepresented; you must not
--    claim that you wrote the original software. If you use this software
--    in a product, an acknowledgment in the product documentation would be
--    appreciated but is not required.
-- 2. Altered source versions must be plainly marked as such, and must not be
--    misrepresented as being the original software.
-- 3. This notice may not be removed or altered from any source distribution.

local lily = {_VERSION = "1.0.0"}
local love = require("love")

-- Get current script directory
local _arg = {...}
local module_path

if type(_arg[1]) == "string" then
	-- Oh, standard Lua require
	module_path = _arg[1]:match("(.-)[^%.]+$")
else
	-- In case it's loaded from AquaShine.LoadModule
	module_path = ""
end

-- We need love.event and love.thread
assert(love.event, "Lily requires love.event. Enable it in conf.lua")
assert(love.thread, "Lily requires love.thread. Enable it in conf.lua")

-- List active modules
local excluded_modules = {"event", "joystick", "keyboard", "mouse", "physics", "system", "timer", "touch", "window"}
lily.modules = {}
if love.data then lily.modules[1] = "data" end
for a, b in pairs(love._modules) do
	local f = false
	for i = 1, #excluded_modules do
		if excluded_modules[i] == a then
			f = true
			break
		end
	end
	
	if not(f) then lily.modules[#lily.modules + 1] = a end
end
--print(lily)

-- We have some ways to get processor count
local number_processor = 1
if love.system then
	-- love.system is loaded. We can use that.
	number_processor = love.system.getProcessorCount()
elseif package.path:find("\\", 1, true) then
	-- Windows. Use NUMBER_OF_PROCESSORS environment variable
	number_processor = assert(tonumber(os.getenv("NUMBER_OF_PROCESSORS")), "NUMBER_OF_PROCESSORS is not a valid processor number")
elseif os.execute() == 1 then
	-- Ok we have shell support
	if os.execute("nproc") == 0 then
		-- Use nproc
		local a = io.popen("nproc", "r")
		number_processor = a:read("*n")
	end
	-- Well, fallback to single core (not recommended)
end

-- Create n-threads
local errchannel = love.thread.newChannel()
lily.threads = {}
for i = 1, number_processor do
	local a = {}
	a.channel_info = love.thread.newChannel()
	a.channel = love.thread.newChannel()
	a.thread = love.thread.newThread(module_path:gsub(".", "/").."lily_thread.lua")
	a.thread:start(lily.modules, math.random(), a.channel, a.channel_info, errchannel)
	
	lily.threads[i] = a
end
for i = 1, number_processor do
	local a = lily.threads[i]
	a.id = a.channel_info:demand()
end

-- Function handler
lily.handlers = {}
local dummyhandler = function(...) return select(2, ...) end
local wraphandler = function(fname)
	return function(...)
		return fname(select(2, ...))
	end
end

-- LOVE handlers
lily.request = {}
function love.handlers.lily_resp(req_id, ...)
	if lily.request[req_id] then
		local lilyobj = lily.request[req_id]
		lily.request[req_id] = nil
		
		-- If there's error, then the second value is the error message
		if select(1, ...) == errchannel then
			lilyobj.error(select(2, ...))
		else
			-- No error. Pass it to secondary handler
			local values = {pcall(lily.handlers[lilyobj.request_type], lilyobj, select(1, ...))}
			
			if not(values[1]) then
				-- Error handler again
				lilyobj.error(values[2])
			else
				-- Ok no error.
				-- Remove first element
				for i = 2, #values do
					values[i - 1] = values[i]
				end
				values[#values] = nil
				
				lilyobj.complete(unpack(values))
			end
		end
	end
end

local function get_task_count(channel)
	return channel:peek()
end

local function increase_task_count(channel)
	local task_count = channel:pop()
	return channel:push(task_count + 1)
end

-- Lily useful function
function lily.getThreadCount()
	return number_processor
end

function lily.getThreadsTaskCount()
	local t = {}
	
	for i = 1, number_processor do
		local a = lily.threads[i]
		
		t[i] = a.channel_info:performAtomic(get_task_count)
	end
	
	return t
end

-- If you're under iOS, call this before restarting your game
-- or the threads won't get cleaned up properly (undefined behaviour)
function lily.quit()
	for i = 1, number_processor do
		local a = lily.threads[i]
		-- Pop the task count to tell lily threads to stop
		a.channel_info:pop()
		-- Wait it to finish
		a.thread:wait()
	end
	
	-- Reset package table
	package.loaded.lily = nil
end

-- Private function. Returns the thread table
local function get_lowest_task_count()
	local t = lily.getThreadsTaskCount()
	local highestidx = 1
	local lowestval = 1
	
	for i = 1, #t do
		if t[i] < lowestval then
			lowestval = t[i]
			highestidx = i
		end
	end
	
	return lily.threads[highestidx]
end

-- Lily object
local lily_methods = {__index = {}}

function lily_methods.__index.complete() end
function lily_methods.__index.error(msg) return error(msg, 2) end

function lily_methods.__index.onComplete(this, func)
	this.complete = assert(type(func) == "function" and func, "bad argument #1 to 'lilyObject:onComplete' (function expected)")
	return this
end

function lily_methods.__index.onError(this, func)
	this.error = assert(type(func) == "function" and func, "bad argument #1 to 'lilyObject:onComplete' (function expected)")
	return this
end

-- Request ID used to distinguish between different request
local function create_request_id()
	local t = {}
	for i = 1, 64 do
		t[#t + 1] = string.char(math.random(0, 255))
	end
	
	return table.concat(t)
end

local function new_lily_object(reqtype, ...)
	-- Initialize
	local this = setmetatable({}, lily_methods)
	this.request_type = reqtype
	this.req_id = create_request_id()
	this.arguments = {...}
	
	-- Send request to other thread
	local thread = get_lowest_task_count()
	-- Push task
	thread.channel:push(thread.id)
	thread.channel:push(reqtype)
	thread.channel:push(this.req_id)
	thread.channel_info:performAtomic(increase_task_count)
	
	-- Push arguments
	for i = 1, #this.arguments do
		thread.channel:push(this.arguments[i])
	end
	
	-- Insert to request table
	lily.request[this.req_id] = this
	
	return this
end

-- Macro function to define most operation
local function lily_new_func(reqtype, handler)
	lily[reqtype] = function(...)
		return new_lily_object(reqtype, select(1, ...))
	end
	lily.handlers[reqtype] = handler
end

-- LOVE audio handler
if love.audio then
	lily_new_func("newSource", dummyhandler)
end

-- Well, love.filesystem always exists anyway
if love.filesystem then
	lily_new_func("append", dummyhandler)
	lily_new_func("newFileData", dummyhandler)
	lily_new_func("read", dummyhandler)
	lily_new_func("readFile", dummyhandler)
	lily_new_func("write", dummyhandler)
	lily_new_func("writeFile", dummyhandler)
end

-- Most love.graphics functions are not meant for multithread, but we can circumvent that.
if love.graphics then
	lily_new_func("newFont", wraphandler(love.graphics.newFont))
	lily_new_func("newImage", wraphandler(love.graphics.newImage))
	lily_new_func("newVideo", wraphandler(love.graphics.newVideo))
end

if love.image then
	lily_new_func("encodeImageData", dummyhandler)
	lily_new_func("newImageData", wraphandler(love.image.newImageData))
	lily_new_func("newCompressedData", wraphandler(love.image.newCompressedData))
	lily_new_func("pasteImageData", dummyhandler)
end

if love.math and love._version < "0.11.0" or love.data then
	-- Notice: compress/decompress in lily expects it to be string
	lily_new_func("compress", function(lilyobj, value)
		return value:getString()
	end)
	lily_new_func("decompress", dummyhandler)
end

if love.sound then
	lily_new_func("newSoundData", dummyhandler)
end

return lily
