local repeatUtil = require("repeat-util")

local args = {...}

if args[1] ~= "go" then
	print("Save before running and not after, as this script will delete all buildings with z = 0 so that stonesense can run. When ready, run `safestonesense go`")
	return
end

print("Deleting all buildings with z = 0, disabling saving on exit, forcing pause, and launching stonesense. Run die when finished looking, DO NOT save")

local function deleteBuilding(building)
	local function searchVector(vec)
		for i, v in ipairs(vec) do
			if v == building then
				vec:erase(i)
				break
			end
		end
	end

	for _, vec in pairs(df.global.world.buildings.other) do
		searchVector(vec)
	end
	searchVector(df.global.world.buildings.all)
end

local buildingsToDelete = {}
for _, building in ipairs(df.global.world.buildings.all) do
	if building.z == 0 then
		buildingsToDelete[#buildingsToDelete + 1] = building
	end
end

for _, building in ipairs(buildingsToDelete) do
	deleteBuilding(building)
end


df.global.save_on_exit = false

repeatUtil.scheduleEvery("safestonesense", 1, "ticks", function()
	df.global.pause_state = true
end)

dfhack.run_command("stonesense")
