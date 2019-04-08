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

-- Task channel structure (inside table)
-- request ID (string) or error channel to signal quit
-- Task name (string)
-- Amount of arguments (number)
-- n-amount of arguments (Variant)

-- Load LOVE module
local love = require("love")
require("love.event")
require("love.data")
-- Non-thread-safe modules
local ntsModules = {"graphics", "window"}
-- But love.graphics must be treated specially
local hasGraphics = false

-- See lily.lua initThreads() function for more information about
-- arguments passed
local modules, errorChannel, taskChannel, dataPullChannel, updateModeChannel = ...

-- Load modules
for _, v in pairs(modules) do
	local f = false
	if v == "graphics" then hasGraphics = true end

	for i = 1, #ntsModules do
		if ntsModules[i] == v then
			f = true
			break
		end
	end

	if not(f) then
		require("love."..v)
	end
end

-- Handlers
local lilyProcessor = {}
local getUpdateMode
do
	local function atomicFuncGetUpdateMode()
		return updateModeChannel:peek()
	end
	function getUpdateMode()
		return updateModeChannel:performAtomic(atomicFuncGetUpdateMode)
	end
end

-- Function to push data
local function pushData(reqID, v1, v2)
	local updateMode = getUpdateMode()
	if updateMode == "automatic" then
		-- Event push
		love.event.push("lily_resp", reqID, v1, v2)
	elseif updateMode == "manual" then
		-- Channel push
		dataPullChannel:push({reqID, v1, v2})
	end
end

-- Macro function to create handler
local function lilyHandlerFunc(reqtype, minarg, handler)
	lilyProcessor[reqtype] = {minarg = minarg, handler = handler}
end


if love.audio then
	lilyHandlerFunc("newSource", 2, function(t)
		return love.audio.newSource(t[1], t[2])
	end)
end

-- Always exist
if love.data then
	local function isCompressedData(t)
		return type(t) == "userdata" and t:typeOf("CompressedData")
	end

	lilyHandlerFunc("compress", 1, function(t)
		return love.data.compress("data", t[1] or "lz4", t[2], t[3])
	end)
	lilyHandlerFunc("decompress", 1, function(t)
		if type(t[2]) == "userdata" and t[2]:typeOf("Data") and love._version < "11.2" then
			-- Prior to LOVE 11.2, love.data.decompress can't decompress
			-- Data object (not CompressedData) due to bug in the code
			-- when handling this variant. So, convert it to string before
			-- passing it.
			t[2] = t[2]:getString()
		end
		return love.data.decompress("data", t[1], t[2])
	end)
end

-- Always exist
if love.filesystem then
	lilyHandlerFunc("append", 2, function(t)
		return assert(love.filesystem.append(t[1], t[2], t[3]))
	end)
	lilyHandlerFunc("newFileData", 1, function(t)
		return assert(love.filesystem.newFileData(t[1], t[2], t[3]))
	end)
	lilyHandlerFunc("read", 1, function(t)
		return assert(love.filesystem.read(t[1], t[2]))
	end)
	lilyHandlerFunc("readFile", 1, function(t)
		return t[1].read(t[1], t[2])
	end)
	lilyHandlerFunc("write", 2, function(t)
		return assert(love.filesystem.write(t[1], t[2], t[3]))
	end)
	lilyHandlerFunc("writeFile", 2, function(t)
		return t[1].write(t[1], t[2], t[3])
	end)
end

if hasGraphics then
	lilyHandlerFunc("newFont", 1, function(t)
		return love.font.newRasterizer(t[1], t[2])
	end)
	lilyHandlerFunc("newImage", 1, function(t)
		local s, x = pcall(love.image.newImageData, t[1])
		return (s and x or love.image.newCompressedData(t[1])), select(2, unpack(t))
	end)
	lilyHandlerFunc("newVideo", 1, function(t)
		return love.video.newVideoStream(t[1]), t[2]
	end)
	lilyHandlerFunc("newCubeImage", 1, function(t)
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
	lilyHandlerFunc("encodeImageData", 1, function(t)
		return t[1].encode(t[1], t[2])
	end)
	lilyHandlerFunc("newImageData", 1, function(t)
		return love.image.newImageData(t[1])
	end)
	lilyHandlerFunc("newCompressedData", 1, function(t)
		return love.image.newCompressedData(t[1])
	end)
	lilyHandlerFunc("pasteImageData", 7, function(t)
		return t[1].paste(t[1], t[2], t[3], t[4], t[5], t[6], t[7])
	end)
end

if love.sound then
	lilyHandlerFunc("newSoundData", 1, function(t)
		return love.sound.newSoundData(t[1], t[2], t[3], t[4])
	end)
end

if love.video then
	lilyHandlerFunc("newVideoStream", 1, function(t)
		return love.video.newVideoStream(t[1])
	end)
end

local handlerFunc
local handlerArg
local function callHandler()
	return handlerFunc(handlerArg)
end

-- Main loop
while true do
	collectgarbage()
	-- Get request (see the beginning of file for table format)
	local request = taskChannel:demand()
	-- If it's not table then quit signaled
	if type(request) ~= "table" then return end
	local tasktype = request[2]

	-- If it's exist in lilyProcessor table that means it's valid event
	if lilyProcessor[tasktype] then
		local task = lilyProcessor[tasktype]
		local argc = request[3]
		-- Check minarg count
		if argc < task.minarg then
			-- Too few arguments
			pushData(request[1], errorChannel, string.format(
				"'%s': too few arguments (at least %d is required)",
				tasktype,
				task.minarg
			))
		else
			local argv = {}
			-- Get arguments
			for i = 1, argc do
				argv[i] = request[3 + i] -- 4th and later are arguments
			end

			-- Call
			handlerFunc = task.handler
			handlerArg = argv
			local result = {xpcall(callHandler, debug.traceback)}
			if result[1] == false then
				-- Error
				pushData(request[1], errorChannel, string.format("'%s': %s", tasktype, result[2]))
			end
			-- Push data (v1 is true, v2 is return values)
			table.remove(result, 1)
			pushData(request[1], true, result)
		end
	end
end
