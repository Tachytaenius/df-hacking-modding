-- underworld-plants
-- For v0.47.05
-- By Tachytaenius

-- The plants plugin doesn't grow plants on bare mud, so neither does this script.
-- You have to wait for cave grass to reach your underworld mud (which it can,
-- it's just the trees and shrubs that don't reach the underworld).

local utils = require("utils")
local repeatUtil = require("repeat-util")
local customRawTokens = require("custom-raw-tokens")

local scriptKey = "underworld-plants"

local validArgs = utils.invert({
	"start",
	"stop",
	"status",
	"attemptDensity"
})

local args = utils.processArgs({...}, validArgs)

enabled = enabled or false

if not rng then
	rng = dfhack.random.new()
	rng:init()
end

local function weightedRandomChoice(choices, randomNumber)
	local weightSum = 0
	for _, choice in ipairs(choices) do
		weightSum = weightSum + choice.weight
	end
	local x = randomNumber * weightSum
	for _, choice in ipairs(choices) do
		if x < choice.weight then
			return choice.value
		end
		x = x - choice.weight
	end
	-- Return nil, I guess
end

-- Based on the plants plugin
local function canCreatePlant(x, y, z)
	local block = dfhack.maps.getTileBlock(x, y, z)
	local column = df.global.world.map.column_index[math.floor(x / 48) * 3][math.floor(y / 48) * 3]
	if not block or not column then
		return false
	end

	local lx, ly = x % 16, y % 16

	local designation = block.designation[lx][ly]
	if designation.flow_size ~= 0 then
		-- Can't spawn in liquids
		return false
	end
	local occupancy = block.occupancy[lx][ly]
	if
		occupancy.building ~= 0
		-- occupancy.no_grow ?
	then
		return false
	end

	local tiletype = block.tiletype[lx][ly]
	local tileAttrs = df.tiletype.attrs[tiletype]
	local matName = df.tiletype_material[tileAttrs.material]
	if
		tileAttrs.shape ~= df.tiletype_shape.FLOOR or
		(
			matName ~= "SOIL" and
			matName ~= "GRASS_DARK" and
			matName ~= "GRASS_LIGHT"
		)
	then
		return false
	end

	return true
end

local function createPlant(plantTypeId, x, y, z, disableCheck) -- disableCheck is good if you've already checked the tile
	if not disableCheck and not canCreatePlant(x, y, z) then
		return false
	end

	local raw = df.global.world.raws.plants.all[plantTypeId]
	if not raw then
		return false
	end
	if raw.flags.GRASS then
		return false
	end

	local plant = df.plant:new()
	if raw.flags.TREE then
		plant.hitpoints = 400000
	else
		plant.hitpoints = 100000
		plant.flags.is_shrub = true
	end

	-- The plants plugin's code sets the watery flag for
	-- WET-type plants even if they're spawned away from water.
	-- According to the code (for v47), the proper method is unclear.
	if raw.flags.WET then
		plant.flags.watery = true
	end
	plant.material = plantTypeId
	plant.pos.x = x
	plant.pos.y = y
	plant.pos.z = z
	plant.update_order = rng:random(10)

	local plants = df.global.world.plants
	plants.all:insert("#", plant)
	local vec =
		plant.flags.is_shrub and (
			plant.flags.watery and plants.shrub_wet or
			plants.shrub_dry
		) or (
			plant.flags.watery and plants.tree_wet or
			plants.tree_dry
		)
	vec:insert("#", plant)

	local block = dfhack.maps.getTileBlock(x, y, z)
	local column = df.global.world.map.column_index[math.floor(x / 48) * 3][math.floor(y / 48) * 3]
	column.plants:insert("#", plant)
	block.tiletype[x % 16][y % 16] = plant.flags.is_shrub and
		df.tiletype.Shrub or df.tiletype.Sapling

	return true
end

local function isBlockUnderworld(block)
	-- Any better way to do this?
	local region = df.world_underground_region.find(block.global_feature)
	if not region then
		return false
	end
	return region.type == df.world_underground_region.T_type.Underworld
end

