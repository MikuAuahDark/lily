# Makefile script to create lily_single.lua
# Useful if you want to add your own modification to Lily

all: lily_single.lua
lily_single.lua: lily.lua lily_thread.lua
	cp lily.lua lily_single.lua
	sed -i '/return lily/i lily_thread_script = [===[' lily_single.lua
	sed -i '/return lily/i ]===]' lily_single.lua
	sed -i '/lily_thread_script = \[===\[/r lily_thread.lua' lily_single.lua
	