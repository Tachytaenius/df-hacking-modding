-- put-item
-- By Tachytaenius

-- TODO: cancelDisplayJob for job menu

local utils = require("utils")
local eventful = require("plugins.eventful")

local consts = {
	unsetItemInBuildingJobFlagKey = 31,
	scriptKey = "put-item"
}

enabled = enabled or false

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

local validArgs = utils.invert({
	"cancelJob",

	"itemId",
	"buildingId",
	"nonPermanent",
	"forceEventManagerFix",

	-- Only important for users who are setting nonPermanent:
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
	print("Stopped watching for jobs set to unset the item's in_building flag")
	return
end

if args.startWatching then
	eventful.onJobCompleted[consts.scriptKey] = function(job)
		if job.job_type ~= df.job_type.PutItemOnDisplay or not job.flags[consts.unsetItemInBuildingJobFlagKey] then
			return
		end
		for _, itemRef in ipairs(job.items) do
			itemRef.item.flags.in_building = false
		end
	end
	eventful.enableEvent(eventful.eventType.JOB_COMPLETED, 0)
	enabled = true
	print("Started watching for jobs set to unset the item's in_building flag! Hopefully automatically on map load.")
	return
end

if args.cancelJob then
	local job
	if tonumber(args.cancelJob) then
		local jobId = tonumber(args.cancelJob)
		local listLink = df.global.world.jobs.list
		while true do
			if listLink.item then
				local listJob = listLink.item
				if listJob.id == jobId then
					job = listJob
					break
				end
			end
			if listLink.next then
				listLink = listLink.next
			else
				break
			end
		end
	elseif args.cancelJob == "selected" then
		job = dfhack.gui.getSelectedJob()
	end
	if not job then
		qerror("No job specified")
	end
	if job.job_type ~= df.job_type.PutItemOnDisplay then
		qerror("Not a PutItemOnDisplay job")
	end
	-- dfhack.job.removeJob(job) -- Supposedly unsafe in this version, so instead we will sabotage the job for the next time someone takes it
	job.flags.item_lost = true
	-- Also need to cancel the item references
	-- Backported from later DFHack versions' disconnectJobItem
	for _, itemRef in ipairs(job.items) do
		if not itemRef.item then
			goto continue
		end
		local refCount = #itemRef.item.specific_refs
		local stillHasJobs = false
		for i = refCount - 1, 0, -1 do
			local ref = itemRef.item.specific_refs[i]
			if ref.type == df.specific_ref_type.JOB then
				if ref.data.job == job then
					itemRef.item.specific_refs:erase(i)
					ref:delete()
				end
			end
		end
		if not stillHasJobs then
			itemRef.item.flags.in_job = false
		end
	    ::continue::
	end
	job.items:resize(0)
	return
end

local item = df.item.find(args.itemId)
if not item then
	qerror("Could not find item with id " .. args.itemId)
end

local building = df.building.find(args.buildingId)
if not building then
	qerror("Could not find building with id " .. args.buildingId)
end

if args.nonPermanent then
	if not enabled then
		qerror("Must enable put-item's watching functionality of placing items non-permanently. Please enable the script in your onMapLoad.init (or another script that runs on map load), as if not then if you reload the world with a job marked for non-permanent placement running the item will be placed as permanent.")
	end
end

local job = df.job:new()

if args.nonPermanent or args.forceEventManagerFix then
	job.completion_timer = 0 -- Workaround for event manager bug for this type of job
end
if args.nonPermanent then
	job.flags[consts.unsetItemInBuildingJobFlagKey] = true
end

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

return job -- In case run_script'd
