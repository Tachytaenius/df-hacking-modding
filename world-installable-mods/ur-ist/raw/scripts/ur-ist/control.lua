-- ur-ist's control script
-- Controls The Royal Game of Ur in Dwarf Fortress
-- By Tachytaenius
-- For DF version 0.47.05

-- Requires my put-item script
-- Requires my v47utils plugin for safe job cancellation

local repeatUtil = require("repeat-util")
local utils = require("utils")
local customRawTokens = require("custom-raw-tokens")
local eventful = require("plugins.eventful")
local persistTable = require("persist-table") -- TODO: Fix persist-table not loading stuff properly when loading from a Lua file in init.d but working if loading from onMapLoad.init (which is not ideal, we want it to be fully self-contained in the raws per-world)

local consts = {
	-- These also depend on job type
	isPlayUrJobFlagKey = 31,
	isLocationStorageJobFlagKey = 30,
	isWaitForUrGameJobFlagKey = 30,
	isRunningPlayJobFlagKey = 29,

	-- For when we can't let the job finish just yet
	waitJobCompletionTimerSet = 15,
	playJobCompletionTimerSet = 50, -- TODO: Does a custom reaction with no skill (like the ones used in this mod) have any way to make this timer move faster? Ideally not.

	scriptKey = "ur-ist",

	-- TODO(?)
	-- requiredDice = {
	-- 	standard = {
	-- 		tetrahedral = 4
	-- 	}
	-- }
}

local validArgs = utils.invert({
	"urScriptLocation",
	"startManaging",
	"stopManaging",
	"status",
	"getDesiredBoardCount",
	"setDesiredBoardCount",
	"getBoardsInLocation",
	"gameChancePerTick",
	"searchNow"
})
local args = utils.processArgs({...}, validArgs)

local urScriptLocation = args.urScriptLocation or "ur-ist/ur"
local makeNewUrInstance
if not pcall(function()
	makeNewUrInstance = dfhack.run_script(urScriptLocation)
end) then
	qerror("Couldn't find Ur script at location " .. urScriptLocation .. ". Use the -urScriptLocation argument to point to it.")
end

local function shuffle(t)
	local ret = {}
	for i = 1, #t do
		ret[i] = t[i]
	end
	for i = #t, 2, -1 do
		local j = rng:random(i) + 1
		ret[i], ret[j] = ret[j], ret[i]
	end
	return ret
end

local function removeJobThought(job) -- For onJobCompleted
	-- TODO: Ensure all data in personality is consistent after doing this, including the debug struct that exists in v50+ (when updating this script)
	local unit = dfhack.job.getWorker(job)
	if not unit then
		return
	end
	local soul = unit.status.current_soul
	if not soul then
		return
	end
	for i, emotion in ipairs(soul.personality.emotions) do
		if
			emotion.year == df.global.cur_year and emotion.year_tick == df.global.cur_year_tick and
			emotion.thought == df.unit_thought_type.SatisfiedAtWork and
			emotion.subthought == job.job_type
		then
			soul.personality.emotions:erase(i)
			return
		end
	end
end

local function cancelJob(job)
	-- This can crash with general refs left in the job, so we clear them
	local i = 0
	while i < #job.general_refs do
		local ref = job.general_refs[i]
		if
			-- These two types are handled by job removal code already
			ref._type ~= df.general_ref_building_holderst and
			ref._type ~= df.general_ref_unit_workerst
		then
			job.general_refs:erase(i)
		else
			i = i + 1
		end
	end
	dfhack.run_command("v47utils remove-job " .. job.id)
end

