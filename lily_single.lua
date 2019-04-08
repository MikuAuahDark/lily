-- LOVE Async Loading Library
-- Copyright (c) 2040 Dark Energy Processor
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

-- NOTICE: For custom `love.run` users.
-- 1. You have to explicitly pass event with name "lily_resp"
--    to `love.handlers.lily_resp` along with all of it's arguments.
-- 2. When you're handling "quit" event and you integrate Lily into
--    your `love.run` loop, call `lily.quit` before `return`.

local lily = {_VERSION = "2.0.15"}
local love = require("love")
assert(love._version >= "0.10.0", "Lily require at least LOVE 0.10.0")
local is_love_11 = love._version >= "11.0"

-- Get current script directory
local module_path = select(1, ...):match("(.-)[^%.]+$")
local lily_thread_script --luacheck: ignore lily_thread_script

-- We need love.event and love.thread
assert(love.event, "Lily requires love.event. Enable it in conf.lua")
assert(love.thread, "Lily requires love.thread. Enable it in conf.lua")

-- List active modules
local excluded_modules = {"event", "joystick", "keyboard", "mouse", "physics", "system", "timer", "touch", "window"}
lily.modules = {}
if is_love_11 then lily.modules[1] = "data" end
for a in pairs(love._modules) do
	local f = false
	for i = 1, #excluded_modules do
		if excluded_modules[i] == a then
			f = true
			break
		end
	end

	if not(f) then lily.modules[#lily.modules + 1] = a end
end

-- We have some ways to get processor count
local number_processor = 1
if love.system then
	-- love.system is loaded. We can use that.
	number_processor = love.system.getProcessorCount()
elseif love._os == "Windows" then
	-- Windows. Use NUMBER_OF_PROCESSORS environment variable
	number_processor = assert(tonumber(os.getenv("NUMBER_OF_PROCESSORS")), "Invalid NUMBER_OF_PROCESSORS")
elseif os.execute() == 1 then
	-- Ok we have shell support
	if os.execute("nproc") == 0 then
		-- Use nproc
		local a = io.popen("nproc", "r")
		number_processor = a:read("*n")
	end
	-- Well, fallback to single core (not recommended)
end
-- Limit CPU to 4. Imagine how many threads will be created when
-- someone runs this in threadripper.
number_processor = math.min(number_processor, 4)

-- Create n-threads
local errchannel = love.thread.newChannel()
lily.threads = {}

local function initThreads()
	for i = 1, number_processor do
		local a = {}
		a.channel_info = love.thread.newChannel()
		a.channel = love.thread.newChannel()
		a.thread = love.thread.newThread(
			lily_thread_script or
			module_path:gsub("%.", "/").."lily_thread.lua"
		)
		a.thread:start(lily.modules, math.random(), a.channel, a.channel_info, errchannel)

		lily.threads[i] = a
	end
	for i = 1, number_processor do
		local a = lily.threads[i]
		a.id = a.channel_info:demand()
		-- Wait until task_count count is added. Somehow, using suply/demand
		-- doesn't work, so busy wait is last resort.
		-- FIXME: Do not use busy wait!
		while a.channel_info:getCount() == 0 do end
	end
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
			lilyobj.error(lilyobj.userdata, select(2, ...))
		else
			-- No error. Pass it to secondary handler
			local values = {pcall(lily.handlers[lilyobj.request_type], lilyobj, select(1, ...))}

			if not(values[1]) then
				-- Error handler again
				lilyobj.error(lilyobj.userdata, values[2])
			else
				-- Ok no error.
				-- Remove first element
				for i = 2, #values do
					values[i - 1] = values[i]
				end
				values[#values] = nil

				lilyobj.values = values
				lilyobj.done = true
				lilyobj.complete(lilyobj.userdata, unpack(values))
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

-- If you're under mobile, call this before restarting/exiting your game
-- or the threads won't get cleaned up properly (undefined behaviour)
function lily.quit()
	for i = 1, number_processor do
		local a = lily.threads[i]
		if a then
			-- Pop the task count to tell lily threads to stop
			a.channel_info:pop()
			-- Wait it to finish
			-- Push thread id so demand returns a value
			-- and it unblocks the thread
			a.channel:push(a.id)
			-- Wait
			a.thread:wait()
			-- Clear
			lily.threads[i] = nil
		end
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
function lily_methods.__index.error(_, msg) return error(msg, 2) end

function lily_methods.__index.onComplete(this, func)
	this.complete = assert(type(func) == "function" and func, "bad argument #1 to 'lilyObject:onComplete' (function expected)")
	return this
end

function lily_methods.__index.onError(this, func)
	this.error = assert(type(func) == "function" and func, "bad argument #1 to 'lilyObject:onError' (function expected)")
	return this
end

function lily_methods.__index.setUserData(this, userdata)
	this.userdata = userdata
	return this
end

function lily_methods.__index.isComplete(this)
	return this.done
end

function lily_methods.__index.getValues(this)
	assert(this.done, "Incomplete request")
	return unpack(this.values)
end

function lily_methods.__tostring(this)
	return "lilyObject "..this.request_type
end

-- Request ID used to distinguish between different request
local function create_request_id()
	local t = {}
	for _ = 1, 64 do
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
	this.done = false

	-- Send request to other thread
	local thread = get_lowest_task_count()
	-- Push task
	thread.channel:push(thread.id)
	thread.channel:push(reqtype)
	thread.channel:push(this.req_id)
	thread.channel_info:performAtomic(increase_task_count)

	-- Push arguments
	thread.channel:push(#this.arguments)
	for i = 1, #this.arguments do
		thread.channel:push(this.arguments[i])
	end

	-- Insert to request table
	lily.request[this.req_id] = this

	return this
end

-- Multi Lily object. Loads everything in parallel
local multilily_methods = {__index = {}}
-- loaded(multilily, val)
multilily_methods.__index.loaded = lily_methods.__index.complete
-- error(msg)
function multilily_methods.__index.error(_, __, msg)
	error(msg, 2)
end
-- complete(lilydatas)
multilily_methods.__index.complete = lily_methods.__index.complete
-- error handler
local miltilily_single_lily_error_handler = function(userdata, msg)
	-- The userdata:
	-- 1st index is lilyindex, 2nd index is multilily object
	local multi = userdata[2]
	multi.error(multi.userdata, userdata[1], msg)
end

function multilily_methods.__len(this)
	return #this.lilies
end

function multilily_methods.__index.onLoaded(this, func)
	this.loaded = assert(type(func) == "function" and func, "bad argument #1 to 'lilyObject:onLoaded' (function expected)")
	return this
end

function multilily_methods.__index.onComplete(this, func)
	this.complete = assert(type(func) == "function" and func, "bad argument #1 to 'lilyObject:onComplete' (function expected)")
	return this
end

function multilily_methods.__index.onError(this, func)
	this.error = assert(type(func) == "function" and func, "bad argument #1 to 'lilyObject:onError' (function expected)")
	return this
end

function multilily_methods.__index.setUserData(this, userdata)
	this.userdata = userdata
	return this
end

function multilily_methods.__index.isComplete(this)
	return this.completed_request >= #this.lilies
end

function multilily_methods.__index.getValues(this, index)
	assert(this:isComplete(), "Incomplete request")

	if index == nil then
		local output = {}
		for i = 1, #this.lilies do
			output[i] = this.lilies[i].values
		end

		return output
	end

	return assert(this.lilies[index], "Invalid index"):getValues()
end

function multilily_methods.__index.getCount(this)
	return #this.lilies
end

function multilily_methods.__index.getLoadedCount(this)
	return this.completed_request
end

local function multilily_onLoaded(info, ...)
	local multilily = info[2]

	multilily.completed_request = multilily.completed_request + 1
	multilily.loaded(multilily.userdata, info[1], select(1, ...))

	if multilily:isComplete() then
		-- Process
		local output = {}
		for i = 1, #multilily.lilies do
			output[i] = multilily.lilies[i].values
		end

		multilily.complete(multilily.userdata, output)
	end
end

-- Multi Lily constructor
function lily.loadMulti(tabdecl)
	local this = setmetatable({
		lilies = {},
		completed_request = 0
	}, multilily_methods)

	for i = 1, #tabdecl do
		local tab = tabdecl[i]

		-- tab[1] is lily name, the rest is arguments
		local func

		if type(tab[1]) == "string" then
			if lily[tab[1]] and lily.handlers[tab[1]] then
				func = lily[tab[1]]
			else
				error("Invalid lily function ("..tab[1]..") at index #"..i)
			end
		elseif type(tab[1]) == "function" then
			-- Must be `lily[function]`
			func = tab[1]
		else
			error("Invalid lily function at index #"..i)
		end

		local lilyobj = func(unpack(tab, 2))
			:setUserData({i, this})
			:onComplete(multilily_onLoaded)
			:onError(miltilily_single_lily_error_handler)

		this.lilies[#this.lilies + 1] = lilyobj
	end

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
	-- Check if LOVE 11.0
	if is_love_11 then
		-- Not all system support cobe image, so make it unavailable
		-- if that's the case
		if love.graphics.getTextureTypes().cube then
			lily_new_func("newCubeImage", wraphandler(love.graphics.newCubeImage))
		end
	end
end

if love.image then
	lily_new_func("encodeImageData", dummyhandler)
	lily_new_func("newImageData", dummyhandler)
	lily_new_func("newCompressedData", dummyhandler)
	lily_new_func("pasteImageData", dummyhandler)
end

if love.math and not(is_love_11) or love.data then
	local function dataGetString(_, value)
		return value:getString()
	end

	-- Notice: compress/decompress in lily expects it to be string
	lily_new_func("compress", dataGetString)
	lily_new_func("decompress", dataGetString)
end

if love.sound then
	lily_new_func("newSoundData", dummyhandler)
end

if love.video then
	lily_new_func("newVideoStream", dummyhandler)
end

lily_thread_script = [===[
-- LOVE Async Loading Library (Thread Part)
-- Copyright (c) 2040 Dark Energy Processor
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

local love = require("love")
local modules, seed, channel, channel_info, errorindicator = ...
local nts_modules = {"graphics", "window"}
local has_graphics = false
local is_love_11 = love._version >= "11.0"

-- We need love.event, always.
require("love.event")
math.randomseed((math.random() + seed) * 1073741823.5)

-- Load modules
for _, v in pairs(modules) do
	local f = false
	if v == "graphics" then has_graphics = true end

	for i = 1, #nts_modules do
		if nts_modules[i] == v then
			f = true
			break
		end
	end

	if not(f) then
		require("love."..v)
	end
end

local thread_lily_id
do
	-- Generate our lily thread id
	-- Lily thread id consist of 64 printable ASCII char
	local t = {}
	for _ = 1, 64 do
		t[#t + 1] = string.char(math.floor(math.random() * 94 + 32))
	end

	-- Supply the thread id
	-- Supply means push + wait until received.
	thread_lily_id = table.concat(t)
	channel_info:supply(thread_lily_id)
	-- Push current lily thread task count
	channel_info:push(0)
end

-- Function handlers
local reg = debug.getregistry()
local lily_processor = {}
local function push_data(req_id, ...)
	return love.event.push("lily_resp", req_id, select(1, ...))
end

-- Macto function to create table handler
local function lily_handler_func(reqtype, minarg, handler)
	lily_processor[reqtype] = {minarg = minarg, handler = handler}
end

if love.audio then
	-- LOVE 11.0 requires 2 arguments to love.audio.newSource
	-- but LOVE 0.10.0 only requires 1
	local argc = is_love_11 and 2 or 1
	lily_handler_func("newSource", argc, function(t)
		return love.audio.newSource(t[1], t[2])
	end)
end

-- Always exist
if love.filesystem then
	lily_handler_func("append", 2, function(t)
		return assert(love.filesystem.append(t[1], t[2], t[3]))
	end)
	lily_handler_func("newFileData", 1, function(t)
		return assert(love.filesystem.newFileData(t[1], t[2], t[3]))
	end)
	lily_handler_func("read", 1, function(t)
		return assert(love.filesystem.read(t[1], t[2]))
	end)
	lily_handler_func("readFile", 1, function(t)
		return reg.File.read(t[1], t[2])
	end)
	lily_handler_func("write", 2, function(t)
		return assert(love.filesystem.write(t[1], t[2], t[3]))
	end)
	lily_handler_func("writeFile", 2, function(t)
		return reg.File.write(t[1], t[2], t[3])
	end)
end

if has_graphics then
	lily_handler_func("newFont", 1, function(t)
		return love.font.newRasterizer(t[1], t[2]), t[2] -- This should work.
	end)
	lily_handler_func("newImage", 1, function(t)
		local s, x = pcall(love.image.newImageData, t[1])
		return (s and x or love.image.newCompressedData(t[1])), select(2, unpack(t))
	end)
	lily_handler_func("newVideo", 1, function(t)
		return love.video.newVideoStream(t[1]), t[2]
	end)
	lily_handler_func("newCubeImage", 1, function(t)
		-- If it's not table, then it should be processed with
		-- love.image.newCubeFaces (undocumented function)
		if type(t[1]) ~= "table" then
			local id = t[1]
			if type(id) ~= "userdata" or id:type() ~= "ImageData" then
				id = love.image.newImageData(id)
			end
			t[1] = {love.image.newCubeFaces(id)}
		end
		for i = 1, 6 do
			local v = t[1][i]
			local t = v:type()
			if t ~= "userdata" or (t ~= "ImageData" and t ~= "CompressedImageData") then
				t[1][i] = love.image.newImageData(v)
			end
		end
		return t[1], t[2]
	end)
end

if love.image then
	lily_handler_func("encodeImageData", 1, function(t)
		return reg.ImageData.encode(t[1], t[2])
	end)
	lily_handler_func("newImageData", 1, function(t)
		return love.image.newImageData(t[1])
	end)
	lily_handler_func("newCompressedData", 1, function(t)
		return love.image.newCompressedData(t[1])
	end)
	lily_handler_func("pasteImageData", 7, function(t)
		return reg.ImageData.paste(t[1], t[2], t[3], t[4], t[5], t[6], t[7])
	end)
end

if love.math and not(is_love_11) then
	local function isCompressedData(t)
		return type(t) == "userdata" and t:typeOf("CompressedData")
	end

	lily_handler_func("compress", 2, function(t)
		-- lily.compress expects LOVE 11.0 order. That's it, format first then data then level
		return love.math.compress(t[2], t[1], t[3])
	end)
	lily_handler_func("decompress", 1, function(t)
		-- lily.decompress expects LOVE 11.0 order too.
		if isCompressedData(t[1]) then
			-- CompressedData supplied as first argument
			return love.filesystem.newFileData(love.math.decompress(t[1]), "")
		else
			-- string or Data is supplied as first argument (format)
			return love.filesystem.newFileData(love.math.decompress(t[2], t[1]), "")
		end
	end)
elseif love.data then
	lily_handler_func("compress", 2, function(t)
		return love.data.compress("data", t[1], t[2], t[3])
	end)
	lily_handler_func("decompress", 1, function(t)
		return love.data.decompress("data", t[1], t[2])
	end)
end

if love.sound then
	lily_handler_func("newSoundData", 1, function(t)
		return love.sound.newSoundData(t[1], t[2], t[3], t[4])
	end)
end

if love.video then
	lily_handler_func("newVideoStream", 1, function(t)
		return love.video.newVideoStream(t[1])
	end)
end

-- Function to update the current task count
-- Meant to be passed to Channel:performAtomic
local function decrease_task_count()
	local task_count = channel_info:pop()

	if not(task_count) then return end
	channel_info:push(task_count - 1)
end

local function not_quit()
	return channel_info:getCount() == 1
end

local handlerFunc
local handlerArg
local function callHandler()
	return handlerFunc(handlerArg)
end

-- If main thread puses anything to channel_info, or pop the count, that means we should exit
while channel_info:performAtomic(not_quit) do
	collectgarbage()
	-- Structure
	-- 1. thread_id
	-- 2. task type
	-- 3. request ID
	-- 4. argument count
	-- n arguments.
	local tid = channel:demand()
	if not(not_quit()) then return end -- These 3 checks must be on each demand!
	local tasktype = channel:demand()
	if not(not_quit()) then return end -- so even on incomplete, we cna quit
	local req_id = channel:demand()
	if not(not_quit()) then return end -- faster and more earlier.
	

	if not(lily_processor[tasktype]) then
		-- We don't know such event.
		local argcount = channel:demand()
		for i = 1, argcount do
			channel:pop()
		end
	else
		-- We know such event.
		local task = lily_processor[tasktype]
		local inputs = {}

		-- Get all arguments first, so the channel is clean.
		local argcount = channel:demand()
		for i = 1, argcount do
			inputs[i] = channel:demand()
		end
		
		if argcount < task.minarg then
			-- Error: too few arguments
			push_data(req_id, errorindicator, string.format("'%s': too few arguments (at least %d is required)", tasktype, task.minarg))
		else
			handlerFunc = task.handler
			handlerArg = inputs
			local result = {xpcall(callHandler, debug.traceback)}

			if result[1] == false then
				-- Error
				push_data(req_id, errorindicator, string.format("'%s': %s", tasktype, result[2]))
			else
				-- Remove first element
				for i = 2, #result do
					result[i - 1] = result[i]
				end
				result[#result] = nil

				-- Unfortunately, due to default love.run way to handle events
				-- we can't pass more than 6 arguments to event.
				-- We must pass "req_id", which means we only able to return 5 values.
				if #result == 0 then
					push_data(req_id)
				elseif #result == 1 then
					push_data(req_id, result[1])
				elseif #result == 2 then
					push_data(req_id, result[1], result[2])
				elseif #result == 3 then
					push_data(req_id, result[1], result[2], result[3])
				elseif #result == 4 then
					push_data(req_id, result[1], result[2], result[3], result[4])
				elseif #result >= 5 then
					push_data(req_id, result[1], result[2], result[3], result[4], result[5])
				end
			end
		end
	end

	channel_info:performAtomic(decrease_task_count)
end
]===]
-- do not remove this comment!
initThreads()
return lily

--[[
Changelog:
v2.0.15: 08-04-2018
> Reorder lily.newImage image loading function

v2.0.14: 26-12-2018
> Limit to 4 threads.

v2.0.13: 25-11-2018
> Fixed `lily.decompress` error if Data other than CompressedData is specified

v2.0.12: 17-11-2018
> Fixed `lily.decompress` error

v2.0.11: 29-09-2018
> Fixed `MultiLilyObject:getValues()` errors despite `MultiLilyObject:isComplete() == true`

v2.0.10: 18-07-2018
> Fixed calling `lily.newCompressedData` crashes Lily thread

v2.0.9: 16-07-2018
> `lily.newFont` ignores size parameter

v2.0.8: 09-06-2018
> Fixed additional arguments were not passed to task handler in separate thread
> Make error message more meaningful (but the stack traceback is still meaningless)

v2.0.7: 06-06-2018
> Fixed `lily.quit` deadlock.

v2.0.6: 05-06-2018
> Added `lily.newCubeImage`
> Fix error handler function signature incorrect for MultiLilyObject
> Added `MultiLilyObject:getLoadedCount()`

v2.0.5: 02-05-2018
> Fixed LOVE 11.0 detection

v2.0.4: 09-01-2018
> Fixed if love.data emulation is used in 0.10.0

v2.0.2: 04-01-2018
> Fixed random crash (again)
> Fixed when lily in folder, it doesn't work

v2.0.1: 03-01-2018
> Fixed random crash

v2.0.0: 01-01-2018
> Support `newVideoStream`
> Support multi loading (`lily.loadMulti`)
> More methods for `LilyObject`

v1.0.0: 21-12-2017
> Initial Release
]]
