--@ enable = true

-- proper-dining

local repeatUtil = require("repeat-util")
local utils = require("utils")

local consts = {
	scriptKey = "proper-dining",
	handledJobFlagKey = 31
}

local validArgs = utils.invert({
	"status"
})

local args = utils.processArgs({...}, validArgs)

local function hasFreeAdjacentTable(chair)
	local x, y, z = chair.centerx, chair.centery, chair.z
	for _, table in ipairs(df.global.world.buildings.other.TABLE) do
		if #table.users.unit > 0 then
			return false
		end
		if
			(
				math.abs(table.centerx - x) == 1 and table.centery == y or
				math.abs(table.centery - y) == 1 and table.centerx == x
			) and
			table.z == z
		then
			return true
		end
	end
end

local function searchForFreeDiningSpot(pos)
	local choices = {}
	for _, building in ipairs(df.global.world.buildings.other.TABLE) do
		if not building.is_room then
			goto continue
		end
		for _, subBuilding in ipairs(building.children) do
			if subBuilding._type ~= df.building_chairst then
				goto continue
			end
			if #subBuilding.users.unit > 0 then
				goto continue
			end
			if not hasFreeAdjacentTable(subBuilding) then
				goto continue
			end
			if not dfhack.maps.canWalkBetween(pos, xyz2pos(subBuilding.centerx, subBuilding.centery, subBuilding.z)) then
				goto continue
			end
			choices[#choices+1] = subBuilding
		    ::continue::
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
		return
			math.sqrt((a.centerx - pos.x) ^ 2 + (a.centery - pos.y) ^ 2) <
			math.sqrt((b.centerx - pos.x) ^ 2 + (b.centery - pos.y) ^ 2)
	end)
	return choices[1]
end

local function isDiningSpot(building)
	if building._type ~= df.building_chairst then
		return
	end
	for _, parent in ipairs(building.parents) do
		if parent._type ~= df.building_tablest then
			goto continue
		end
		if parent.is_room then -- Probably can't (or shouldn't) be false
			return true
		end
		::continue::
	end
end

local function handleJob(job)
	if job.job_type ~= df.job_type.Eat then
		return
	end
	if job.flags[consts.handledJobFlagKey] then
		-- This comes after, so that other scripts that use the same key but don't handle Eat jobs won't clash
		return
	end

	local unit = dfhack.job.getWorker(job)

	local ref = dfhack.job.getGeneralRef(job, df.general_ref_type.BUILDING_USE_TARGET_1)
	if not ref then
		return
	end

	local building = df.building.find(ref.building_id)
	if not building then
		return
	end

	local item = job.items and job.items[0] and job.items[0].item
	if not item then
		return
	end

	job.flags[consts.handledJobFlagKey] = true

	if dfhack.items.getHolderBuilding(item) then
		-- Already placed down
		return
	end

	if isDiningSpot(building) then
		return
	end

	local newSpot = searchForFreeDiningSpot(xyz2pos(dfhack.units.getPosition(unit)))
	if not newSpot then
		return
	end

	ref.building_id = newSpot.id

	newSpot.users.unit:insert("#", unit.id)
	newSpot.users.mode:insert("#", 0) -- df.building_use_type.SitForEat

	unit.path.dest.x = newSpot.centerx
	unit.path.dest.y = newSpot.centery
	unit.path.dest.z = newSpot.z

	unit.path.path.x:resize(0)
	unit.path.path.y:resize(0)
	unit.path.path.z:resize(0)
end

local function iterateJobs(func)
	local listLink = df.global.world.jobs.list
	while true do
		if listLink.item then
			func(listLink.item)
		end
		if listLink.next then
			listLink = listLink.next
		else
			break
		end
	end
end

local function onTick()
	iterateJobs(handleJob)
end

if args.status then
	print("proper-dining is " .. (enabled and "enabled" or "disabled"))
	return
end

local function start()
	repeatUtil.scheduleEvery(consts.scriptKey, 1, "ticks", onTick)
	enabled = true
	print("proper-dining enabled")
end

local function stop()
	repeatUtil.cancel(consts.scriptKey)
	enabled = false
	print("proper-dining disabled")
end

if dfhack_flags.enable then
	if dfhack_flags.enable_state then
		start()
	else
		stop()
	end
end
