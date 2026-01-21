local function canUseItem(item)
	local flags = item.flags
	if
		flags.hostile or
		flags.on_fire or
		flags.trader or
		flags.construction or
		flags.in_job or
		flags.owned or
		flags.removed or
		flags.encased or
		flags.spider_web or
		flags.garbage_collect or
		flags.forbid
	then
		return false
	end
	if #item.specific_refs > 0 then
		return false
	end
	return true
end

local function addItemToJob(job, item, role, filterIdx, insertIdx) -- Backported from a later DFHack version
	if role ~= df.job_item_ref.T_role.TargetContainer then
		if item.flags.in_job then
			return false
		end
		item.flags.in_job = true
	end

	local itemLink = df.specific_ref:new()
	itemLink.type = df.specific_ref_type.JOB
	itemLink.data.job = job
	item.specific_refs:insert("#", itemLink)

	local jobLink = df.job_item_ref:new()
	jobLink.item = item
	jobLink.role = role
	jobLink.job_item_idx = filterIdx

	if insertIdx >= 0 and insertIdx < #job.items then
		job.items:insert(insertIdx, jobLink)
	else
		job.items:insert("#", jobLink)
	end

	return true
end

local building = dfhack.gui.getSelectedBuilding()
if not building then
	qerror("Please select a building")
end
if building._type ~= df.building_display_furniturest then
	qerror("Building is not display furniture")
end

local buildingPos = xyz2pos(building.centerx, building.centery, building.z)

local jobsMade = 0

for _, itemId in ipairs(building.displayed_items) do
	local item = df.item.find(itemId)
	if not item then
		goto continue
	end

	if not canUseItem(item) then
		goto continue
	end

	local itemX, itemY, itemZ = dfhack.items.getPosition(item)
	if not (itemX and itemY and itemZ) then
		goto continue
	end
	local itemPos = xyz2pos(itemX, itemY, itemZ)

	if not dfhack.maps.canWalkBetween(buildingPos, itemPos) then
		goto continue
	end

	local job = df.job:new()
	job.job_type = df.job_type.PutItemOnDisplay

	job.pos.x = building.centerx
	job.pos.y = building.centery
	job.pos.z = building.z

	addItemToJob(job, item, df.job_item_ref.T_role.Hauled, -1, -1)

	local buildingRef = df.general_ref_building_holderst:new()
	buildingRef.building_id = building.id
	job.general_refs:insert("#", buildingRef)
	building.jobs:insert("#", job)

	dfhack.job.linkIntoWorld(job, true)
	jobsMade = jobsMade + 1

    ::continue::
end

print("Made " .. jobsMade .. " job(s) to put items on display in selected building")
