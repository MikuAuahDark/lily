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

-- NOTICE: For custom `love.run` users.
-- 1. You have to explicitly pass event with name "lily_resp"
--    to `love.handlers.lily_resp` along with all of it's arguments.
-- 2. When you're handling "quit" event and you integrate Lily into
--    your `love.run` loop, call `lily.quit` before `return`.

-- Need love module
local love = require("love")
-- Need love.event and love.thread
assert(love.event, "Lily requires love.event. Enable it in conf.lua or require it manually!")
assert(love.thread, "Lily requires love.thread. Enable it in conf.lua or require it manually!")

local modulePath = select(1, ...):match("(.-)[^%.]+$")
local lily = {
	_VERSION = "3.0.0",
	-- Loaded modules
	modules = {},
	-- List of threads
	threads = {},
	-- Function handler
	handlers = {},
	-- Request list
	request = {}
}

-- List of excluded modules to be loaded (doesn't make sense to be async)
-- PS: "event" module will be always loaded regardless.
local excludedModules = {
	"event",
	"joystick",
	"keyboard",
	"math",
	"mouse",
	"physics",
	"system",
	"timer",
	"touch",
	"window"
}
-- List all loaded LOVE modules using hidden "love._modules" table
for name in pairs(love._modules) do
	local f = false
	for i = 1, #excludedModules do
		if excludedModules[i] == name then
			-- Excluded
			f = true
			break
		end
	end

	-- If not excluded, add it.
	if not(f) then
		lily.modules[#lily.modules + 1] = name
	end
end

-- We have some ways to get processor count
local amountOfCPU = 1
if love.system then
	-- love.system is loaded. We can use that.
	amountOfCPU = love.system.getProcessorCount()
elseif love._os == "Windows" then
	-- Windows. Use NUMBER_OF_PROCESSORS environment variable
	amountOfCPU = assert(tonumber(os.getenv("NUMBER_OF_PROCESSORS")), "Invalid NUMBER_OF_PROCESSORS")
elseif os.execute() == 1 then
	-- Ok we have shell support
	if os.execute("nproc") == 0 then
		-- Use nproc
		local a = io.popen("nproc", "r")
		amountOfCPU = a:read("*n")
		a:close()
	end
	-- Fallback to single core (discouraged, it will perform same as love-loader)
end

-- Dummy channel used to signal main thread that there's error
local errorChannel = love.thread.newChannel()
-- Main channel used to push task
lily.taskChannel = love.thread.newChannel()
-- Main channel used to pull task
lily.dataPullChannel = love.thread.newChannel()

-- Variable used to indicate that embedded code should be used
-- instead of loading file (lily_single)
local lilyThreadScript = nil

-- Function to initialize threads. Must be declared as local
-- then called later
local function initThreads()
	for i = 1, amountOfCPU do
		lily.threads[i] = love.thread.newThread(
			lilyThreadScript or
			(modulePath:gsub("%.", "/").."lily_thread.lua")
		)
	end
end

--luacheck: push no unused args
----------------
-- LilyObject --
----------------
local lilyObjectMethod = {}
local lilyObjectMeta = {__index = lilyObjectMethod}

-- Complete function
function lilyObjectMethod.complete(userdata, ...)
end

-- On error function
function lilyObjectMethod.error(userdata, errorMessage)
	error(errorMessage)
end

function lilyObjectMethod:onComplete(func)
	self.complete = assert(
		type(func) == "function" and func,
		"bad argument #1 to 'lilyObject:onComplete' (function expected)"
	)
	return self
end

function lilyObjectMethod:setUserData(userdata)
	self.userdata = userdata
	return self
end

function lilyObjectMethod:isComplete()
	return not(not(self.values))
end

function lilyObjectMethod:getValues()
	assert(self.values, "Incomplete request")
	return unpack(self.values)
end

function lilyObjectMeta:__tostring()
	return "LilyObject: "..self.requestType
end

---------------------
-- MultiLilyObject --
---------------------
local multiObjectMethod = {}
local multiObjectMeta = {__index = multiObjectMethod}
-- On loaded function (noop)
multiObjectMethod.loaded = lilyObjectMethod.complete
-- On error function
function multiObjectMethod.error(userdata, lilyIndex, errorMessage)
	error(errorMessage)
end
-- On complete function (noop)
multiObjectMethod.complete = lilyObjectMethod.complete
-- Internal function for child lilies error handler
local function multiObjectChildErrorHandler(userdata, errorMessage)
	-- Userdata is {index, parentObject}
	local multi = userdata[2]
	multi.error(multi.userdata, userdata[1], errorMessage)
end

-- Internal function used for child lilies onComplete callback
local function multiObjectOnLoaded(info, ...)
	-- Info is {index, parentObject}
	local multiLily = info[2]

	multiLily.completedRequest = multiLily.completedRequest + 1
	multiLily.loaded(multiLily.userdata, info[1], select(1, ...))

	-- If it's complete, then call onComplete callback of MultiLilyObject
	if multiLily:isComplete() then
		-- Process
		local output = {}
		for i = 1, #multiLily.lilies do
			output[i] = multiLily.lilies[i].values
		end

		multiLily.complete(multiLily.userdata, output)
	end
end

function multiObjectMethod:onLoaded(func)
	self.loaded = assert(
		type(func) == "function" and func,
		"bad argument #1 to 'lilyObject:onLoaded' (function expected)"
	)
	return self
end

function multiObjectMethod:onComplete(func)
	self.complete = assert(
		type(func) == "function" and func,
		"bad argument #1 to 'lilyObject:onComplete' (function expected)"
	)
	return self
end

function multiObjectMethod:onError(func)
	self.error = assert(
		type(func) == "function" and func,
		"bad argument #1 to 'lilyObject:onError' (function expected)"
	)
	return self
end

function multiObjectMethod:setUserData(userdata)
	self.userdata = userdata
	return self
end

function multiObjectMethod:isComplete()
	return self.completedRequest >= #self.lilies
end

function multiObjectMethod:getValues(index)
	assert(self.done, "Incomplete request")

	if index == nil then
		local output = {}
		for i = 1, #self.lilies do
			output[i] = self.lilies[i].values
		end

		return output
	end

	return assert(self.values[index], "Invalid index")
end

function multiObjectMethod:getCount()
	return #self.lilies
end

function multiObjectMethod:getLoadedCount()
	return self.completedRequest
end

multiObjectMeta.__len = multiObjectMethod.getCount

-- luacheck: pop

-- Add Lily event handler to love.handlers (lily_resp)
function love.handlers.lily_resp(reqID, ...)
	-- Check if specified request exist
	if lily.request[reqID] then
		local lilyObject = lily.request[reqID]
		lily.request[reqID] = nil

		-- Check for error
		if select(1, ...) == errorChannel then
			-- Second argument is the error message
			lilyObject.error(lilyObject.userdata, (select(2, ...)))
		else
			-- Call main thread handler for specified request type
			local values = {pcall(lily.handlers[lilyObject.requestType], lilyObject, select(1, ...))}
			-- If values[1] is false then there's error
			if not(values[1]) then
				lilyObject.error(lilyObject.userdata, values[2])
			else
				-- No error. Remove first value (pcall status)
				table.remove(values, 1)
				-- Set values table
				lilyObject.values = values
				lilyObject.complete(lilyObject.userdata, unpack(values))
			end
		end
	end
end

--- Get amount of thread for processing
-- In most cases, this is amount of logical CPU available.
-- @treturn number Amount of threads used by Lily.
function lily.getThreadCount()
	return amountOfCPU
end

--- Uninitializes Lily and used threads.
-- Call this just before your game quit (inside `love.quit()`).
-- Not calling this function in iOS and Android can cause
-- strange crash when re-starting your game!
function lily.quit()
	for i = 1, amountOfCPU do
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

----------------------------------------
-- Lily async asset loading functions --
----------------------------------------
local function dummyhandler(...)
	return select(2, ...)
end

local function wraphandler(fname)
	return function(...)
		return fname(select(2, ...))
	end
end

-- Internal function to create request ID
local function createReqID()
	local t = {}
	for _ = 1, 64 do
		t[#t + 1] = string.char(math.random(0, 255))
	end

	return table.concat(t)
end

-- Internal function which return function to create LilyObject
-- with specified request type
local function newLilyFunction(requestType, handlerFunc)
	-- This function is the constructor
	lily[requestType] = function(...)
		-- Initialize
		local this = setmetatable({}, lilyObjectMeta)
		local reqID = createReqID()
		local args = {...}
		-- Values
		this.requestType = requestType
		this.done = false
		this.values = nil

		-- Push task
		-- See structure in lily_thread.lua
		lily.taskChannel:push(reqID)
		lily.taskChannel:push(requestType)
		lily.taskChannel:push(#args)
		-- Push arguments
		for i = 1, #args do
			lily.taskChannel:push(args[i])
		end
		-- Insert to request table (to prevent GC collecting it)
		lily.request[reqID] = this
		-- Return
		return this
	end
	-- Handler function
	lily.handlers[requestType] = handlerFunc and wraphandler(handlerFunc) or dummyhandler
end

-- love.audio
if love.audio then
	newLilyFunction("newSource")
end

-- love.data (always exists)
if love.data then
	newLilyFunction("compress")
	newLilyFunction("decompress")
end

-- love.filesystem (always exists)
if love.filesystem then
	newLilyFunction("append")
	newLilyFunction("newFileData")
	newLilyFunction("read")
	newLilyFunction("readFile")
	newLilyFunction("write")
	newLilyFunction("writeFile")
end

-- Most love.graphics functions are not meant for multithread, but we can circumvent that.
if love.graphics then
	newLilyFunction("newFont", love.graphics.newFont)
	newLilyFunction("newImage", love.graphics.newImage)
	newLilyFunction("newVideo", love.graphics.newVideo)

	-- Get texture type
	local texType = love.graphics.getTextureTypes()
	-- Not all system support cube image. Make it unavailable in that case.
	if texType.cube then
		--newLilyFunction("newCubeImage", love.graphics.newCubeImage)
	end
end

if love.image then
	newLilyFunction("encodeImageData")
	newLilyFunction("newImageData")
	newLilyFunction("newCompressedData")
	newLilyFunction("pasteImageData")
end

if love.sound then
	newLilyFunction("newSoundData")
end

if love.video then
	newLilyFunction("newVideoStream")
end

-- do not remove this comment!
initThreads()
return lily

--[[
Changelog:
v3.0.0: Work In Progress
> Major refactoring
> Allow to set update mode, whetever to use Lily style (automatic) or love-loader style (manual)
> New functions: newArrayImage and newVolumeImage (only on supported systems)
> Loading speed improvements

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
