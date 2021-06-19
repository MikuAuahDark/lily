Lily
====

LOVE Async Loading library. Uses multiple thread to load your assets (depends on amount of CPU)

Example
-------

This code snippet displays "Loading image" if the image hasn't been loaded and "Loading song" if the audio hasn't been loaded

```lua
local lily = require("lily")
local myimage
local mysound

function love.load()
	lily.newImage("image.png"):onComplete(function(userdata, image)
		-- In v2.0, there's "userdata" before the return value
		myimage = image
	end)
	lily.newSource("song.wav"):onComplete(function(userdata, sound)
		-- In v2.0, there's "userdata" before the return value
		mysound = sound
		sound:play()
	end)
end

function love.draw()
	if myimage then love.graphics.draw(myimage, 0, 24, 0, 0.25, 0.25)
	else love.graphics.print("Loading image") end
	if not(mysound) then love.graphics.print("Loading song", 0, 12) end
end
```

Example of multi loading

```lua
local lily = require("lily")

function love.load()
	multilily = lily.loadMulti({
		{"newImage", "image1-0.png"},	-- You can use string
		{lily.newImage, love.filesystem.newFile("image1-1.png")},	-- or the function object
	})
	multilily:onComplete(function(_, lilies)
		image1 = lilies[1][1]
		image2 = lilies[2][1]
	end)
end

function love.update() end
function love.draw()
	if multilily:isComplete() then
		love.graphics.draw(image1, -1024, -1024)
		love.graphics.draw(image2)
	end
end
```

Version Compatibility
---------------------

Lily v3.0 is not compatible with LOVE 0.10.x. Latest version which is compatible with LOVE 0.10.x is Lily v2.0.x
and can be found in `v2.0` branch. In case of bug fix, it will be backported to v2.0 branch when applicable.

Install
-------

Put `lily.lua` and `lily_thread.lua` in your LOVE game and `require("lily")`. Or use `lily_single.lua` and `require("lily_single")`.

How it Works
------------

Lily tries to load the asset, which can be time consuming, into another thread, called "TaskPool". When Lily is loaded, it creates
n-amount of "TaskPool", where `n` depends on how many CPU core you have. This allows the main thread to keep rendering while the other
thread do the asset loading. If you have more CPU cores, this is even better because the asset loading will be scattered across "TaskPool"
(by selecting "TaskPool" which has least amount of pending tasks). CPU core detection requires `love.system` module. Although it's possible
to use Lily without `love.system` by using other methods to find amount of CPU core, such strategy can fail under some system configuration
and fallback to 1 "TaskPool".

Why there's no `lily.update()` (like `loader.update()` in love-loader)? Lily takes advantage that `love.event.push` is thread-safe and
in fact LOVE allows custom event which can be added via `love.handlers` table. So, instead of using `Channel` to pass the loaded asset
to Lily main thread, Lily register it's own event and then the other thread will send LOVE event using `love.thread.push`. LOVE will
read that this event comes from Lily "TaskPool" thread, then execute Lily event handler, which returns the loaded asset ready to use.

Documentation
-------------

Most Lily function to create threaded asset follows LOVE name, like `newSource` for loading playable audio, `newImage` for loading
drawable image, and such. Additionally, Lily expose these additional function.

To call the async version of LOVE function, see function below. The function argument and the return value follows LOVE argument name unless noted. Lily
only expose function if the corresponding LOVE module is loaded, so load Lily after you `require` your necessary LOVE modules.

Available functions:

* newSource (`love.audio.newSource`)

* append (`love.filesystem.append`)

* newFileData (`love.filesystem.newFileData`)

* read (`love.filesystem.read`)

* readFile(`File`, ...) (`File:read(...)`)

* write (`love.filesystem.write`)

* writeFile(`File`, ...) (`File:write(...)`)

* newFont (`love.graphics.newFont`)

* newImage (`love.graphics.newImage`)

* newCubeImage (`love.graphics.newCubeImage`) \*

* newArrayImage (`love.graphics.newCubeImage`) \*

* newVolumeImage (`love.graphics.newCubeImage`) \*

* newVideo (`love.graphics.newVideo`)

* encodeImageData(`ImageData`, ...) (`ImageData:encode(...)`)

* newImageData (`love.image.newImageData`)

* newCompressedData (`love.image.newCompressedData`)

* pasteImageData(`ImageData`, ...) (`ImageData:paste(...)`)

