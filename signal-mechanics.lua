--@enable=true

-- Only levers can be used as retransmitters/inverters, but pressure plates can still be used to trigger levers.
-- Levers triggered by other triggers will flip on the same tick as their triggers do, but then trigger everything they are connected to on the next tick.
-- Make sure to have enable signal-mechanics on map load, otherwise some state changes may not be detected. Forcing the script's tick function to run multiple times in a single tick (enabling causes an extra run of that function due to how repeat-util works) won't have any effect, so saving and loading makes no difference to what pulls are detected.
-- If lever A pulls and goes left, and is connected to already-left-facing lever B, B will trigger other things as though it had gone from right to left, rather than do nothing because it was already set left.

-- Notes:
-- Trigger state 0 is represented as false, all other states are represented as true
-- Only fort mode is enabled
-- You can make an extremely fast clock by hooking up two levers to each other and setting one to invert signal. Certain triggerable buildings (ones that open and close) will quickly burn out if retriggered too often, because they can cause immense lag (or too much damage) if allowed to run at full speed. You can still trigger a burnt out building with a direct vanilla triggering.

-- TODO: Check that buildings exist before doing things to them (cooling burn out, triggering, etc). Don't allow them triggering while deconstructing
-- TODO: Proper args

local persistTable = require("persist-table")
local repeatUtil = require("repeat-util")
local utils = require("utils")

local GLOBAL_KEY = "signal-mechanics"

local plateInfoFlagsUses = {
	activatedByScript = 29,
	invertOutSignal = 30,
	lastKnownState = 31
}

local burnoutSmokeAmount = 0 -- Set to 0 to disable
local buildingBurnoutThreshold = 128
local buildingBurnoutMax = 248 -- Can't be higher than 2 ^ (cooldownBitsEnd - cooldownBitsStart + 1) - 1
local buildingBurnoutPerTrigger = 12
local buildingBurnoutReductionPerTick = 1
local buildingFlagUses = {
	cooldownBitsStart = 24,
	cooldownBitsEnd = 31
}
local burnoutBuildingTypes = utils.invert({ -- Note that the levers themselves don't burn out, only the triggerable target buildings like doors. The only lever-triggerable weapon traps are upright weapon traps, and those are set to burn out. The others are of type df.building_trapst and don't trigger
	df.building_doorst,
	df.building_floodgatest,
	df.building_hatchst,
	df.building_grate_wallst,
	df.building_grate_floorst,
	df.building_bars_verticalst,
	df.building_bars_floorst,
	df.building_bridgest,
	df.building_gear_assemblyst,
	df.building_weaponst
})
local burnoutBuildingVectors = {
	"DOOR",
	"FLOODGATE",
	"HATCH",
	"GRATE_WALL",
	"GRATE_FLOOR",
	"BARS_VERTICAL",
	"BARS_FLOOR",
	"BRIDGE",
	"GEAR_ASSEMBLY",
	"WEAPON_UPRIGHT"
}

-- There is also targetBuildingRef as state
if enabled == nil then
	enabled = false
end

function isEnabled()
	return enabled
end

local function validGamestate()
	-- Because we don't want wandering about in adventure mode to mess things up, we'll limit this to fort mode (for now?)
	-- Engineering a system where building unloading, loading, destruction, and creation are all handled appropriately and persistently such that no building state changes are missed will be an interesting challenge
	return dfhack.isMapLoaded() and df.global.gamemode == df.game_mode.DWARF
	-- return dfhack.isMapLoaded()
end

local function printStatus()
	print(("signal-mechanics is currently %s."):format(enabled and "enabled" or "disabled"))
end

local function disable()
	if not enabled then
		print("signal-mechanics already disabled")
		return
	end
	targetBuildingRef = nil
	enabled = false
	repeatUtil.cancel(GLOBAL_KEY)
	dfhack.onStateChange[GLOBAL_KEY] = nil
	print("signal-mechanics disabled")
end

local function isLever(building)
	return building._type == df.building_trapst and building.trap_type == df.trap_type.Lever
end

local function getBuildingBurnout(flags)
	local total = 0
	for i = buildingFlagUses.cooldownBitsStart, buildingFlagUses.cooldownBitsEnd do
		if flags[i] then
			total = total + 2 ^ (i - buildingFlagUses.cooldownBitsStart)
		end
	end
	return total
end

local function setBuildingBurnout(flags, number)
	for i = buildingFlagUses.cooldownBitsStart, buildingFlagUses.cooldownBitsEnd do
		local mask = 2 ^ (i - buildingFlagUses.cooldownBitsStart)
		flags[i] = bit32.band(number, mask) ~= 0
	end
end

