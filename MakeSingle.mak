# Makefile script to create lily_single.lua
# Useful if you want to add your own modification to Lily

all: lily_single.lua
lily_single.lua: lily.lua lily_thread.lua
	cp lily.lua lily_single.lua
	sed -i '/-- do not remove this comment!/i lilyThreadScript = [===[' lily_single.lua
	sed -i '/-- do not remove this comment!/i ]===]' lily_single.lua
	sed -i '/lilyThreadScript = \[===\[/r lily_thread.lua' lily_single.lua
	