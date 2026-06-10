-- bathe
-- Gets your citizens to take a bath more often, not just when there's spatter.
-- It makes them happy and also... really goes through your soap reserves!
-- By Tachytaenius
-- For DF version 0.47.05

local utils = require("utils")
local repeatUtil = require("repeat-util")

local consts = {
	scriptKey = "bathe",
	repeatInterval = 1000,
	chancePerRepeat = 0.25 -- Per eligible unit
}

-- TODO: Don't pick dry/inactive wells (how does the game check?)

-- Backported from later versions of DFHack
local function removeJobPostings(job)
	qerror("TODO") -- I don't think we'll need this to be filled in.
	-- If this really is needed, other scripts such as Ur-ist's control script have it.
end
local function isUnitInSquadOrder(unit)
	-- Part of a squad?
	local squad = df.squad.find(unit.military.squad_id)
	if not squad then
		return false
	end
	-- Any all-squad orders?
	if #squad.orders > 0 then
		return true
	end
	-- Any position-specific orders?
	local positionIndex = unit.military.squad_position
	if #squad.positions <= positionIndex then
		-- ???
		return false
	end
	local position = squad.positions[positionIndex]
	if #position.orders > 0 then
		return true
	end
	-- No orders found
	return false
end
local function canBeAddedToJob(unit)
	if unit.job.current_job then
		return false
	end
	return true
end
local function addJobWorker(job, unit)
	assert(job, "No job specified")
	assert(unit, "No unit specified")

	if not canBeAddedToJob(unit) then
		return false
	end

	if job.posting_index ~= -1 then
		-- NOTE: This is never entered (right?)
		qerror("Not implemented")
		removeJobPostings(job)
	end

	job.general_refs:insert("#", {new = df.general_ref_unit_workerst, unit_id = unit.id})
	job.recheck_cntdn = 0

	unit.job.current_job = job

	return true
end

local bitToDirection = {
	[0] = "north",
	"south",
	"east",
	"west",
	"northeast",
	"northwest",
	"southeast",
	"southwest"
}
local directionToBit = utils.invert(bitToDirection)
local xOffsets = {
	east = 1,
	northeast = 1,
	southeast = 1,
	west = -1,
	northwest = -1,
	southwest = -1
}
local yOffsets = {
	north = -1,
	northeast = -1,
	northwest = -1,
	south = 1,
	southeast = 1,
	southwest = 1
}

local function bathe(unit, building, direction)
	local job = df.job:new()
	local x, y, z = building.centerx + (xOffsets[direction] or 0), building.centery + (yOffsets[direction] or 0), building.z
	job.pos.x, job.pos.y, job.pos.z = x, y, z
	job.job_type = df.job_type.CleanSelf
	job.flags.special = true
	local directionBit = directionToBit[direction]
	local directionFlags = 2 ^ directionBit
	job.general_refs:insert("#", {new = df.general_ref_building_well_tag, building_id = building.id, direction = directionFlags})
	addJobWorker(job, unit)
	-- unit.path.goal = df.unit_path_goal.StartWaterJobWell
	-- unit.path.dest.x, unit.path.dest.y, unit.path.dest.z = x, y, z
	-- unit.path.path.x:resize(0)
	-- unit.path.path.y:resize(0)
	-- unit.path.path.z:resize(0)
	dfhack.job.linkIntoWorld(job, true)
end

local function checkShouldRun()
	if not autoBatheThreshold then
		print("No auto bathe grime threshold set. Use `-setAutoBatheThreshold` (max grime is 7)")
		return false
	end
	return true
end

local function getMaxGrime(unit)
	local max = -math.huge
	for _, status in ipairs(unit.body.components.body_part_status) do
		if not status.missing then
			max = math.max(max, status.grime)
		end
	end
	return max
end