local function triggerBuilding(building, sendState)
	if burnoutBuildingTypes[building._type] then
		local currentBurnout = getBuildingBurnout(building.flags)
		local newBurnout = math.min(buildingBurnoutMax, currentBurnout + buildingBurnoutPerTrigger)
		if currentBurnout ~= newBurnout then
			setBuildingBurnout(building.flags, newBurnout)
		end
		if newBurnout >= buildingBurnoutThreshold then
			if burnoutSmokeAmount > 0 then
				local position = xyz2pos( -- Would be better done anywhere within the building's actual tiles
					building.centerx,
					building.centery,
					building.z
				)
				dfhack.maps.spawnFlow(position, df.flow_type.Smoke, -1, -1, burnoutSmokeAmount)
			end
			return -- Burnout, do not trigger
		end
	end

	-- setTriggerState does nothing for untriggerable buildings
	building:setTriggerState(sendState and 0 or 1) -- Note that this is inverted compared to lever states
end

local function coolBurnoutBuildings()
	for _, vecName in ipairs(burnoutBuildingVectors) do
		for _, building in ipairs(df.global.world.buildings.other[vecName]) do
			local currentBurnout = getBuildingBurnout(building.flags)
			local newBurnout = math.max(0, currentBurnout - buildingBurnoutReductionPerTick)
			if currentBurnout ~= newBurnout then
				setBuildingBurnout(building.flags, newBurnout)
			end
		end
	end
end

local function tick()
	if not validGamestate() then -- Won't check for not enabled because enable() schedules this function (which calls it) before setting enabled to true, in case of errors
		-- Shouldn't happen
		disable()
		return
	end

	if
		-- cur_year_tick_advmode does tick up in fort mode but I am not sure that this would be airtight going between advmode and fort mode if the 2 weeks are skipped (which is possible with some hacking)
		tonumber(persistTable.GlobalTable.signalMechanicsLastRunYear) == df.global.cur_year and
		tonumber(persistTable.GlobalTable.signalMechanicsLastRunYearTick) == df.global.cur_year_tick and
		tonumber(persistTable.GlobalTable.signalMechanicsLastRunYearTickAdv) == df.global.cur_year_tick_advmode
	then
		-- print("signal-mechanics avoided running on the same tick twice; this is normal on reloading a world that uses it")
		return
	end

	local buildingsToWatch = df.global.world.buildings.other.TRAP

	local newTriggerStates = {}

	for _, building in ipairs(buildingsToWatch) do
		-- Lever or pressure plate for initial signal, but levers for retransmitted signals
		if not (building._type == df.building_trapst and (building.trap_type == df.trap_type.Lever or building.trap_type == df.trap_type.PressurePlate)) then
			goto continue -- Acceptable use of goto in Lua
		end

		-- Check for change in state
		local flags = building.plate_info.flags
		local currentState = building.state ~= 0
		if flags[plateInfoFlagsUses.lastKnownState] ~= currentState then
			-- State change detected!
			local sendState = building.state ~= 0
			if flags[plateInfoFlagsUses.invertOutSignal] then
				sendState = not sendState
			end
			-- Set any triggers that this is linked to to the state of this trigger
			-- If multiple triggers set a trigger on one frame, the state of the trigger with the highest building id (the one built last) will go through
			local activatedByScript = flags[plateInfoFlagsUses.activatedByScript] -- Don't trigger doors etc unless the script flipped the state, in which case the game won't have set the state of linked doors etc
			for _, item in ipairs(building.linked_mechanisms) do
				for _, ref in ipairs(item.general_refs) do
					if ref._type == df.general_ref_building_holderst then
						local building2 = ref:getBuilding()
						if building2 then
							if isLever(building2) then
								newTriggerStates[building2.id] = sendState
							elseif activatedByScript then
								triggerBuilding(building2, sendState)
							end
						end
						break -- No more iteration over item general refs, we found a building holder one. Go to the next linked mechanism
					end
				end
			end
		end

		-- Clear any state not meant to remain
		flags[plateInfoFlagsUses.activatedByScript] = false

		-- Save previous state
		flags[plateInfoFlagsUses.lastKnownState] = building.state ~= 0

		::continue::
	end

	-- Set last known state and set new state
	for _, building in ipairs(buildingsToWatch) do
		if isLever(building) and newTriggerStates[building.id] ~= nil then
			building.state = newTriggerStates[building.id] and 1 or 0
			building.plate_info.flags[plateInfoFlagsUses.activatedByScript] = true -- Temporary
		end
	end

	-- Cool down building burn-out
	coolBurnoutBuildings()

	persistTable.GlobalTable.signalMechanicsLastRunYear = tostring(df.global.cur_year)
	persistTable.GlobalTable.signalMechanicsLastRunYearTick = tostring(df.global.cur_year_tick)
	persistTable.GlobalTable.signalMechanicsLastRunYearTickAdv = tostring(df.global.cur_year_tick_advmode)
end

local function enable()
	if not validGamestate() then
		print("Can't enable in this state")
		if enabled then
			-- Shouldn't happen
			disable()
		end
		return
	end
	if enabled then
		print("signal-mechanics already enabled, reenabling")
	end
	repeatUtil.scheduleEvery(GLOBAL_KEY, 1, "ticks", tick)
	dfhack.onStateChange[GLOBAL_KEY] = function(stateChange)
		if not validGamestate() then
			disable()
		end
	end
	enabled = true
	print("signal-mechanics enabled")
