--@ enable = true

local usage = [[
Usage
-----

enable tool-wear
disable tool-wear
]]

local eventful = require("plugins.eventful")
local customRawTokens = require("custom-raw-tokens")
local utils = require("utils")

local consts = {
	scriptKey = "tool-wear",

	-- Game's own values
	totalWearCapacity = 806400 * 4,
	qualityLevels = 5, -- 0 to 5 are standard qualities and 6 is artifact. Any item marked as an artifact, regardless of quality, receives no wear
}

local defaultConfig = {
	overallDurabilityMultiplier = 12000,
	qualityMulPower = 1.8,
	qualityMulLow = 0.4, -- Lower bound, within (0, 1]
	strengthConst = 500000, -- This number, instead of being used in the calculations implied above, is used in one that gives diminishing returns for material shear fracture.

	jobWearMultipliers = { -- All of these expect a weapon with the MINING melee skill except for FellTree (which expects AXE)
		Dig = 4,
		CarveUpwardStaircase = 3,
		CarveDownwardStaircase = 2, -- TODO: This sometimes removes more stone than Dig, sometimes less. Reconsider this system?
		CarveUpDownStaricase = 5,
		CarveRamp = 7,
		DigChannel = 7,
		RemoveStairs = 1,

		-- DetailWall DetailFloor CarveFortification

		FellTree = 40
	}
}

local config

local function loadConfig()
	config = utils.clone(defaultConfig, true) -- This table will be the one used by the script

	print("Loading tool-wear config")

	local success, configFromFile = pcall(function() return dfhack.run_script("tool-wear/config") end)
	if not success or not configFromFile then
		return
	end

	-- Now merge configFromFile into config (which is currently a deep copy of defaultConfig)
	for k, v in pairs(configFromFile) do
		-- nil is "leave as default". It won't come up in this loop, so we can just overwrite with everything pairs gives us (except for tables)
		if type(v) ~= "table" then
			config[k] = v
		end
	end
	if configFromFile.jobWearMultipliers then
		for k, v in pairs(configFromFile.jobWearMultipliers) do
			config.jobWearMultipliers[k] = v
		end
	end
end

local function getBrokenToolItemSubtypeIds()
	local ret = {} -- Maps material sizes to appropriate tool subtype ids, allowing gaps
	local highest = 0
	for _, toolSubtype in ipairs(df.global.world.raws.itemdefs.tools) do
		if customRawTokens.getToken(toolSubtype, "TOOL_WEAR_MOD_BROKEN_TOOL_PIECE") then
			local subtypeId = toolSubtype.subtype
			local matSize = toolSubtype.material_size
			if ret[matSize] then
				dfhack.printerr("Multiple tool itemdefs with [TOOL_WEAR_MOD_BROKEN_TOOL_PIECE] with material size " .. matSize)
			else
				ret[matSize] = subtypeId
				highest = math.max(highest, matSize)
			end
		end
	end
	local hasGaps = false
	for i = 1, highest do
		if not ret[i] then
			hasGaps = true
			break
		end
	end
	local allOK = true
	if not ret[1] or hasGaps then
		allOK = false
		dfhack.printerr("Broken tool itemdefs should increase in size from 1 to some number n for the algorithm that finds pieces to break broken tools into")
	end
	return ret, highest, allOK
end

local function saturate(x)
	return math.max(0, math.min(1, x))
end

local function handleWear(worker, item, jobWearFactor)
	local matinfo = dfhack.matinfo.decode(item)
	if not matinfo then
		return
	end
	local strength = matinfo.material.strength.fracture.SHEAR
	local durabilityMaterialMultiplier = strength / (config.strengthConst + strength)

	local durabilityQualityMultiplier = saturate(
		config.qualityMulLow + (1 - config.qualityMulLow) * (item.quality / consts.qualityLevels) ^ config.qualityMulPower
	)

	local durabilityScore = durabilityMaterialMultiplier * durabilityQualityMultiplier * config.overallDurabilityMultiplier

	local wearAmount
	if durabilityScore <= 0 then
		wearAmount = consts.totalWearCapacity
	else
		wearAmount = math.floor(consts.totalWearCapacity / durabilityScore * jobWearFactor)
	end

	local subtype = item.subtype

	item:addWear(wearAmount, false, false)
	local destroyed = item:checkWearDestroy(false, false)
	if destroyed then
		-- Place broken pieces (mostly for melting). Only one if possible (so that melting takes one fuel), or as few as possible
		local brokenSubtypeIds, highestBrokenSubtypeId, allOK = getBrokenToolItemSubtypeIds()
		if allOK then
			local materialToDrop = subtype.material_size
			local droppedItems = {}
			while materialToDrop > 0 do
				local dropSize = math.min(highestBrokenSubtypeId, materialToDrop)
				if brokenSubtypeIds[dropSize] then
					materialToDrop = materialToDrop - dropSize
					droppedItems[#droppedItems+1] = brokenSubtypeIds[dropSize]
				else
					-- Shouldn't happen
					dfhack.printerr("Could not find correctly-sized broken tool items to break tool of size " .. subtype.material_size .. " into")
					break -- Avoid infinite loop
				end
			end
			for _, subtypeId in ipairs(droppedItems) do
				dfhack.items.createItem(df.item_type.TOOL, subtypeId, matinfo.type, matinfo.index, worker)
				-- TODO: Remove maker etc?
			end
		end

		-- Announce
		local text = "A tool has broken from use."
		dfhack.gui.showZoomAnnouncement(-1, xyz2pos(dfhack.units.getPosition(worker)), text, COLOR_GREY, 0)
		local announcements = df.global.world.status.announcements
		local announcement = announcements[#announcements - 1]
		if not announcement or announcement.text ~= text then
			-- ???
			return
		end
		announcement.zoom_type = df.report_zoom_type.Unit
	end
end

local function getWeaponSkill(item)
	if item._type ~= df.item_weaponst then
		return nil
	end
	return item.subtype.skill_melee
end

local function onJobCompleted(job)
	local jobTypeString = df.job_type[job.job_type]
	local jobWearFactor = config.jobWearMultipliers[jobTypeString]
	if not jobWearFactor then
		return
	end

	local requiredSkill = df.job_skill[jobTypeString == "FellTree" and "AXE" or "MINING"]

	local worker = dfhack.job.getWorker(job)
	local bodyPart = worker.body.weapon_bp
	for _, equip in ipairs(worker.inventory) do
		if equip.body_part_id == bodyPart and equip.mode == 1 then -- mode 1 is weapon
			local item = equip.item
			if
				getWeaponSkill(item) == requiredSkill and
				not item.flags.artifact
			then
				handleWear(worker, item, jobWearFactor)
				break
			end
		end
	end
end

function enable()
	getBrokenToolItemSubtypeIds() -- To print errors early
	eventful.onJobCompleted[consts.scriptKey] = onJobCompleted
	eventful.enableEvent(eventful.eventType.JOB_COMPLETED, 0)
	enabled = true
	loadConfig()
	print("tool-wear enabled")
end

function disable()
	eventful.onJobCompleted[consts.scriptKey] = nil
	enabled = false
	print("tool-wear disabled")
end

if dfhack_flags.enable then
	if dfhack_flags.enable_state then
		enable()
	else
		disable()
	end
else
	print(usage)
end