local function canUseFurniture(building)
	return
		building.flags.exists and
		building:isActual() and
		building:getBuildStage() >= building:getMaxBuildStage() and
		not dfhack.buildings.markedForRemoval(building) and
		#building.jobs == 0 and
		not building:isForbidden() and
		not (building:getUsers() and #building:getUsers().unit > 0)
end

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

local function findReactionByName(name)
	for _, reaction in ipairs(df.global.world.raws.reactions.reactions) do
		if reaction.code == name then
			return reaction
		end
	end
end

-- Backported from later versions of DFHack
local function removeJobPostings(job, removeAll)
	assert(job, "No job specified")
	local world = df.global.world
	local removed = false
	if not removeAll then
		if job.posting_index >= 0 and job.posting_index < #world.jobs.postings then
			local posting = world.jobs.postings[job.posting_index]
			posting.flags.dead = true
			posting.job = nil
			removed = true
		end
	else
		for _, posting in ipairs(world.jobs.postings) do
			if posting.job == job then
				posting.flags.dead = true
				posting.job = nil
				removed = true
			end
		end
	end
	job.posting_index = -1
	return removed
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
	if isUnitInSquadOrder(unit) then
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
		removeJobPostings(job)
	end

	job.general_refs:insert("#", {new = df.general_ref_unit_workerst, unit_id = unit.id})
	job.recheck_cntdn = 0

	unit.job.current_job = job

	return true
end

local function getSelectedLocation()
	local screen = dfhack.gui.getCurViewscreen()
	if screen._type ~= df.viewscreen_locationsst then
		qerror("Not in the locations menu")
	end
	local location = screen.locations[screen.location_idx]
	return location
end

local function ensureBoardCountStorage()
	persistTable.GlobalTable.urIstLocationDesiredBoardCounts = persistTable.GlobalTable.urIstLocationDesiredBoardCounts or {}
end

local function isUrBoard(item)
	return customRawTokens.getToken(item, "UR_MOD_CAN_PLAY_UR")
end

local function isPlayJob(job)
	return job.job_type == df.job_type.CustomReaction and job.flags[consts.isPlayUrJobFlagKey]
end

local function isPlayJobRunning(job)
	assert(isPlayJob(job), "Can't check if a job which isn't an Ur play job is a running Ur play job")
	return job.flags[consts.isRunningPlayJobFlagKey]
end

local function getUrJobBoardId(job)
	for _, ref in ipairs(job.general_refs) do
		if ref._type == df.general_ref_item then
			local item = ref:getItem()
			if item and isUrBoard(item) then
				return item.id
			end
		end
	end
end

local function getUrJobUnits(job)
	local a, b, getter
	for _, ref in ipairs(job.general_refs) do
		if ref._type == df.general_ref_unit then
			local unit = ref:getUnit()
			if not a then
				a = unit
			elseif not b then
				b = unit
			elseif not getter then
				getter = unit
			end
		end
	end
	return a, b, getter
end

local function getUrJobBuildings(job)
	local aChair, bChair, playTable
	for _, ref in ipairs(job.general_refs) do
		if ref._type == df.general_ref_building then
			local building = ref:getBuilding()
			if not aChair then
				aChair = building
			elseif not bChair then
				bChair = building
			elseif not playTable then
				playTable = building
			end
		end
	end
	return aChair, bChair, playTable
end
local function getUrJobSourceLocation(job)
	for _, ref in ipairs(job.general_refs) do
		if ref._type == df.general_ref_abstract_buildingst then
			if ref.site_id >= 0 and ref.site_id == df.global.ui.site_id then
				local site = df.world_site.find(df.global.ui.site_id)
				if site then
					return utils.binsearch(site.buildings, ref.building_id, "id")
				end
				return nil
			else
				return nil
			end
		end
	end
end

local function isStoreJob(job)
	return job.job_type == df.job_type.PutItemOnDisplay and job.flags[consts.isLocationStorageJobFlagKey]
end

local function getStoreJobDestinationLocationId(job)
	for _, ref in ipairs(job.general_refs) do
		if ref._type == df.general_ref_abstract_buildingst then
			if ref.site_id >= 0 and ref.site_id == df.global.ui.site_id then
				return ref.building_id
			else
				return nil
			end
		end
	end
end

local function isWaitJob(job)
	return job.job_type == df.job_type.CustomReaction and job.flags[consts.isWaitForUrGameJobFlagKey]
end

local function isWaitJobCorrectlyAssigned(job) -- Also returns false if the worker and intended unit are both absent
	local worker = dfhack.job.getWorker(job)
	local correctUnitRef = dfhack.job.getGeneralRef(job, df.general_ref_type.UNIT) -- Only one ref is stored, unlike on play jobs, so we can use this function
	if not correctUnitRef then
		error("Wait job was not marked with an intended unit.") -- Assuming this is a wait job.
	end
	local correctUnit = correctUnitRef:getUnit()
	if not (worker or correctUnit) then
		return false
	end
	return worker == correctUnit
end

local function getJobBuildingPosition(job)
	local building = dfhack.job.getHolder(job)
	if building then
		return building.centerx, building.centery, building.z
	end
end

local function canAddImminentJobAction(unit)
	if not unit.job.current_job then
		return false
	end
	local bx, by, bz = getJobBuildingPosition(unit.job.current_job)
	local ux, uy, uz = dfhack.units.getPosition(unit)
	if bx ~= ux or by ~= uy or bz ~= uz then
		return false
	end
	for _, action in ipairs(unit.actions) do
		local typeName = df.unit_action_type[action.type]
		if not (
			-- Allowed action types
			typeName == "None" or
			typeName == "Job" or
			typeName == "Job2" or
			typeName == "Talk"
		) then
			return false
		end
	end
	return true
end

local function addImminentJobAction(unit)
	-- dfhack.units.setActionTimers(waitUnit, 1, df.unit_action_type.Job) -- Doesn't set if not present
	local set = false
	local x, y, z = getJobBuildingPosition(unit.job.current_job)
	for _, action in ipairs(unit.actions) do
		if action.type == df.unit_action_type.None then
			action.type = df.unit_action_type.Job
			local data = action.data.job
			data.x, data.y, data.z = x, y, z
			data.timer = 1
			set = true
			break
		elseif action.type == df.unit_action_type.Job then
			local data = action.data.job
			-- Not much point checking the job action position probably
			data.timer = 1
			set = true
			break
		end
	end
	if not set then
		local action = df.unit_action:new()
		action.id = unit.next_action_id
		action.type = df.unit_action_type.Job
		local data = action.data.job
		data.x, data.y, data.z = x, y, z
		data.timer = 1
		unit.actions:insert("#", action)
		unit.next_action_id = unit.next_action_id + 1
	end
end

local function makeZoomAnnouncement(text, colour, bright, announcementType, zoomType, x, y, z)
	local announcements = df.global.world.status.announcements
	local prevLength = #announcements
	dfhack.gui.showZoomAnnouncement(announcementType, xyz2pos(x, y, z), text, colour, bright)
	for i = prevLength, #announcements - 1 do -- Get continuations
		local announcement = announcements[i]
		announcement.zoom_type = zoomType
	end
end

local function getUnitGameBotIntelligence(unit)
	local analyticalAbility = dfhack.units.getMentalAttrValue(unit, df.mental_attribute_type.ANALYTICAL_ABILITY)
	return math.min(1, analyticalAbility / 4000)
end

local function playGame(playJob, unitA, unitB, jobsToCancel)
	local function randomInt(lower, upper) -- Expected to be a random integer within [lower, upper]. rng:random(limit) is a random integer within [0, limit)
		return lower + rng:random(upper - lower + 1)
	end

	local game = makeNewUrInstance({
		aPlayer = getUnitGameBotIntelligence(unitA),
		bPlayer = getUnitGameBotIntelligence(unitB),
		randomInt = randomInt,
		randomFloat = function() return rng:drandom() end
	})
	game:tick()

	local winner, loser
	if game.winner == "a" then
		winner, loser = unitA, unitB
	elseif game.winner == "b" then
		winner, loser = unitB, unitA
	end

	-- Announce
	local winnerName = dfhack.units.getVisibleName(winner)
	local loserName = dfhack.units.getVisibleName(loser)
	local winnerString = winnerName and dfhack.TranslateName(winnerName) or "An unknown creature"
	local loserString = loserName and dfhack.TranslateName(loserName) or "an unknown creature"
	local announcement = winnerString .. " has won a game of Ur against " .. loserString .. "."
	makeZoomAnnouncement(announcement, 2, true, -1, df.report_zoom_type.Unit, dfhack.units.getPosition(winner))

	-- Add thoughts
	dfhack.run_script("add-thought", "--unit", winner.id, "--emotion", df.emotion_type.ENJOYMENT, "--strength", 1, "--thought", df.unit_thought_type.PlayToy, "--subthought", "\\-1") -- -1 is interpreted as an argument, but \-1 means "no particular toy type"
	dfhack.run_script("add-thought", "--unit", loser.id, "--emotion", df.emotion_type.ENJOYMENT, "--strength", 1, "--thought", df.unit_thought_type.PlayToy, "--subthought", "\\-1")

	-- Remove wait jobs
	local a, b, getter = getUrJobUnits(playJob)
	local waitUnits = {}
	if a ~= getter then
		waitUnits[#waitUnits+1] = a
	end
	if b ~= getter then
		waitUnits[#waitUnits+1] = b
	end
	for _, waitUnit in ipairs(waitUnits) do
		-- We don't break this loop upon encountering an error because we also want to gather up all wait jobs we have access to to cancel them all
		local job = waitUnit.job.current_job
		if job and isWaitJob(job) and isWaitJobCorrectlyAssigned(job) then
			jobsToCancel[#jobsToCancel+1] = job -- Don't cancel jobs during an onJobCompleted callback! That causes a crash
		end
	end
end

local function isItemAvailableForUrCheck(item)
	return
		item.flags.in_building and -- Needed for keeping the game from using the items. Items will be pulled out of buildings
		canUseItem(item)
end

local function isItemAvailableForUrLocationClaimCheck(item)
	return
		not item.flags.in_building and -- If this item *is* in_building, then it is not available for claiming
		canUseItem(item)
end

local function findItems(location, itemCheck, numRequired, walkablePosition, availabilityCheck)
	local foundItems = {}
	local contents = location:getContents()
	if not contents then
		return foundItems
	end
	for _, buildingId in ipairs(contents.building_ids) do
		local building = df.building.find(buildingId)
		if not building then
			goto continue
		end
		local buildingsToCheck = {building} -- To include parent building (in case it's a table, mostly)
		for _, subBuilding in ipairs(building.children) do
			buildingsToCheck[#buildingsToCheck+1] = subBuilding
		end
		for _, building in ipairs(buildingsToCheck) do
			if not (building._type == df.building_boxst or building._type == df.building_tablest) then
				goto continue
			end
			for _, containedItem in ipairs(building.contained_items) do
				if containedItem.use_mode ~= 0 then
					goto continue
				end
				local item = containedItem.item
				if not availabilityCheck(item, walkablePosition) then
					goto continue
				end
				if item._type ~= df.item_toolst then
					goto continue
				end
				if itemCheck(item) then
					foundItems[#foundItems+1] = item
				end
			    ::continue::
			end
			::continue::
		end
		::continue::
	end
	if numRequired then
		foundItems = shuffle(foundItems)
		for i = numRequired + 1, #foundItems do
			foundItems[i] = nil
		end
	end
	return foundItems
end

local function findSingleItem(location, itemCheck, walkablePosition, availabilityCheck)
	local items = findItems(location, itemCheck, 1, walkablePosition, availabilityCheck)
	if #items == 0 then
		return nil
	end
	-- local index = rng:random(#items) + 1
	local index = 1 -- If given numRequired then findItems looks through all possibilities, shuffles, and returns a table with only the first <numRequired> items. So in this function items is either an empty table or a table containing one random relevant item
	return items[index]
end

local function setUpGame(event, unitA, unitB, getterUnit)
	getterUnit = getterUnit or rng:drandom() < 0.5 and unitA or unitB

	local waitUnits = {}
	if unitA ~= getterUnit then
		waitUnits[#waitUnits+1] = unitA
	end
	if unitB ~= getterUnit then
		waitUnits[#waitUnits+1] = unitB
	end

	if not (
		canBeAddedToJob(getterUnit) and
		canBeAddedToJob(unitA) and
		canBeAddedToJob(unitB)
	) then
		return
	end

	if event.site_id < 0 or event.site_id ~= df.global.ui.site_id then
		return
	end
	local location
	for _, siteLocation in ipairs(df.world_site.find(event.site_id).buildings) do
		if siteLocation.id == event.location_id then
			location = siteLocation
			break
		end
	end

	local board = findSingleItem(location, isUrBoard, xyz2pos(dfhack.units.getPosition(getterUnit)),
		function(item, walkablePosition)
			if not dfhack.maps.canWalkBetween(walkablePosition, xyz2pos(dfhack.items.getPosition(item))) then
				return false
			end
			return isItemAvailableForUrCheck(item)
		end
	)
	if not board then
		return
	end

	local tables = {}
	local chairMap = {}
	local contents = location:getContents()
	if not contents then
		return
	end
	for _, buildingId in ipairs(contents.building_ids) do
		local building = df.building.find(buildingId)
		if not building then
			goto continue
		end
		local buildingsToCheck = {building} -- To include parent building (in case it's a table)
		for _, subBuilding in ipairs(building.children) do
			buildingsToCheck[#buildingsToCheck+1] = subBuilding
		end
		for _, building in ipairs(buildingsToCheck) do
			local buildingPos = xyz2pos(building.centerx, building.centery, building.z)
			if
				(
					building._type == df.building_tablest or
					building._type == df.building_chairst
				) and
				canUseFurniture(building) and
				dfhack.maps.canWalkBetween(
					xyz2pos(dfhack.units.getPosition(unitA)),
					buildingPos
				) and
				dfhack.maps.canWalkBetween(
					xyz2pos(dfhack.units.getPosition(unitB)),
					buildingPos
				)
			then
				if building._type == df.building_tablest then
					tables[#tables+1] = building
				elseif building._type == df.building_chairst then
					chairMap[building.z] = chairMap[building.z] or {}
					chairMap[building.z][building.centerx] = chairMap[building.z][building.centerx] or {}
					chairMap[building.z][building.centerx][building.centery] = building
				end
			end
		end
		::continue::
	end
	-- chairMap is z, x, y
	local tableSetsToChooseFrom = {}
	for _, table in ipairs(tables) do
		local x, y, z = table.centerx, table.centery, table.z
		local chairsThisLevel = chairMap[z]
		if not chairsThisLevel then
			goto continue
		end
		local function tryChair(ox, oy)
			return chairsThisLevel[x + ox] and chairsThisLevel[x + ox][y + oy]
		end
		local ac, bc = tryChair(-1, 0), tryChair(1, 0)
		if ac and bc then
			tableSetsToChooseFrom[#tableSetsToChooseFrom+1] = {table = table, chairA = ac, chairB = bc}
		end
		local ac, bc = tryChair(0, -1), tryChair(0, 1)
		if ac and bc then
			tableSetsToChooseFrom[#tableSetsToChooseFrom+1] = {table = table, chairA = ac, chairB = bc}
		end
	    ::continue::
	end
	local tableSet = tableSetsToChooseFrom[rng:random(#tableSetsToChooseFrom) + 1]
	if not tableSet then
		return
	end
	local table = tableSet.table

	-- TODO: Set furniture users?

	local waitBuildings = {
		[unitA.id] = tableSet.chairA,
		[unitB.id] = tableSet.chairB
	}

	local getJob = dfhack.run_script("put-item", "-itemId", board.id, "-buildingId", table.id, "-forceEventManagerFix") -- forceEventManagerFix ensures that onJobCompleted will activate for the job
	addJobWorker(getJob, getterUnit)
	-- Customise job and, if the reaction for it is present, make sure that the items aren't consumed by linking to a reagent with [PRESERVE_REAGENT]
	local gatherReaction = findReactionByName("GATHER_GAME_OF_UR_PIECES")
	local gatherReactionId = gatherReaction and gatherReaction.index
	-- TODO: If adding multiple items at once, will pointing them to the same reagent index be OK? Or will we have to extend the reaction's reagents on the fly to preserve all of them?
	if gatherReactionId then
		-- local preserverReagent = gatherReaction.reagents[0]

		-- Setting path is required to avoid picking up extra items!
		-- Which also probably means that wiping a unit's path can cause side effects, then?
		getterUnit.path.goal = df.unit_path_goal.GrabJobResources
		getterUnit.path.dest.x, getterUnit.path.dest.y, getterUnit.path.dest.z =
			dfhack.items.getPosition(board)

		getJob.job_items:insert("#", {new = true, reagent_index = 0, reaction_id = gatherReactionId})

		getJob.job_type = df.job_type.CustomReaction
		getJob.reaction_name = "GATHER_GAME_OF_UR_PIECES"
		getJob.flags.fetching = true
		getJob.items[0].is_fetching = 1
		getJob.items[0].role = df.job_item_ref.T_role.Reagent
		getJob.items[0].job_item_idx = 0
	end
	-- Hack extra information into the job
	getJob.flags[consts.isPlayUrJobFlagKey] = true
	getJob.general_refs:insert("#", {new = df.general_ref_abstract_buildingst, site_id = event.site_id, building_id = event.location_id})
	getJob.general_refs:insert("#", {new = df.general_ref_unit, unit_id = unitA.id})
	getJob.general_refs:insert("#", {new = df.general_ref_unit, unit_id = unitB.id})
	getJob.general_refs:insert("#", {new = df.general_ref_unit, unit_id = getterUnit.id})
	getJob.general_refs:insert("#", {new = df.general_ref_item, item_id = board.id})
	getJob.general_refs:insert("#", {new = df.general_ref_building, building_id = waitBuildings[unitA.id].id})
	getJob.general_refs:insert("#", {new = df.general_ref_building, building_id = waitBuildings[unitB.id].id})
	getJob.general_refs:insert("#", {new = df.general_ref_building, building_id = table.id})
	-- Ensure it has the correct completion timer (which remains suspended while the items are being placed etc)
	getJob.completion_timer = consts.playJobCompletionTimerSet

	for _, unit in ipairs(waitUnits) do
		local waitBuilding = waitBuildings[unit.id]
		local waitJob = df.job:new()
		waitJob.flags[consts.isWaitForUrGameJobFlagKey] = true
		waitJob.job_type = df.job_type.CustomReaction
		waitJob.reaction_name = "WAIT_FOR_GAME_OF_UR" -- It's fine if the reaction isn't present (because injecting them into a preexisting world seems to cause trouble), this will just call itself "Reaction".
		addJobWorker(waitJob, unit)
		local buildingRef = df.general_ref_building_holderst:new()
		buildingRef.building_id = waitBuilding.id
		waitJob.general_refs:insert("#", buildingRef)
		waitBuilding.jobs:insert("#", waitJob)
		waitJob.general_refs:insert("#", {new = df.general_ref_unit, unit_id = unit.id}) -- Who this job is for (used to force a cancel etc)
		waitJob.completion_timer = consts.waitJobCompletionTimerSet
		dfhack.job.linkIntoWorld(waitJob, true)
	end
end

local function canUnitPlay(unit)
	-- TODO: Not stressed, not hungry, etc
	if not dfhack.units.isCitizen(unit) then
		return false
	end
	if not unit.status.current_soul then
		return false
	end
	if unit.job.current_job then
		return false
	end
	if isUnitInSquadOrder(unit) then
		return false
	end
	return true
end

local function unitPairingScore(unitA, unitB)
	-- TODO: Friendship etc
	-- TODO: Return nil for a "no way"
	return 1
end

local function searchForGame()
	local activities = {}
	for i, activity in ipairs(df.global.world.activities.all) do
		activities[i + 1] = activity
	end
	local shuffledActivities = shuffle(activities)

	for _, activity in ipairs(shuffledActivities) do
		if activity.type ~= df.activity_entry_type.Socialize then
			goto continue
		end

		local rootEvent
		for _, event in ipairs(activity.events) do
			if event._type ~= df.activity_event_socializest then
				goto continue
			end
			if event.parent_event_id ~= -1 then
				goto continue
			end
			if event.flags.dismissed then
				goto continue
			end
			rootEvent = event
			do break end
			::continue::
		end

		local units = {}
		for _, unitId in ipairs(rootEvent.participants.free_units) do
			local unit = df.unit.find(unitId)
			if canUnitPlay(unit) then
				units[#units+1] = unit
			end
		end

		local pairings = {}
		for i = 1, #units - 1 do
			for j = i + 1, #units do
				local unitA = units[i]
				local unitB = units[j]
				local score = unitPairingScore(unitA, unitB)
				if score then
					pairings[#pairings+1] = {unitA = unitA, unitB = unitB, score = score}
				end
			end
		end

		if #pairings == 0 then
			goto continue
		end

		table.sort(pairings, function(a, b)
			if a.score == b.score then
				-- TODO: Break ties
			end
			return a.score < b.score
		end)

		-- TODO: Make earlier pairings in the list more likely
		local pairing = pairings[rng:random(#pairings) + 1]

		local getterUnit = nil -- TODO: Set up custom occupation for bringing boards to players in taverns?

		setUpGame(rootEvent, pairing.unitA, pairing.unitB, getterUnit)
		do break end

		::continue::
	end
end

local function getBoardsInLocation(location)
	local foundBoardsLocation = findItems(location, isUrBoard, nil, nil, isItemAvailableForUrCheck)
	local foundBoardsInPlayJobs = {}
	local foundBoardsInStoreJobs = {}
	local listLink = df.global.world.jobs.list
	while true do
		if listLink.item then
			local job = listLink.item
			-- Check job for any Ur-related items
			if isPlayJob(job) then
				if getUrJobSourceLocation(job) == location then
					local board = getUrJobBoardId(job)
					if board then
						local alreadyFound -- Like if in a table
						for _, previouslyFoundBoard in ipairs(foundBoardsLocation) do -- Shouldn't be able to find it in another job
							if previouslyFoundBoard == board then
								alreadyFound = true
								break
							end
						end
						if not alreadyFound then
							foundBoardsInPlayJobs[#foundBoardsInPlayJobs+1] = board
						end
					end
				end
			elseif isStoreJob(job) then
				if getStoreJobDestinationLocationId(job) == location.id then
					local itemRef = #job.items == 1 and job.items[0] -- Should this be a for loop in case we find a good way to bring multiple items in one job?
					if itemRef and itemRef.item and isUrBoard(itemRef.item) then
						local alreadyFound -- Like if in a table
						for _, previouslyFoundBoard in ipairs(foundBoardsLocation) do -- Shouldn't be able to find it in another job
							if previouslyFoundBoard == itemRef.item then
								alreadyFound = true
								break
							end
						end
						if not alreadyFound then
							foundBoardsInStoreJobs[#foundBoardsInStoreJobs+1] = itemRef.item
						end
					end
				end
			end
		end
		if listLink.next then
			listLink = listLink.next
		else
			break
		end
	end
	return foundBoardsLocation, foundBoardsInPlayJobs, foundBoardsInStoreJobs
end

local function isRightMode()
	return df.global.gamemode == df.game_mode.DWARF and dfhack.isMapLoaded()
end

local function getDesiredBoardCount(location)
	ensureBoardCountStorage()
	return tonumber(persistTable.GlobalTable.urIstLocationDesiredBoardCounts[location.id]) or 0
end

local function setDesiredBoardCount(location, count)
	ensureBoardCountStorage()
	persistTable.GlobalTable.urIstLocationDesiredBoardCounts[location.id] = tostring(count)
end

local function getLocationBoxBuildings(location)
	local boxBuildings = {}
	local contents = location:getContents()
	if not contents then
		return boxBuildings
	end
	for _, buildingId in ipairs(contents.building_ids) do
		local building = df.building.find(buildingId)
		if not building then -- Main building won't be a box, since you can't make a tavern from a box (TODO: what if I do, though.)
			goto continue
		end
		for _, subBuilding in ipairs(building.children) do
			if subBuilding._type == df.building_boxst and canUseFurniture(subBuilding) then
				boxBuildings[#boxBuildings+1] = subBuilding
			end
		end
		::continue::
	end
	return boxBuildings
end

local function tryPlaceBoardInLocationBox(item, location, boxBuildings, forceUnit)
	for _, box in ipairs(boxBuildings) do
		if
			dfhack.maps.canWalkBetween(
				xyz2pos(dfhack.items.getPosition(item)),
				xyz2pos(box.centerx, box.centery, box.z)
			)
			-- TODO: Check capacity
		then
			-- TODO: Custom reaction instead of put item on display for moving items around? Will it work? Don't forget to remove job thought.

			-- Synthesise a job to claim it (not a job marked with the unused flag used to start an actual game)
			local job = dfhack.run_script("put-item", "-itemId", item.id, "-buildingId", box.id, "-forceEventManagerFix") -- in_building will be true when it is placed
			job.flags[consts.isLocationStorageJobFlagKey] = true
			job.general_refs:insert("#", {new = df.general_ref_abstract_buildingst, site_id = df.global.ui.site_id, building_id = location.id})
			if forceUnit then
				local added = addJobWorker(job, forceUnit)
				return true, added
			end
			return true
		end
	end
	return false
end

local function eachDay()
	if not isRightMode() then
		return
	end

	-- local totalStoreJobs = 0
	-- local listLink = df.global.world.jobs.list
	-- while true do
	-- 	if listLink.item then
	-- 		local job = listLink.item
	-- 		if isStoreJob(job) then
	-- 			totalStoreJobs = totalStoreJobs + 1
	-- 		end
	-- 	end
	-- 	if listLink.next then
	-- 		listLink = listLink.next
	-- 	else
	-- 		break
	-- 	end
	-- end
	-- Can use the above to check if we're making too many store jobs

	for _, location in ipairs(df.world_site.find(df.global.ui.site_id).buildings) do
		local desired = getDesiredBoardCount(location)
		local foundBoardsLocation, foundBoardsInPlayJobs, foundBoardsInStoreJobs = getBoardsInLocation(location)
		local foundCount = #foundBoardsLocation + #foundBoardsInPlayJobs + #foundBoardsInStoreJobs
		local amountToChange = desired - foundCount

		if amountToChange > 0 then
			-- Claim more boards

			local boxBuildings = getLocationBoxBuildings(location)

			local foundItemsInLocation = findItems(location, isUrBoard, nil, nil, isItemAvailableForUrLocationClaimCheck)
			for _, item in ipairs(foundItemsInLocation) do
				assert(not item.flags.in_building, "in_building is supposed to mean the item is already claimed")
				local building = dfhack.items.getHolderBuilding(item)
				local claimed = false
				if building and building._type == df.building_boxst then
					item.flags.in_building = true
					claimed = true
				elseif building and building._type == df.building_tablest then
					local placed = tryPlaceBoardInLocationBox(item, location, boxBuildings)
					if placed then
						claimed = true
					end
				end
				if claimed then
					amountToChange = amountToChange - 1
					if amountToChange <= 0 then
						break
					end
				end
			end
			if amountToChange <= 0 then
				goto continue
			end

			for _, item in ipairs(df.global.world.items.other.TOOL) do
				if isUrBoard(item) and isItemAvailableForUrLocationClaimCheck(item) then
					local placed = tryPlaceBoardInLocationBox(item, location, boxBuildings)
					if placed then
						amountToChange = amountToChange - 1
						if amountToChange <= 0 then
							break
						end
					end
				end
			end
			if amountToChange <= 0 then
				goto continue
			end
		elseif amountToChange < 0 then
			-- Unclaim some boards

			for _, item in ipairs(foundBoardsLocation) do -- Not in job
				if not item.flags.in_job then
					-- Eligible for de-reservation
					item.flags.in_building = false
					amountToChange = amountToChange + 1
					if amountToChange >= 0 then
						break
					end
				end
			end
		end
	    ::continue::
	end
end

local function maintainJobs()
	local playJobs = {}
	local waitJobsInWorld = {} -- Not per play job

	local cancelledWaitJobIds = {}
	local waitJobsToCancel = {}
	local function markWaitJobCancel(job)
		if not cancelledWaitJobIds[job.id] then
			assert(isWaitJob(job), "Attemped to cancel a non-wait job as a wait job")
			waitJobsToCancel[#waitJobsToCancel+1] = job
			cancelledWaitJobIds[job.id] = true
		end
	end

	local listLink = df.global.world.jobs.list
	while true do
		if listLink.item then
			local job = listLink.item
			if isPlayJob(job) then
				playJobs[#playJobs+1] = job
			elseif isWaitJob(job) then
				waitJobsInWorld[#waitJobsInWorld+1] = job
			end
		end
		if listLink.next then
			listLink = listLink.next
		else
			break
		end
	end

	for _, playJob in ipairs(playJobs) do
		-- TODO: Cancel Ur jobs ifever any item hacked into its memory (or the location hacked into its memory (or the building!)) becomes in any way invalid

		-- TODO: Upon an Ur job being cancelled (at least anywhere in this mod's code), ensure the items are placed back in the location or were left on a table in in_building mode

		local errored = false

		local playJobWorker = dfhack.job.getWorker(playJob)
		-- Check that the job is still running OK
		if
			not playJobWorker or
			playJob.flags.suspend or
			playJob.flags.item_lost
		then
			errored = true
		end

		local a, b, getter = getUrJobUnits(playJob)
		local waitUnits = {}
		if a ~= playJobWorker then
			waitUnits[#waitUnits+1] = a
		end
		if b ~= playJobWorker then
			waitUnits[#waitUnits+1] = b
		end
		local waitJobsThisPlayJob = {}
		local waitJobsByUnit = {}

		-- Board and furniture present and OK?
		local aChair, bChair, table = getUrJobBuildings(playJob)
		local boardId = getUrJobBoardId(playJob)
		local board = boardId and df.item.find(boardId)
		if not (aChair and bChair and table and board) then
			errored = true
		end

		-- Check that wait units are in their correct jobs
		for _, waitUnit in ipairs(waitUnits) do
			-- We don't break this loop upon encountering an error because we also want to gather up all wait jobs we have access to to cancel them all
			local job = waitUnit.job.current_job
			if not job then
				errored = true
				goto continue
			end
			if not isWaitJob(job) then
				errored = true
				goto continue
			end
			waitJobsByUnit[waitUnit.id] = job
			waitJobsThisPlayJob[#waitJobsThisPlayJob+1] = job -- If present and marked as a wait job, but not necessarily valid
			if not isWaitJobCorrectlyAssigned(job) then
				errored = true
			end
		    ::continue::
		end

		if errored then
			-- Break play job and wait jobs
			cancelJob(playJob)
			for _, waitJob in ipairs(waitJobsThisPlayJob) do
				markWaitJobCancel(waitJob)
			end
		else
			-- Reset wait jobs' completion timers. We only do it here so that the jobs are only done indefinitely if the actual play job is still working
			for _, waitJob in ipairs(waitJobsThisPlayJob) do
				if waitJob.completion_timer < 0 then
					error("Something went wrong with the wait jobs, one (id " .. waitJob.id .. ") has a negative completion timer")
				end
				waitJob.completion_timer = consts.waitJobCompletionTimerSet
			end

			local ready = true

			local boardIsOnTable = table and board and dfhack.items.getHolderBuilding(board) == table
			-- if playJob.flags.fetching or playJob.flags.bringing then
			if not boardIsOnTable then
				ready = false
			elseif ready and not isPlayJobRunning(playJob) then
				-- Set play job to be running
				playJob.flags[consts.isRunningPlayJobFlagKey] = true
				playJob.completion_timer = consts.playJobCompletionTimerSet -- This seems to be able to tick down a tiny bit before the game is actually running

				local chairBuildingToMoveJobTo
				local other
				if getter ~= a and getter ~= b then
					-- Game was brought by a third unit

					-- Give play job to one of the players
					-- But first remove the player from their wait job (and mark it to be cancelled)
					local recipient = rng:drandom() < 0.5 and a or b
					other = recipient == a and b or a
					local waitJobToCancel = waitJobsByUnit[recipient.id]
					chairBuildingToMoveJobTo = dfhack.job.getHolder(waitJobToCancel)
					-- Don't use dfhack.job.removeWorker as it does not force
					recipient.job.current_job = nil
					for i, ref in ipairs(waitJobToCancel.general_refs) do
						if ref:getType() == df.general_ref_type.UNIT_WORKER then
							waitJobToCancel.general_refs:erase(i)
							ref:delete()
							break
						end
					end
					markWaitJobCancel(waitJobToCancel)

					-- Now we hand it over
					local workerRef = dfhack.job.getGeneralRef(playJob, df.general_ref_type.UNIT_WORKER)
					assert(workerRef, "Getter unit was not the job's worker??")
					getter.job.current_job = nil
					workerRef.unit_id = recipient.id
					-- workerRef.cached_index = -1
					recipient.job.current_job = playJob
				else
					chairBuildingToMoveJobTo = getter == a and aChair or bChair
					other = getter == a and b or a -- Whoever is waiting
				end

				-- Move play job from table to chair (without carrying items with it)
				local tableToMoveFrom = dfhack.job.getHolder(playJob)
				for i, job in ipairs(tableToMoveFrom.jobs) do
					if job == playJob then
						tableToMoveFrom.jobs:erase(i)
						break
					end
				end
				chairBuildingToMoveJobTo.jobs:insert("#", playJob)
				local holderRef = dfhack.job.getGeneralRef(playJob, df.general_ref_type.BUILDING_HOLDER)
				holderRef.building_id = chairBuildingToMoveJobTo.id
				local x, y, z = getJobBuildingPosition(playJob)
				playJob.pos.x, playJob.pos.y, playJob.pos.z = x, y, z
				local player = dfhack.job.getWorker(playJob)
				player.path.goal = df.unit_path_goal.SeekBuildingForJob -- Or WorkAtBuilding?
				player.path.dest.x = x
				player.path.dest.y = y
				player.path.dest.z = z
				-- Removing the path fixes a bug where the player would be removed from the job worker when the move action to go to the chair completed...? Something about the path's next step still being the table.
				player.path.path.x:resize(0)
				player.path.path.y:resize(0)
				player.path.path.z:resize(0)

				-- Make both the play job and the wait job say "play game of ur"
				playJob.reaction_name = "PLAY_GAME_OF_UR"
				waitJobsByUnit[other.id].reaction_name = "PLAY_GAME_OF_UR"
			end

			if not ready then
				playJob.completion_timer = consts.playJobCompletionTimerSet
			end
		end
	end

	for _, job in ipairs(waitJobsToCancel) do
		cancelJob(job)
	end
end

local jobsToCancelAfterJobCompletionCallbacks = {}

local function onJobCompleted(job)
	if isPlayJob(job) or isWaitJob(job) or isStoreJob(job) then
		removeJobThought(job)
	end

	if not (isPlayJob(job) and isPlayJobRunning(job)) then
		-- Ideally, a non-running play job would not complete
		return
	end

	local a, b, getter = getUrJobUnits(job)
	local location = getUrJobSourceLocation(job)
	local boardId = getUrJobBoardId(job)

	local board = boardId and df.item.find(boardId)

	if not (a and b and board and getter and location) then
		return
	end

	local holder = dfhack.items.getHolderBuilding(board)
	if not holder or holder._type ~= df.building_tablest then
		return
	end
	for _, contained in ipairs(holder.contained_items) do
		if contained.item == board then
			if contained.use_mode ~= 0 then
				return
			end
			break
		end
	end

	-- onJobCompleted runs all script's callbacks, then the onTick function runs. This avoids a crash
	playGame(job, a, b, jobsToCancelAfterJobCompletionCallbacks)

	local potentialReturners = {}
	if getter ~= a and getter ~= b then
		-- Had the game brought by a third person, try to use same person to bring it back
		potentialReturners[#potentialReturners+1] = getter
	end
	-- Either player can return, but if there was a getter then they take priority for returning
	if rng:drandom() < 0.5 then
		potentialReturners[#potentialReturners+1] = a
		potentialReturners[#potentialReturners+1] = b
	else
		-- Other way 'round
		potentialReturners[#potentialReturners+1] = b
		potentialReturners[#potentialReturners+1] = a
	end

	-- Get final returner
	local finalReturner
	for _, potentialReturner in ipairs(potentialReturners) do
		if canBeAddedToJob(potentialReturner) then
			finalReturner = potentialReturner
			break
		end
	end

	-- finalReturner can be nil
	tryPlaceBoardInLocationBox(board, location, getLocationBoxBuildings(location), finalReturner)
end

if not rng then
	rng = dfhack.random.new()
	rng:init()
end

forceSearch = args.searchNow

local function onTick()
	if not isRightMode() then
		return
	end
	maintainJobs()
	if rng:drandom() < gameChancePerTick or forceSearch then
		searchForGame()
	end

	forceSearch = false

	-- Jobs "sent" from onJobCompleted to this function. Should not contain data outside of the time between those two functions
	for _, job in ipairs(jobsToCancelAfterJobCompletionCallbacks) do
		cancelJob(job)
	end
	jobsToCancelAfterJobCompletionCallbacks = {}
end

if args.getDesiredBoardCount or args.setDesiredBoardCount then
	local location = getSelectedLocation()
	if args.getDesiredBoardCount then
		print(getDesiredBoardCount(location))
	elseif args.setDesiredBoardCount then
		setDesiredBoardCount(location, args.setDesiredBoardCount)
	end
end

if args.getBoardsInLocation then
	local location = getSelectedLocation()
	print(getBoardsInLocation(location))
end

if args.stopManaging then
	disable()
	return
end

if args.startManaging then
	local gatherReaction = findReactionByName("GATHER_GAME_OF_UR_PIECES")
	-- assert(gatherReaction, "Could not find gather reaction, are the mod's raws properly installed?") -- Allow it, because injecting reactions into premade worlds seems to break. We'll just not use the reactions
	if not gatherReaction then
		print("No GATHER_GAME_OF_UR_PIECES reaction found. Adding it to a preexisting world seems to break things, so the script will just run as usual. You won't see the custom job names, though.")
	end

	local found = false
	for _, def in ipairs(df.global.world.raws.itemdefs.tools) do
		if customRawTokens.getToken(def, "UR_MOD_CAN_PLAY_UR") then
			found = true
			break
		end
	end
	if not found then
		print("No tool items with an UR_MOD_CAN_PLAY_UR tag set (e.g. [UR_MOD_CAN_PLAY_UR:standard]). Did you install the mod properly, and if you're using a preexisting world, did you inject the item type(s)?")
	end

	local defaultChance = 1 / 12000
	gameChancePerTick = tonumber(args.gameChancePerTick) or defaultChance
	repeatUtil.scheduleEvery(consts.scriptKey, 1, "ticks", onTick)
	repeatUtil.scheduleEvery(consts.scriptKey .. "_daily", 1, "days", eachDay)
	eventful.onJobCompleted[consts.scriptKey] = onJobCompleted
	enabled = true
	print("Now managing Ur games and board/dice storage")
	return
end
