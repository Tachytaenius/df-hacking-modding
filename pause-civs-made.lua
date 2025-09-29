local repeatUtil = require("repeat-util")

local function getWorldgenScreen()
	-- These don't work when putting up the in-game console
	-- dfhack.gui.getCurViewscreen()
	-- dfhack.gui.getViewscreenByType(df.viewscreen_new_regionst)
	local view = df.global.gview.view
	while view do
		if df.viewscreen_new_regionst:is_instance(view) then
			return view
		end
		view = view.child
	end
	return nil
end

local scriptKey = "pause-civs-made"

print("Scheduling pause-civs-made")
repeatUtil.scheduleEvery(scriptKey, 1, "frames", function()
	local worldgenScreen = getWorldgenScreen()
	if worldgenScreen then
		local status = df.global.world.worldgen_status
		if
			status.state == df.world.T_worldgen_status.T_state.Finalizing and
			status.place_civs and
			status.civs_left_to_place == 0
		then
			print("pause-civs-made: pausing")
			worldgenScreen.worldgen_paused = true
			repeatUtil.cancel(scriptKey)
		end
	end
end)