end

-- Either returns a building to use or errors
local function getBuildingForInversionSetGet()
	local building = dfhack.gui.getSelectedBuilding()
	if not building then
		qerror("Could not find building")
	end
	if not isLever(building) then
		qerror("Building is not a lever")
	end
	return building
end

local function trySetBuildingInverter(inversion)
	local building = getBuildingForInversionSetGet() -- Errors if not successful
	building.plate_info.flags[plateInfoFlagsUses.invertOutSignal] = inversion
	print("Lever \"" .. utils.getBuildingName(building) .. "\" with id " .. building.id .. " set as a " .. (inversion and "signal inverter" or "signal retransmitter"))
end

local args = {...}
if #args > 1 then
	print(dfhack.script_help())
	return
end
if args[1] == "status" then
	printStatus()
	return
elseif args[1] == "target" then
	local targetBuilding = dfhack.gui.getSelectedBuilding()
	if not targetBuilding then
		qerror("No building selected to link to")
	end
	targetBuildingRef = df.general_ref_building:new()
	targetBuildingRef.building_id = targetBuilding.id
	print("Building \"" .. utils.getBuildingName(targetBuilding) .. "\" with id " .. targetBuilding.id .. " selected as linkage target for jobs")
	return
elseif args[1] == "link" then
	-- Get building id to link to
	if not targetBuildingRef then
		qerror("No building has been selected for linking up to")
	end
	local targetBuildingId = targetBuildingRef.building_id
	local targetBuilding = targetBuildingRef:getBuilding()
	if not targetBuilding then -- Check that it still exists
		targetBuildingRef = nil
		qerror("Building selected for link target with id " .. targetBuildingId .. " does not exist, it has been deselected")
	end

	-- Get job to setup linkage for
	-- getSelectedJob fails for triggers
	local building = dfhack.gui.getSelectedBuilding()
	if not building then
		qerror("No building selected to modify a job for")
	end
	local index = df.global.ui_workshop_job_cursor
	if index >= #building.jobs then
		-- This shouldn't happen
		qerror("Invalid job cursor index " .. index .. " for building with id " .. building.id)
	end
	local job = building.jobs[index]

	-- Make sure the job is of the right type and that the mechanism headed for the target isn't already in a building
	if job.job_type ~= df.job_type.LinkBuildingToTrigger then
		qerror("Wrong type of job, must be a link building to trigger job")
	end
	local foundMechanism = false
	for _, jobItemRef in ipairs(job.items) do
		if jobItemRef.role == df.job_item_ref.T_role.LinkToTrigger then
			-- This is the target item
			foundMechanism = true
			if jobItemRef.item.flags.in_building then
				-- Before this point you can actually retarget and it works, though you get a pathing fail message in the errorlog
				-- TODO: Just double-check^
				qerror("A target building has already had its item added")
			end
			break
		end
	end
	if not foundMechanism then
		-- This shouldn't happen
		qerror("Could not find item that will attach to the target building")
	end

	-- Find general ref that sets the job's trigger target and change it
	for _, generalRef in ipairs(job.general_refs) do
		if generalRef._type == df.general_ref_building_triggertargetst then
			generalRef.building_id = targetBuildingId
			print("Building \"" .. utils.getBuildingName(targetBuilding) .. "\" with id " .. targetBuilding.id .. " set as target for selected linkage job (index " .. index .. ")")
			return
		end
	end
	-- This shouldn't happen
	qerror("Could not find general ref that determines target building")
elseif args[1] == "check-inversion" then
	local building = getBuildingForInversionSetGet() -- Errors if not successful
	local inversion = building.plate_info.flags[plateInfoFlagsUses.invertOutSignal]
	print("Lever \"" .. utils.getBuildingName(building) .. "\" with id " .. building.id .. " is a " .. (inversion and "signal inverter" or "signal retransmitter"))
	return
elseif args[1] == "set-as-inverter" then
	trySetBuildingInverter(true)
	return
elseif args[1] == "set-as-retransmitter" then
	trySetBuildingInverter(false)
	return
elseif args[1] ~= nil or not dfhack_flags.enable then
	print(dfhack.script_help())
	return
end

if dfhack_flags.enable_state then
	if not validGamestate() then
		qerror("Can't enable signal-mechanics without a map loaded")
	end
	enable()
else
	disable()
end

-- NOTE: In the wildly hypothetical scenario of a lever being created in the active state and then pulled to inacive all in one tick (like if another mod created an active lever and a unit about to finish pulling it at the same time) the pull will not be detected because the unused flag bit for lastKnownState will be false, which matches the inactive state. This is impossible in normal gameplay, and is left as a curiousity, rather than a warning for the airtightness of the mod. It could be fixed, perhaps, with eventful's onJobCompleted, depending on when that runs.
