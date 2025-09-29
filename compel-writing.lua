-- compel-writing
-- Initial v0.47.05 code by Tachytaenius

-- NOTE: Some details of the writing systems may not be imitated perfectly

-- TODO: Handle form id stuff right

local utils = require("utils")
local repeatUtil = require("repeat-util")
local scriptKey = "compel-writing"

local knowledgeCategories = { -- Indices here start at 1 but should start at 0 for DF
	"philosophy", "philosophy2",
	"math", "math2",
	"history",
	"astronomy",
	"naturalist",
	"chemistry",
	"geography",
	"medicine", "medicine2", "medicine3",
	"engineering", "engineering2"
}

local function getTopicInfo(knowledgeName) -- Given topic name, returns knowledge category name, knowledge category id, and topic id within category. Returns nil(s) for unknown topic
	-- Categories that aren't full have entries which are just number names, but they pose no issue
	for luaCategoryIndex, categoryName in ipairs(knowledgeCategories) do
		local categoryIndex = luaCategoryIndex - 1
		local bitfieldType = df["knowledge_scholar_flags_" .. categoryIndex]
		for topicIndex, topicName in ipairs(bitfieldType) do
			if topicName == knowledgeName then
				return categoryName, categoryIndex, topicIndex
			end
		end
	end
end

