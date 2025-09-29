-- TODO: Auto-cleaning zones

local eventful = require("plugins.eventful")
local utils = require("utils")

local consts = {
	scriptKey = "cleaning",
	cleanMudJobFlagKey = 31,
	removeEngravingJobFlagKeyStart = 27,
	removeEngravingJobFlagKeyEnd = 30, -- Included
	removeEngravingTypeEnum = {
		[0] = nil,
		"floor",
		"north",
		"south",
		"east",
		"west",
		"northeast",
		"northwest",
		"southeast",
		"southwest"
	},
	directionOpposites = {
		north = "south",
		south = "north",
		east = "west",
		west = "east",
		southwest = "northeast",
		southeast = "northwest",
		northwest = "southeast",
		northeast = "southwest"
	},
	directionXOffsets = {
		east = 1,
		northeast = 1,
		southeast = 1,
		west = -1,
		northwest = -1,
		southwest = -1
	},
	directionYOffsets = {
		north = -1,
		northeast = -1,
		northwest = -1,
		south = 1,
		southeast = 1,
		southwest = 1
	}
}
-- Derived
consts.removeEngravingTypeToEnumNumber = utils.invert(consts.removeEngravingTypeEnum)

local validArgs = utils.invert({
	"unit",
	"position",

	"cleanMud",
	"removeEngraving",

	-- Only important for users who are setting special clean jobs:
	"startWatching",
	"stopWatching", -- Not really meant to be used unless something's gone wrong
	"status"
})

local args = utils.processArgs({...}, validArgs)

if args.status then
	print(enabled and "Watching enabled" or "Watching disabled")
	return
end

if args.stopWatching then
	eventful.onJobCompleted[consts.scriptKey] = nil
	enabled = false
	print("Stopped watching for clean jobs with the clean mud flag")
	return
end

local function cleanTileMud(x, y, z)
	local block = dfhack.maps.getTileBlock(x, y, z)
	for _, event in ipairs(block.block_events) do
		if event._type ~= df.block_square_event_material_spatterst then
			goto continue
		end
		if not (event.mat_type == df.builtin_mats.MUD and event.mat_index == -1) then
			goto continue
		end
		local lx, ly = x % 16, y % 16
		event.amount[lx][ly] = 0
	    ::continue::
	end
end

local function removeEngraving(x, y, z, directionToErase)
	-- NOTE: Could make it so that we remove the relevant engraving direction flag and only remove
	-- the engraving if all engraving flags are gone, because maybe multi-direction engravings work
	-- and should be accounted for.

	for i, engraving in ipairs(df.global.world.engravings) do
		if not engraving.flags[directionToErase] then
			goto continue
		end

		local pos = engraving.pos
		if
			pos.x == x and
			pos.y == y and
			pos.z == z
		then
			df.global.world.engravings:erase(i)
			break
		end

	    ::continue::
	end
end

if args.startWatching then
	eventful.onJobCompleted[consts.scriptKey] = function(job)
		if job.job_type ~= df.job_type.Clean then
			return
		end

		if job.flags[consts.cleanMudJobFlagKey] then
			for x = job.pos.x - 1, job.pos.x + 1 do
				for y = job.pos.y - 1, job.pos.y + 1 do
					cleanTileMud(x, y, job.pos.z)
				end
			end
		end

		local removeEngravingEnumNumber = 0
		for i = consts.removeEngravingJobFlagKeyStart, consts.removeEngravingJobFlagKeyEnd do
			local bitNumber = i - consts.removeEngravingJobFlagKeyStart
			if job.flags[i] then
				removeEngravingEnumNumber = removeEngravingEnumNumber + 2 ^ bitNumber
			end
		end
		local removeEngravingType = consts.removeEngravingTypeEnum[removeEngravingEnumNumber]
		if removeEngravingType then
			removeEngraving(
				job.pos.x + (consts.directionXOffsets[removeEngravingType] or 0),
				job.pos.y + (consts.directionYOffsets[removeEngravingType] or 0),
				job.pos.z,
				consts.directionOpposites[removeEngravingType] or removeEngravingType
			)
		end
	end
	eventful.enableEvent(eventful.eventType.JOB_COMPLETED, 0)
	enabled = true
	print("Started watching for clean jobs with special flags")
	return
end

if not args.unit then
	qerror("No unit specified")
end
local unit =
	args.unit == "selected" and dfhack.gui.getSelectedUnit(true) or
	tonumber(args.unit) and df.unit.find(tonumber(args.unit))
if not unit then
	qerror("No unit found")
end

local x, y, z
if type(args.position) == "table" then
	x = tonumber(args.position[1])
	y = tonumber(args.position[2])
	z = tonumber(args.position[3])
elseif args.position == "cursor" then
	x, y, z = pos2xyz(df.global.cursor)
	if not (x and y and z) then
		qerror("No cursor!")
	end
else
	qerror("No position specified")
end

local function removePostings(job)
	qerror("TODO") -- Do we need this?
end

local function canAddToJob(unit)
	if unit.job.current_job then
		return false
	end
	return true
end

local function addWorker(job, unit) -- Backported from later versions of DFHack
	assert(job, "No job specified")
	assert(unit, "No unit specified")

	assert(canAddToJob(unit), "Can't add unit to job!")

	if job.posting_index ~= -1 then
		-- NOTE: This is never entered
		qerror("Not implemented")
		-- removePostings(job)
	end

	job.general_refs:insert("#", {new = df.general_ref_unit_workerst, unit_id = unit.id})
	job.recheck_cntdn = 0

	unit.job.current_job = job

	return true
end

if not canAddToJob(unit) then
	qerror("Can't add unit to job")
end

if not enabled and args.cleanMud then
	qerror("Must enable the script's job watching functionality to use it to clean mud")
end

local job = df.job:new()

job.job_type = df.job_type.Clean

job.pos.x = x
job.pos.y = y
job.pos.z = z

job.flags.special = true
if args.cleanMud then
	job.completion_timer = 0 -- So that the onJobCompleted fires
	job.flags[consts.cleanMudJobFlagKey] = true
end
if args.removeEngraving then
	local number = consts.removeEngravingTypeToEnumNumber[args.removeEngraving]
	if not number then
		qerror("Unrecognised engraving removal direction " .. args.removeEngraving)
	end
	for i = consts.removeEngravingJobFlagKeyStart, consts.removeEngravingJobFlagKeyEnd do
		local bitNumber = i - consts.removeEngravingJobFlagKeyStart
		local mask = 2 ^ bitNumber
		local andResult = bit32.band(number, mask)
		if andResult ~= 0 then
			job.flags[i] = true
		end
	end
end

unit.path.dest.x = x
unit.path.dest.y = y
unit.path.dest.z = z
unit.path.goal = df.unit_path_goal.Clean
local path = unit.path.path
path.x:resize(0)
path.y:resize(0)
path.z:resize(0)
addWorker(job, unit)

dfhack.job.linkIntoWorld(job, true)

return job -- In case run_script'd