local function getUnderworldPosition()
	local bw, bh, bd = dfhack.maps.getSize()
	local bx = rng:random(bw)
	local by = rng:random(bh)
	local underworldHeightHere
	for bz = 0, bd - 1 do
		local block = dfhack.maps.getBlock(bx, by, bz)
		if not (block and isBlockUnderworld(block)) then
			break
		end
		underworldHeightHere = bz
	end
	if not underworldHeightHere then
		return
	end

	local bz = rng:random(underworldHeightHere + 1)
	local lx = rng:random(16)
	local ly = rng:random(16)

	return bx * 16 + lx, by * 16 + ly, bz
end

local function getAttemptCount(average) -- Average can be a float! This function is uniform-ish. It returns numbers with the desired average
	local ret = rng:random(2 * math.floor(average) + 1) -- Integer within [0, 2 * floor(average)]
	if rng:drandom() < average % 1 then -- Use fractional part of average as a probability
		ret = ret + 1
	end
	return ret
end

local function getAvailablePlantChoices()
	local ret = {}
	local foundNames = {}
	for _, pop in ipairs(df.global.world.populations) do
		local typeName = df.world_population_type[pop.type]
		if typeName == "Tree" or typeName == "Bush" then
			local raw = df.plant_raw.find(pop.plant)
			local rawId = raw.id
			if underworldPlantsRaws[rawId] then
				-- Is this availability check correct?
				local available = pop.flags.discovered
				if not available then
					local cave = df.world_underground_region.find(pop.population.cave_id)
					available = cave and cave.feature_init.flags.Discovered
				end

				if not foundNames[rawId] then
					foundNames[rawId] = true
					ret[#ret+1] = underworldPlantsRaws[rawId]
				end
			end
		end
	end
	return ret
end

local function onTick()
	local tw, th, td = dfhack.maps.getSize()
	local area = tw * th
	local averageAttempts = attemptDensity * area
	local attemptCount = getAttemptCount(averageAttempts)
	local availablePlantChoices
	for _=1, attemptCount do
		local x, y, z = getUnderworldPosition()
		if not x then
			goto continue
		end

		if not canCreatePlant(x, y, z) then
			goto continue
		end

		availablePlantChoices = availablePlantChoices or getAvailablePlantChoices()

		local plantId = weightedRandomChoice(availablePlantChoices, rng:drandom())
		if not plantId then
			goto continue
		end

		createPlant(plantId, x, y, z, true)

	    ::continue::
	end
end

local function getUnderworldPlantsRaws()
	local ret = {}
	local foundAny = false
	for i, raw in ipairs(df.global.world.raws.plants.all) do
		-- Don't put the weight after a plant growth definition, otherwise custom-raw-tokens won't see it
		local weight = tonumber(customRawTokens.getToken(raw, "UNDERWORLD_PLANTS_WEIGHT"))
		if weight and weight > 0 then
			foundAny = true
			ret[raw.id] = { -- raw.id is a string
				value = i, -- For the weighted random function
				weight = weight
			}
		end
	end
	return ret, foundAny
end

if args.attemptDensity then
	-- Average number of attempts per world xy area. So that bigger worlds don't get less plant attempts per block
	attemptDensity = tonumber(args.attemptDensity)
end

if args.status then
	print("underworld-plants is " .. (enabled and "enabled" or "disabled"))
	print("attempt density is " .. (attemptDensity or "undefined"))
	return
end

if args.stop then
	repeatUtil.cancel(scriptKey)
	enabled = false
	print("underworld-plants disabled")
	return
end

if args.start then
	if not attemptDensity then
		qerror("Attempt density not set. It's the average amount of plant attempts per map tile area (not considering z). A sensible value is 5e-4, which is 0.0005")
	end
	underworldPlantsRaws, foundAny = getUnderworldPlantsRaws()
	repeatUtil.scheduleEvery(scriptKey, 1, "ticks", onTick)
	enabled = true
	print("underworld-plants enabled")
	if not foundAny then
		print("No underworld plants (with nonzero weight) found in raws. Specify custom raw token UNDERWORLD_PLANTS_WEIGHT on a plant (not after a growth definition) with a number argument, e.g. [UNDERWORLD_PLANTS_WEIGHT:100]")
	end
	return
end
