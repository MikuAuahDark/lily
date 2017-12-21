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
	lily.newImage("image.png"):onComplete(function(image)
		myimage = image
	end)
	lily.newSource("song.wav"):onComplete(function(sound)
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

How it Works
------------

Lily tries to load the asset, which can be time consuming, into another thread, called "TaskPool". When Lily is loaded, it creates
n-amount of "TaskPool", where `n` depends on how many CPU core you have. This allows the main thread to keep rendering while the other
thread do the asset loading. If you have more CPU cores, this is even better because the asset loading will be scattered across "TaskPool"
(by selecting "TaskPool" which has least amount of pending tasks). CPU core detection requires `love.system` module. Although it's possible
to use Lily without `love.system` by using other methods to find amount of CPU core, such strategy can fail under some system configuration
and fallback to 1 "TaskPool".

Why there's no `lily.update()` like in love-loader `loader.update()`? Lily takes advantage that `love.event.push` is thread-safe and
in fact LOVE allows custom event which can be added via `love.handlers` table. So, instead of using `Channel` to pass the loaded asset
to Lily main thread, Lily register it's own event and then the other thread will send LOVE event using `love.thread.push`, then LOVE
will read that this event comes from Lily "TaskPool" thread, then execute Lily event handler, which in turns returns the loaded asset.

Documentation
-------------

Most Lily function to create threaded asset follows LOVE name, like `newSource` for loading playable audio, `newImage` for loading
drawable image, and such. Additionally, Lily expose these additional function.

For LOVE name functions (`newImage`, `newFont`, `newImageData`, `newSource`, ...), Lily always returns object called `LilyObject`.

*************************************************

### `number lily.getThreadCount()`

Returns: Amount of threads used by Lily. This is mostly likely amount of logical CPU available.

> When `love.system` is not loaded, it uses other ways to get the amount of logical CPU. If all else fails, fallback to 1

*************************************************

### `table lily.getThreadsTaskCount()`

Retrieves the total pending task for every thread.

Returns: Table with n-elements depending on `lily.getThreadCount()`.

*************************************************

### `void lily.quit()`

Uninitializes Lily.

> This function should only be called if you plan restarting your game with `love.event.quit("restart")`. This is true when using LOVE under iOS!

*************************************************

### `LilyObject LilyObject:onComplete(function complete_callback)`

Sets new function as callback when the asset is loaded. Default to noop.

Returns: itself

*************************************************

### `LilyObject LilyObject:onError(function complete_callback)`

Sets new function as callback when there's error when loading asset. Default to Lua built-in `error` function.

Returns: itself
