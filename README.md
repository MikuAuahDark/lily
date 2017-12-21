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

Documentation
-------------

Most Lily function to create threaded asset follows LOVE name, like `newSource` for loading playable audio, `newImage` for loading
drawable image, and such. Additionally, Lily expose these additional function

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