-- Returns event on success
local function tryWrite(unit, silent, writeAboutKnowledge, researchTopic, writingType, formId, skipFurnitureCheck)
	-- Bail if we're not researching
	if #unit.social_activities ~= 1 then
		if not silent then
			print("Unit is not in a social activity")
		end
		return
	end
	local activity = df.activity_entry.find(unit.social_activities[0])
	if activity.type ~= df.activity_entry_type.Research then
		if not silent then
			print("Social activity type is not research")
		end
		return
	end

	-- We need a parent research event
	if #activity.events == 0 then
		if not silent then
			print("Activity's event list is empty; no event to use as parent")
		end
		return
	end
	local parentEvent = activity.events[0]
	if parentEvent._type ~= df.activity_event_researchst then
		if not silent then
			print("First event (to use as parent) is not a research event")
		end
		return
	end

	-- Bail if we're in any event other than research, ponder, or discuss. This avoids writing more while writing, or anything unrecognised
	for _, event in ipairs(activity.events) do
		if
			event._type ~= df.activity_event_researchst and
			event._type ~= df.activity_event_ponder_topicst and
			event._type ~= df.activity_event_discuss_topicst
		then
			for _, unitId in ipairs(event.participants.units) do
				if unitId == unit.id then
					if not silent then
						print("Unit is currently in an activity event other than a research or ponder event")
					end
					return
				end
			end
		end
	end

	-- Used to look for items and buildings
	local zone = df.building.find(parentEvent.building_id)
	if not zone then
		if not silent then
			print("Couldn't find zone building for event")
		end
		return
	end

	local writingMaterial
	-- Look for writing material
	local function writable(item, unit, containingBuildingPos)
		if
			item.flags.in_job or item.flags.forbid or item.flags.owned or item.flags.garbage_collect or item.flags.dump or
			not item.flags2.unk_book or -- Reserved by a location
			not item:hasToolUse(df.tool_uses.CONTAIN_WRITING) or item:hasWriting() or
			dfhack.items.getGeneralRef(item, df.general_ref_type.ACTIVITY_EVENT) or
			not dfhack.maps.canWalkBetween(unit.pos, containingBuildingPos or item.pos)
			-- TODO: Check stuff like burrows?
		then
			return false
		end
		return true
	end
	local function pos(x, y, z)
		local ret = df.coord:new()
		ret.x, ret.y, ret.z = x, y, z
		return ret
	end
	for _, building in ipairs(zone.children) do
		if building._type == df.building_boxst then
			for _, itemContainment in ipairs(building.contained_items) do
				if itemContainment.use_mode == 0 then
					local item = itemContainment.item
					if writable(item, unit, pos(building.x1, building.y1, building.z)) then
						writingMaterial = item
						break
					end
				end
			end
		end
	end
	if not writingMaterial then
		if not silent then
			print("Couldn't find writing material")
		end
		return
	end

	-- Look for table and chair to use
	local tableToWriteOn, chair
	if not skipFurnitureCheck then
		local tables, chairs = {}, {}
		for _, building in ipairs(zone.children) do -- I saw a zone building with a chair in it but no chair child building, so beware
			if building._type == df.building_tablest and #building.users.unit == 0 then
				tables[#tables + 1] = building
			elseif building._type == df.building_chairst and #building.users.unit == 0 then
				chairs[#chairs + 1] = building
			end
		end
		local function neighbours(b1, b2)
			local xNeighbours = b1.x1 == b2.x1 - 1 or b1.x1 == b2.x1 + 1
			local yNeighbours = b1.y1 == b2.y1 - 1 or b1.y1 == b2.y1 + 1
			return xNeighbours and not yNeighbours or yNeighbours and not xNeighbours
		end
		for _, tableToTry in ipairs(tables) do
			for _, chairToTry in ipairs(chairs) do
				if neighbours(tableToTry, chairToTry) then
					tableToWriteOn = tableToTry
					chair = chairToTry
					break
				end
			end
		end
		if not (tableToWriteOn and chair) then
			if not silent then
				print("Couldn't find usable table/chair pair")
			end
			return
		end
	end

	-- Setup event
	local event = df.activity_event_writest:new()
	event.event_id = activity.next_event_id
	event.activity_id = activity.id
	event.parent_event_id = parentEvent.event_id

	event.unk_v42_1:insert("#", {new = true, -- Items vector
		unk_1 = 3, -- Role, 3 is item to write on
		item_id = writingMaterial.id,
		unk_2 = 0 -- Flags, nothing to set
	})

	-- We're going to do the minimum work ourselves and let the game handle as much as possible, so we don't need to set the furniture
	-- if not skipFurnitureCheck then
	-- 	event.unk_v42_2:insert("#", {new = true, -- Buildings vector
	-- 		unk_1 = 1, -- Role, 1 is sit and write
	-- 		unk_2 = chair.id, -- Building id
	-- 		item_id = unit.id, -- item_id is unit id
	-- 		unk_3 = 0 -- Flags, nothing to set
	-- 	})
	-- 	event.unk_v42_2:insert("#", {new = true,
	-- 		unk_1 = 2, -- Role, 2 is placed writing materials
	-- 		unk_2 = tableToWriteOn.id,
	-- 		item_id = unit.id,
	-- 		unk_3 = 0
	-- 	})
	-- end

	event.participants.histfigs:insert("#", unit.hist_figure_id)
	event.participants.units:insert("#", unit.id)
	event.participants.free_histfigs:insert("#", unit.hist_figure_id)
	event.participants.free_units:insert("#", unit.id)
	event.participants.activity_id = activity.id
	event.participants.event_id = event.event_id

	event.building_id = parentEvent.building_id
	event.site_id = parentEvent.site_id
	event.location_id = parentEvent.location_id

	event.timer = 0 -- Game constructs the right time

	event.unk_2 = writingType and df.written_content_type[writingType] or -1
	event.unk_3 = formId or -1
	event.mode = writeAboutKnowledge and df.activity_event_writest.T_mode.WriteAboutKnowledge or -1
	local flags = event.knowledge.flag_data["flags_" .. event.knowledge.flag_type]
	for flagName in pairs(flags) do
		flags[flagName] = false -- May be necessary, it seems uninitialised
	end
	if researchTopic then -- Research topics can be put on poems etc
		local _, categoryIndex, _ = getTopicInfo(researchTopic)
		if not categoryIndex then
			error("Invalid topic " .. tostring(researchTopic))
		end
		event.knowledge.flag_type = categoryIndex
		event.knowledge.flag_data["flags_" .. categoryIndex][researchTopic] = true
	end

	-- Take us out of any events that we're in before adding the write event
	-- Actually, this breaks things, even though it's what I saw when researching game-made writing event state
	-- for _, event in ipairs(activity.events) do
	-- 	local i = 0
	-- 	while i < #event.participants.units do
	-- 		if event.participants.units[i] == unit.id then
	-- 			event.participants.units:erase(i)
	-- 			event.participants.histfigs:erase(i)
	-- 		else
	-- 			i = i + 1
	-- 		end
	-- 	end

	-- 	local i = 0
	-- 	while i < #event.participants.free_units do
	-- 		if event.participants.free_units[i] == unit.id then
	-- 			event.participants.free_units:erase(i)
	-- 			event.participants.free_histfigs:erase(i)
	-- 		else
	-- 			i = i + 1
	-- 		end
	-- 	end
	-- end

	-- Commit changes to game

	activity.next_event_id = activity.next_event_id + 1
	activity.events:insert("#", event)

	writingMaterial.flags.in_job = true
	local ref = df.general_ref_activity_eventst:new()
	ref.activity_id = activity.id
	ref.event_id = event.event_id
	writingMaterial.general_refs:insert("#", ref)

	return event
end

local validArgs = utils.invert({
	"target",
	"writeAboutKnowledge",
	"writeAboutKnowledgeChance",
	"researchTopic",
	"writingType",
	"formId",
	"skipFurnitureCheck", -- May result in holding the item being written on
	"silent",
	"start",
	"time",
	"timeUnits",
	"chancePerRepeat",
	"stop"
})
local args = utils.processArgs({...}, validArgs)

if args.stop then
	print("Cancelling automatic compel-writing")
	repeatUtil.cancel(scriptKey)
	return
end

local unit
if not args.start then
	if args.target then
		unit = df.unit.find(tonumber(args.target))
	else
		unit = dfhack.gui.getSelectedUnit()
	end
	assert(unit, "Could not find target")
end

local writeAboutKnowledgeChance
if args.writeAboutKnowledgeChance then
	assert(not args.writeAboutKnowledge, "Can't specify both writeAboutKnowledgeChance and writeAboutKnowledge")
	writeAboutKnowledgeChance = tonumber(args.writeAboutKnowledgeChance)
	assert(writeAboutKnowledgeChance, "Specify a number for writing about knowledge chance (between 0 and 1)")
else
	writeAboutKnowledgeChance = 0.2 -- 20% chance of writing about knowledge when unspecified, allowing for more free writing. Most fortress writing tends to be scholarly, so...
end

local function getChanceBasedDetails(unit, silent)
	local writeAboutKnowledge
	if not args.writeAboutKnowledge then
		-- math.random() is never 1 so math.random() < probability is good
		writeAboutKnowledge = math.random() < writeAboutKnowledgeChance
	else
		writeAboutKnowledge =
			args.writeAboutKnowledge == "true" and true or
			args.writeAboutKnowledge == "false" and false
		if writeAboutKnowledge == nil then
			error("writeAboutKnowledge argument must be either true, false, or not specified")
		end
	end

	local researchTopic
	if writeAboutKnowledge and not args.researchTopic or args.researchTopic == "known" then
		if unit then -- If unit is nil, then presumably we're just here to validate args for automatic mode
			-- Pick a topic known about by the writer
			local histfig = df.historical_figure.find(unit.hist_figure_id)
			local knowledge = histfig and histfig.info.known_info and histfig.info.known_info.knowledge
			if knowledge then
				local knownTopics = {}
				for _, category in ipairs(knowledgeCategories) do
					for topic, known in pairs(knowledge[category]) do
						if known then
							knownTopics[#knownTopics + 1] = topic
						end
					end
				end
				researchTopic = #knownTopics > 0 and knownTopics[math.random(#knownTopics)]
			end
			if not researchTopic then
				-- Bail if they known no topics
				if not silent then
					print("Writing about knowledge but no known topics, not writing anything")
				end
				return
			end
		end
	elseif args.researchTopic == "none" then
		-- Explicitly use no topic even if we're writing about knowledge, since when writing about knowledge an unspecified topic defaults to any known topic
		-- This leads to a book with "knowledge" in the title and a broken description ("the writing concerns .")
	elseif args.researchTopic then
		local categoryName, _, _ = getTopicInfo(args.researchTopic)
		assert(categoryName, "Unknown research topic \"" .. args.researchTopic .. "\"")
		if unit and not silent then
			-- Warn if it isn't known about by the writer
			local histfig = df.historical_figure.find(unit.hist_figure_id)
			local knowledge = histfig and histfig.info.known_info and histfig.info.known_info.knowledge
			local topicKnown = knowledge and knowledge[categoryName][args.researchTopic]
			if not topicKnown then
				print("Note: topic \"" .. args.researchTopic .. "\" is not known by writer")
			end
		end
		researchTopic = args.researchTopic
	end

	local writingType
	if args.writingType then
		assert(df.written_content_type[args.writingType], "Unknown writing type \"" .. args.writingType .. "\"")
		writingType = args.writingType
	elseif writeAboutKnowledge then
		writingType = "Manual"
	end
	-- nil will be handled as a -1 in the write event, which lets the game choose. Unless writeAboutKnowledge is true, in which case it will be Manual. TreatiseOnTechnologicalEvolution-type contents have also been observed to be written in relation to research topics, but when this happens is unknown, so I've left it out.

	return writeAboutKnowledge, researchTopic, writingType
end

local formId
if args.formId then
	assert(tonumber(args.formId), "Form ID must be a number")
	formId = args.formId
end
-- nil will be handled as a -1 in the write event, which leads to no form? More research needed on form stuff

if args.start then
	assert(not args.target, "Can't specify a target when starting automated mode")

	local time
	if args.time then
		time = tonumber(args.time)
		assert(time, "Specify a number for script repeat interval")
	else
		time = 1
	end

	local timeUnits = args.timeUnits or "months"

	local chancePerRepeat
	if args.chancePerRepeat then
		chancePerRepeat = tonumber(args.chancePerRepeat)
		assert(chancePerRepeat, "Specify a number for chance of trying to write on script repeat")
	elseif not args.time and not args.timeUnits then
		chancePerRepeat = 0.05
	else
		error("If specifying time or timeUnits of script repeat, also specify chancePerRepeat")
	end

	getChanceBasedDetails() -- For errors if the args are bad
	repeatUtil.scheduleEvery(scriptKey, time, timeUnits, function()
		for _, unit in ipairs(df.global.world.units.active) do
			-- if dfhack.units.isCitizen(unit) then -- TODO: Allow visitors?
				if math.random() < chancePerRepeat then
					local writeAboutKnowledge, researchTopic, writingType = getChanceBasedDetails(unit, true)
					tryWrite(unit, true, writeAboutKnowledge, researchTopic, writingType, formId, args.skipFurnitureCheck) -- The checks in this will suffice
				end
			-- end
		end
	end)
	print("Scheduled compel-writing with chance")
	return
end

local writeAboutKnowledge, researchTopic, writingType = getChanceBasedDetails(unit, args.silent)
local event = tryWrite(unit, args.silent, writeAboutKnowledge, researchTopic, writingType, formId, args.skipFurnitureCheck)
if not args.silent then
	if event then
		print("Writing event created successfully")
	else
		print("Failed to create writing event")
	end
end
