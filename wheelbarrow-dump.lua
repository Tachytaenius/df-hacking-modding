--@ enable = true

-- wheelbarrow-dump

-- Gets units to dump heavy items using wheelbarrows. Unfinished (has TODOs), but works for speeding up dumping boulders
-- Doesn't work for dumping items off ledges, because it converts DumpItem jobs to StoreItemInStockpile jobs
-- A whole garbage system overhaul script is a good idea. This is probably temporary

local repeatUtil = require("repeat-util")
local utils = require("utils")
local eventful = require("plugins.eventful")

local consts = {
	scriptKey = "wheelbarrow-dump",

	-- These may be the same but they don't have to be
	handledDumpItemJobFlagKey = 31, -- For DumpItem jobs
	wasDumpItemJobFlagKey = 31 -- For StoreItemInStockpile jobs
}

local validArgs = utils.invert({
	"status"
})

local args = utils.processArgs({...}, validArgs)

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

local function findWheelbarrow(x, y, z)
	local choices = {}
	for _, item in ipairs(df.global.world.items.other.TOOL) do
		if not canUseItem(item) then
			goto continue
		end
		if not item:hasToolUse(df.tool_uses.HEAVY_OBJECT_HAULING) then
			goto continue
		end
		if item.stockpile.id ~= -1 then
			goto continue
		end
		local ix, iy, iz = dfhack.items.getPosition(item)
		if not (ix and iy and iz) then
			goto continue
		end
		if not dfhack.maps.canWalkBetween(xyz2pos(x, y, z), xyz2pos(ix, iy, iz)) then
			goto continue
		end
		table.insert(choices, item)
	    ::continue::
	end
	return choices[1] -- TODO: Distance sort
end

local function handleJob(job)
	if job.job_type ~= df.job_type.DumpItem then
		return
	end
	if job.flags[consts.handledDumpItemJobFlagKey] then
		return
	end

	job.flags[consts.handledDumpItemJobFlagKey] = true

	local worker = dfhack.job.getWorker(job)
	if worker then
		return
	end

	-- TODO: Go by total weight
	local needsWheelbarrow = false
	local firstHauledItem
	for _, itemRef in ipairs(job.items) do
		if itemRef.role == df.job_item_ref.T_role.Hauled then
			firstHauledItem = firstHauledItem or itemRef.item
			if itemRef.item._type == df.item_boulderst then
				needsWheelbarrow = true
			end
		end
	end

	if not needsWheelbarrow then
		return
	end
	if not firstHauledItem then
		return
	end

	local x, y, z = dfhack.items.getPosition(firstHauledItem)
	if not (x and y and z) then
		return
	end

	local wheelbarrow = findWheelbarrow(x, y, z)
	if not wheelbarrow then
		return
	end

	addItemToJob(job, wheelbarrow, df.job_item_ref.T_role.PushHaulVehicle, -1, -1)
	job.job_type = df.job_type.StoreItemInStockpile
	job.flags[consts.handledDumpItemJobFlagKey] = false -- Free up for any other script
	job.flags[consts.wasDumpItemJobFlagKey] = true -- For onJobCompleted
	job.completion_timer = 0 -- So that onJobCompleted triggers
	job.item_subtype = df.unit_labor.HAUL_REFUSE -- "When StoreInStockpile this is a unit_labor"
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

local function onJobCompleted(job)
	if job.job_type ~= df.job_type.StoreItemInStockpile then
		return
	end
	if not job.flags[consts.wasDumpItemJobFlagKey] then
		return
	end

	for _, itemRef in ipairs(job.items) do
		local roleName = df.job_item_ref.T_role[itemRef.role]
		if roleName == "Hauled" then
			local item = itemRef.item -- Still exists?
			local x, y, z = dfhack.items.getPosition(item)
			if
				-- Check that it is at the position to differentiate from a cancelled dump job
				x and y and z and
				x == job.pos.x and
				y == job.pos.y and
				z == job.pos.z
			then
				item.flags.forbid = true
				item.flags.dump = false
			end
		elseif roleName == "PushHaulVehicle" then
			-- TODO: Bring back to dump wheelbarrow stockpile
		end
	end
end

if args.status then
	print("wheelbarrow-dump is " .. (enabled and "enabled" or "disabled"))
	return
end

local function start()
	repeatUtil.scheduleEvery(consts.scriptKey, 1, "ticks", onTick)
	eventful.onJobCompleted[consts.scriptKey] = onJobCompleted
	eventful.enableEvent(eventful.eventType.JOB_COMPLETED, 0)
	enabled = true
	print("wheelbarrow-dump enabled")
end

local function stop()
	repeatUtil.cancel(consts.scriptKey)
	eventful.onJobCompleted[consts.scriptKey] = nil
	enabled = false
	print("wheelbarrow-dump disabled")
end

if dfhack_flags.enable then
	if dfhack_flags.enable_state then
		start()
	else
		stop()
	end
end
