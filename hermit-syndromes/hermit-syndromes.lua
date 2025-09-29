--@module = true
--@enable = true

--[====[
hermit-syndromes
===========

Tags: gameplay | armok

Adds functionality to units with syndromes that come with this script

Usage
-----

	enable hermit-syndromes
	disable hermit-syndromes
]====]

-- This is all a *tiny* bit hacky, and could lead to quicker-than-intended increases in attribute values if you save and load repeatedly, I think?
-- Could be worth revisiting it to make it work across save and load better

-- Backported from 50.

local repeatUtil = require("repeat-util")

local GLOBAL_KEY = "hermit-syndromes"
local wait = 1000 -- Ticks
local attributeRecoveryPerTick = 1
local wrinklinessReductionPerTick = 1

enabled = enabled or false

function isEnabled()
	return enabled
end

local function findSyndrome(name)
	for _, syndrome in ipairs(df.global.world.raws.syndromes.all) do
		if syndrome.syn_name == name then
			return syndrome
		end
	end
end

local function unitHasSyndrome(unit, id)
	for _, syndrome in ipairs(unit.syndromes.active) do
		if syndrome.type == id then
			return syndrome
		end
	end
	return false
end

local function handleAttribute(name, attribute, caste, physical)
	local cap_perc = caste.attributes[physical and "phys_att_cap_perc" or "ment_att_cap_perc"][name]
	local average = caste.attributes[physical and "phys_att_range" or "ment_att_range"][name][3]

	-- cap = max(cap_perc / 100 * start, average + start)
	-- start is the inverse of this function. We use it as a minimum.
	-- This calculation was tested with an embark starting with 200 units and it worked for all of them
	local startPrediction = math.min(attribute.max_value / (cap_perc / 100), attribute.max_value - average)

	if attribute.value <= startPrediction then
		attribute.unused_counter = 0
		attribute.soft_demotion = 0
		attribute.rust_counter = 0
		attribute.demotion_counter = 0
		attribute.value = math.floor(math.min(startPrediction, attribute.value + wait * attributeRecoveryPerTick))
	end
end

local daysPerInterval = {
	DAILY = 1,
	WEEKLY = 7,
	MONTHLY = 28,
	YEARLY = 336
}

local function work()
	local noAgingSyn = findSyndrome("no aging")
	local noSkillRustSyn = findSyndrome("no skill rust")
	local physicalAttributesSyn = findSyndrome("physical attributes minimum")
	local mentalAttributesSyn = findSyndrome("mental attributes minimum")

	if not (noAgingSyn and noSkillRustSyn and physicalAttributesSyn and mentalAttributesSyn) then
		return
	end

	local noAgingSynId = noAgingSyn and noAgingSyn.id
	local noSkillRustSynId = noSkillRustSyn and noSkillRustSyn.id
	local physicalAttributesSynId = physicalAttributesSyn and physicalAttributesSyn.id
	local mentalAttributesSynId = mentalAttributesSyn and mentalAttributesSyn.id

	for _, unit in ipairs(df.global.world.units.all) do
		if dfhack.units.isActive(unit) then
			local caste = df.creature_raw.find(unit.race).caste[unit.caste]

			if unitHasSyndrome(unit, physicalAttributesSynId) then
				for name, attribute in pairs(unit.body.physical_attrs) do
					handleAttribute(name, attribute, caste, true)
				end
			end

			if unitHasSyndrome(unit, mentalAttributesSynId) then
				for name, attribute in pairs(unit.status.current_soul.mental_attrs) do
					handleAttribute(name, attribute, caste, false)
				end
			end

			local noAging = unitHasSyndrome(unit, noAgingSynId)
			if noAging then
				for modifierIndex, modifier in ipairs(caste.bp_appearance.modifiers) do
					-- local modifier = modifier.modifier -- Not needed in 47
					if modifier.type == df.appearance_modifier_type.WRINKLY and modifier.noun == "skin" then -- There's probably more we can check
						-- Predict wrinkliness at time of no aging start
						-- Some testing was done, and it passed for vanilla wrinkliness tokens, but it may well fail for particularly different uses of the APP_MOD_RATE token
						local birthTimeTicks = unit.birth_year * 403200 + unit.birth_time
						local noAgingStartTicks = noAging.year * 403200 + noAging.year_time
						local noAgingAgeTicks = noAgingStartTicks - birthTimeTicks
						local noAgingAgeDays = noAgingAgeTicks / 1200
						local daysSinceStart = math.max(0, noAgingAgeDays - modifier.growth_start) -- Start of growth, not of syndrome
						local growthIntervalUnit = daysPerInterval[df.appearance_modifier_growth_interval[modifier.growth_interval]]
						local growth = daysSinceStart * modifier.growth_rate / growthIntervalUnit
						local prediction = math.max(modifier.growth_min, math.min(modifier.growth_max, growth)) -- I'm assuming growth max won't be less than growth min
						-- TODO: Use growth_end

						for searchIndex, modifierId in ipairs(caste.bp_appearance.modifier_idx) do
							if modifierId == modifierIndex then
								local currentValue = unit.appearance.bp_modifiers[searchIndex]

								if currentValue > prediction then
									unit.appearance.bp_modifiers[searchIndex] = math.floor(math.max(prediction, currentValue - wait * wrinklinessReductionPerTick))
								end
							end
						end
					end
				end
			end

			if unitHasSyndrome(unit, noSkillRustSynId) then
				for _, skill in ipairs(unit.status.current_soul.skills) do
					skill.unused_counter = 0
					skill.rusty = 0
					skill.rust_counter = 0
					skill.demotion_counter = 0
				end
			end
		end
	end
end

local function enable()
	repeatUtil.scheduleEvery(GLOBAL_KEY, wait, "ticks", work)
	enabled = true
	print("Hermit syndromes enabled")
end

local function disable()
	repeatUtil.cancel(GLOBAL_KEY)
	enabled = false
	print("Hermit syndromes disabled")
end

dfhack.onStateChange[GLOBAL_KEY] = function(stateChange)
	if stateChange == SC_MAP_UNLOADED then
		disable()
		dfhack.onStateChange[GLOBAL_KEY] = nil
		return
	end

	if stateChange ~= SC_MAP_LOADED then
		return
	end

	enable()
end

if dfhack_flags.module then
	return
end

if not dfhack_flags.enable then
	print(dfhack.script_help())
	print()
	print(("Hermit syndromes is currently %s"):format(enabled and "enabled" or "disabled"))
	return
end

if dfhack_flags.enable_state then
	enabled = true
	enable()
else
	enabled = false
	disable()
end