* compress(`format`, `data`, `level`; returns string) (`love.data.compress("data", data, format, level)`)

* decompress(`format`, `data`; returns string) (`love.data.decompress("data", data, format)`)

* newSoundData (`love.sound.newSoundData`)

* newVideoStream (`love.video.newVideoStream`)

\* - Only on supported systems. Nested tables for mipmaps is not supported at the moment.

*************************************************

### `number lily.getThreadCount()`

Returns: Amount of threads used by Lily. This is mostly likely amount of logical CPU available.

> When `love.system` is not loaded, it uses other ways to get the amount of logical CPU. If all else fails, fallback to 1

*************************************************

### `void lily.quit()`

Uninitializes Lily. Uninitialize all threads. Call this just before your game quit (in `love.quit()`). Not calling
this function in iOS and Android can cause strange crash when re-starting your game!

It's good idea to call this function regardless of the platform.

*************************************************

### `bool lily.setUpdateMode(string mode)`

Set update mode, whetever to tell Lily to pull data by using LOVE event handler or
by using `lily.update` function.

Parameters:

* `mode` - Either `"automatic"` (use LOVE event handler) or `"manual"` (calling [`lily.update`](#void-lilyupdate) in `love.update`).

Returns: `true` if success, `false` otherwise.

> By default, Lily uses `"automatic"` method (using LOVE event handler).

*************************************************

### `void lily.update()`

Pull processed data from other threads. Signals other loader object when necessary.

Returns: none

> This function only takes effect when using `"manual"` update mode (see [`lily.setUpdateMode`](#bool-lilysetupdatemodestring-mode))

*************************************************

### `MultiLilyObject lily.loadMulti(table list)`

Loads multiple object simultaneously.

It expects `list` as table with these information

```lua
{
	{lily_function_name or lily_function, arg1, arg2, ...},
	...
}
```

The index will be used as `lilyindex` in below documentation to refer at nth-`LilyObject`.

Returns: `MultiLilyObject`

*************************************************

### `(Multi)LilyObject (Multi)LilyObject:onComplete(function complete_callback)`

Sets new function as callback when the asset is loaded. Default to noop. Function signature is:

* `void complete_callback(any userdata, any value1, any value2, ...)` (`value` is the result of such function) (for `LilyObject`)

* `void complete_callback(any userdata, table lily_return_values)` (`lily_return_values[lilyindex]` is return value of correctponding nth-`LilyObject` in table)

Returns: itself

*************************************************

### `(Multi)LilyObject (Multi)LilyObject:onError(function error_callback)`

Sets new function as callback when there's error when loading asset. Default to Lua built-in `error` function.
Function signature is:

* `void error_callback(any userdata, string error_message, string traceback)` (for `LilyObject`)

* `void error_callback(any userdata, number lilyindex, string error_message, string traceback)` (for `MultiLilyObject`)

Returns: itself

> `traceback` parameter is added in v3.0.9

*************************************************

### `(Multi)LilyObject (Multi)LilyObject:setUserData(any userdata)`

Sets the userdata. It can be any user-supplied data.

Returns: itself

*************************************************

### `MultiLilyObject MultiLilyObject:onLoaded(function loaded_callback)`

Sets new function as callback when `LilyObject` asset is loaded. Function signature is
`void loaded_callback(any userdata, number lilyindex, any value1, any value2, ...)`

`valuen` depends on nth-`LilyObject` (correstpond to `lilyindex`).

Returns: itself

*************************************************

### `bool (Multi)LilyObject:isComplete()`

Returns: `true` if specificed object fully loaded, `false` otherwise.

*************************************************

### `value1, value2, ... LilyObject:getValues()`

### `value1, value2, ... MultiLilyObject:getValues(number lilyindex)`

Get the result value of corresponding Lily request. Throws error if request is still incomplete.

Returns: Value depends on Lily request

*************************************************

### `table MultiLilyObject:getValues()`

Gets all result value from all `LilyObject`.

Returns: table, where at index `n` is correstpond to nth-`LilyObject`.

*************************************************

### `number MultiLilyObject:getCount()`

Retrieve amount of Lily objects to be loaded. This includes completed one.

Returns: Amount of Lily object needs to be loaded.

*************************************************

### `number MultiLilyObject:getLoadedCount()`

Gets amount of loaded objects.

Returns: Amount of objects loaded. If this is same as `MultiLilyObject:getLoadedCount()` then it's fully loaded.