local function selectWell(unit)
	local pos = xyz2pos(dfhack.units.getPosition(unit))
	local choices = {}
	for _, building in ipairs(df.global.world.buildings.other.WELL) do
		if not building.flags.exists then
			goto continue
		end
		local forbidden
		for _, itemRef in ipairs(building.contained_items) do
			if
				itemRef.use_mode == 2 and
				itemRef.item.flags.forbid
			then
				forbidden = true
				break
			end
		end
		if forbidden then
			goto continue
		end

		for i = 0, #bitToDirection do
			local direction = bitToDirection[i]
			local x, y, z =
				building.centerx + (xOffsets[direction] or 0),
				building.centery + (yOffsets[direction] or 0),
				building.z
			if dfhack.maps.canWalkBetween(pos, xyz2pos(x, y, z)) then
				choices[#choices+1] = {
					building = building,
					direction = direction,
					x = x,
					y = y,
					z = z
				}
			end
		end
	    ::continue::
	end
	table.sort(choices, function(a, b)
		if a.z ~= b.z then
			if a.z == pos.z then
				return true
			elseif b.z == pos.z then
				return false
			end
		end
		return -- x and y refer to the positions to the side of the well, not the position of the well itself
			math.sqrt((a.x - pos.x) ^ 2 + (a.y - pos.y) ^ 2) <
			math.sqrt((b.x - pos.x) ^ 2 + (b.y - pos.y) ^ 2)
	end)
	local choice = choices[1]
	if not choice then
		return
	end
	return choice.building, choice.direction
end

local function hasCleanSelfCooldown(unit)
	for _, trait in ipairs(unit.status.misc_traits) do
		if
			trait.id == df.misc_trait_type.CleanSelfCooldown and
			trait.value > 0 -- Presumably. I see some misc traits at 0, so I imagine that these timers work like action timers but just don't get removed.
		then
			return true
		end
	end
	return false
end

local function repeatFunction()
	if not checkShouldRun() then
		disable()
		return
	end
	for _, unit in ipairs(df.global.world.units.active) do
		if not dfhack.units.isCitizen(unit) then
			goto continue
		end

		if dfhack.units.isBaby(unit) then
			-- Otherwise you get "cancels clean self: too insane"
			goto continue
		end
		if not canBeAddedToJob(unit) then
			goto continue
		end
		if isUnitInSquadOrder(unit) then
			goto continue
		end
		if hasCleanSelfCooldown(unit) then
			goto continue
		end

		if rng:drandom() >= consts.chancePerRepeat then
			goto continue
		end
		if getMaxGrime(unit) < autoBatheThreshold then
			goto continue
		end

		local well, direction = selectWell(unit)
		if not well then
			goto continue
		end
		bathe(unit, well, direction)

	    ::continue::
	end
end

local function enable()
	if not checkShouldRun() then
		disable()
		return
	end
	if not rng then
		rng = dfhack.random.new()
		rng:init()
	end
	repeatUtil.scheduleEvery(consts.scriptKey, consts.repeatInterval, "ticks", repeatFunction)
	print("Auto-bathing enabled")
end

local function disable()
	repeatUtil.cancel(consts.scriptKey)
	print("Auto-bathing disabled")
end

local validArgs = utils.invert({
	"unitId",
	"buildingId",
	"direction",

	"getAutoBatheThreshold",
	"setAutoBatheThreshold",
	"startAutoBathing",
	"stopAutoBathing"
})

autoBatheThreshold = autoBatheThreshold or 6

local args = utils.processArgs({...}, validArgs)

if args.getAutoBatheThreshold then
	print(autoBatheThreshold or "Auto-bathe threshold not set")
end

if tonumber(args.setAutoBatheThreshold) then
	local new = tonumber(args.setAutoBatheThreshold)
	assert(0 <= new and new <= 7, "Auto bathe threshold must be a number between 0 and 7")
	autoBatheThreshold = new
end

if args.stopAutoBathing then
	disable()
	return
end

if args.startAutoBathing then
	enable()
	return
end

local unit = df.unit.find(args.unitId)
if not unit then
	qerror("Could not find unit with id " .. args.unitId)
end
if not canBeAddedToJob(unit) then
	qerror("Can't add unit to job")
end

local building = df.building.find(args.buildingId)
if not building then
	qerror("Could not find building with id " .. args.buildingId)
end
-- Won't check if it is actually a well (yet)

bathe(unit, building, args.direction)
