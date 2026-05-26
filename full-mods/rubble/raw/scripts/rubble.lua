--@ enable = true

local usage = [[
Usage
-----

enable rubble
disable rubble
rubble plugin-yes
rubble plugin-no
]]

-- Run `rubble plugin-yes` if the plugin (called rubblecompute) is installed. This is faster.

-- TODO: Fewer blocks per boulder
-- TODO: Only ever one layer stone boulder per tile mined
-- TODO: Make configurable
-- TODO: Test edge cases for item dropping (stairs?)
-- TODO: Drop extra boulder if digging channels or carving ramps-- if one should be dropped. Also, do we let gravity do its thing or move it down ourselves? Test what the game does.

local eventful = require("plugins.eventful")
local repeatUtil = require("repeat-util")
local tileMaterialUtil = require("tile-material")

local consts = {
	scriptKey = "rubble",

	repeatInterval = 6,
	actionTimerMultiply = 2.5,
	dropSoilItems = true,

	handledMoveActionFlagKey = 31, -- Applies to more action types than just Move, but the memory location of Move's flags is altered for all of them

	temperatureNone = 60001 -- Game's own value
}

-- Based on tileMaterialUtil.GetVeinMat
local function getClusterMat(x, y, z)
	local block = dfhack.maps.getTileBlock(x, y, z)
	if not block then
		return
	end

	local returnEvent
	for _, event in ipairs(block.block_events) do
		if
			event._type == df.block_square_event_mineralst and
			dfhack.maps.getTileAssignment(event.tile_bitmask, x, y) and
			event.flags.cluster
		then
			returnEvent = event
			-- Don't break since we want the last one if there are multiple
		end
	end

	if not returnEvent then
		return
	end

	return dfhack.matinfo.decode(0, returnEvent.inorganic_mat)
end

local function fallItem(item)
	local projectile = dfhack.items.makeProjectile(item)
	if not projectile then
		return
	end
	projectile.flags.no_impact_destroy = true
	projectile.flags.bouncing = true
	projectile.flags.piercing = true
	projectile.flags.parabolic = true
	projectile.flags.unk9 = true -- no_adv_pause
	projectile.flags.no_collide = true
end

local function getTileDigInfo(x, y, z) -- Returns item count, type pair, and material pair
	local tileType = dfhack.maps.getTileType(x, y, z)
	local typeAtrrs = df.tiletype.attrs[tileType]
	local tileMaterial = typeAtrrs.material
	local tileShape = typeAtrrs.shape

	local info = {}
	info.itemCount = 0
	info.itemType, info.itemSubtype = df.item_type.BOULDER, -1
	info.matType, info.matIndex = -1, -1

	if tileShape ~= df.tiletype_shape.WALL and tileShape ~= df.tiletype_shape.FORTIFICATION then
		return info
	end

	local tileMaterialName = df.tiletype_material[tileMaterial]

	if
		tileMaterialName == "STONE" or
		tileMaterialName == "MINERAL" or
		tileMaterialName == "FEATURE" or
		tileMaterialName == "LAVA_STONE" or
		(consts.dropSoilItems and tileMaterialName == "SOIL")
	then
		local matinfo =
			getClusterMat(x, y, z) or
			tileMaterialUtil.GetLayerMat(x, y, z)

		if
			tileMaterialName == "SOIL" or
			matinfo.inorganic and matinfo.inorganic.flags.SOIL_ANY
		then
			info.itemType = df.item_type.POWDER_MISC
		end
		info.matType, info.matIndex = matinfo.type, matinfo.index
		info.itemCount = 1
		if not info.matType then
			info.itemCount = 0
		end
	elseif tileMaterialName == "FROZEN_LIQUID" then
		-- Assume frozen water
		-- baseMaterialAtPos would return the riverbed material
		info.itemCount = 1
		info.matType, info.matIndex = df.builtin_mats.WATER, -1
	else
		return info
	end

	-- Unlike dig-now, we are ignoring ore deposits and placing boulders of the surroudning layer stone
	-- So we won't check for the material being a gem

	return info
end

local function getCachedTileDigInfo(x, y, z)
	return miningJobDropInfoCache[x] and miningJobDropInfoCache[x][y] and miningJobDropInfoCache[x][y][z]
end

local function searchForBlockEvent(block, eventType, matType, matIndex, state, minTemp, maxTemp)
	for i, event in ipairs(block.block_events) do
		if event._type ~= eventType then
			goto continue
		end
		if
			event.mat_type == matType and
			event.mat_index == matIndex and
			event.mat_state == state and
			event.min_temperature == minTemp and
			event.max_temperature == maxTemp
		then
			return event, i
		end
	    ::continue::
	end
end

local function addSpatter(matType, matIndex, state, amount, minTemp, maxTemp, x, y, z)
	local block = dfhack.maps.getTileBlock(x, y, z)
	if not block then
		return
	end

	local eventToAddTo = searchForBlockEvent(block, df.block_square_event_material_spatterst, matType, matIndex, state, minTemp, maxTemp)

	if not eventToAddTo then
		eventToAddTo = df.block_square_event_material_spatterst:new()
		eventToAddTo.mat_type, eventToAddTo.mat_index, eventToAddTo.mat_state, eventToAddTo.min_temperature, eventToAddTo.max_temperature = matType, matIndex, state, minTemp, maxTemp
		block.block_events:insert("#", eventToAddTo)
	end

	eventToAddTo.amount[x % 16][y % 16] = eventToAddTo.amount[x % 16][y % 16] + amount
end

local function spawnRubble(x, y, z, worker)
	local info = getCachedTileDigInfo(x, y, z)

	if not info then
		return
	end

	local itemCount = info.itemCount
	local itemType = info.itemType
	local itemSubtype = info.itemSubtype
	local matType = info.matType
	local matIndex = info.matIndex

	local tiletype = dfhack.maps.getTileType(x, y, z)
	local tileShapeAttrs = df.tiletype_shape.attrs[
		df.tiletype.attrs[tiletype].shape
	]

	for _=1, itemCount do
		local itemId = dfhack.items.createItem(itemType, itemSubtype, matType, matIndex, worker)
		if itemId then
			local item = df.item.find(itemId)
			dfhack.items.moveToGround(item, xyz2pos(x, y, z)) -- Was spawned at worker position
			if tileShapeAttrs.basic_shape == df.tiletype_shape_basic.Open then
				fallItem(item)
			end
		end
	end
end

local function isMiningJob(job)
	return df.job_type.attrs[job.job_type].type == df.job_type_class.Digging
end

local function processCompletedMiningJob(job)
	if not isMiningJob(job) then
		return
	end
	local x, y, z = pos2xyz(job.pos)
	local worker = dfhack.job.getWorker(job)
	if worker then
		spawnRubble(x, y, z, worker)
	end
end

local function getBoulderCacheValue(boulderCache, x, y, z)
	if not boulderCache[z] then
		return nil
	end
	if not boulderCache[z][x] then
		return nil
	end
	return boulderCache[z][x][y]
end
local function setBoulderCacheValue(boulderCache, x, y, z, value)
	if not boulderCache[z] then
		boulderCache[z] = {}
	end
	if not boulderCache[z][x] then
		boulderCache[z][x] = {}
	end
	boulderCache[z][x][y] = value
end
-- TODO: Use proper timekeeping
local function rubbleSlowdown()
	if usePlugin then
		dfhack.run_command("rubblecompute slowdown " .. consts.actionTimerMultiply)
		return
	end

	local boulderCache = {} -- [z][x][y] internally, helper functions are x, y, z
	local nextBlockItemIndexes = {}
	-- local totalItemSearches = 0
	for _, unit in ipairs(df.global.world.units.active) do
		local x, y, z = dfhack.units.getPosition(unit)
		if not (x and y and z) then
			goto continue
		end

		local block = dfhack.maps.getTileBlock(x, y, z)
		if not block then
			goto continue
		end

		local boulderPresent
		local cacheValue = getBoulderCacheValue(boulderCache, x, y, z)
		if cacheValue ~= nil then
			boulderPresent = cacheValue
		else
			local lx, ly = x % 16, y % 16
			if not block.occupancy[lx][ly].item then
				-- setBoulderCacheValue(boulderCache, x, y, z, false)
				boulderPresent = false
			else
				local itemIndex = nextBlockItemIndexes[block] or 0
				while itemIndex < #block.items do
					local itemId = block.items[itemIndex] -- Does not contain hauled items
					itemIndex = itemIndex + 1
					local item = df.item.find(itemId)
					-- totalItemSearches = totalItemSearches + 1
					if item and item._type == df.item_boulderst then
						local ix, iy, iz = dfhack.items.getPosition(item)
						setBoulderCacheValue(boulderCache, ix, iy, iz, true) -- If we find any boulders along the way to the stop position that aren't on the stop position, note their positions in the cache
						if ix == x and iy == y and iz == z then
							break
						end
					end
				end
				nextBlockItemIndexes[block] = itemIndex
				boulderPresent = getBoulderCacheValue(boulderCache, x, y, z)
				if boulderPresent == nil then
					-- Save a false if we got a nil, as we're sure the nil means there is no boulder here
					setBoulderCacheValue(boulderCache, x, y, z, false)
				end
			end
		end

		if boulderPresent then
			local multiplier = consts.actionTimerMultiply -- Doesn't have to be an integer. Should be more than 1.

			-- Notably, combat is not slowed down
			-- Affected action types: Move, and Job (but not Job2 (which is later renamed to JobRecover))
			-- Move is handled specially, since it has a useful timer_init variable
			-- All action types are converted to move to access the memory region of the flag bits (which should be unused in the other types)
			for _, action in ipairs(unit.actions) do
				local actionTypeName = df.unit_action_type[action.type]
				if actionTypeName == "Move" then
					-- TODO: Skip if flying
					if not action.data.move.flags[consts.handledMoveActionFlagKey] then
						local data = action.data.move
						data.flags[consts.handledMoveActionFlagKey] = true

						local timeUsed = data.timer_init - data.timer -- Only Move gives this information, making it more exact
						local newTimerInit = math.max(1, math.floor(data.timer_init * multiplier))
						local newTimer = math.max(1, newTimerInit - timeUsed)
						data.timer_init = newTimerInit
						data.timer = newTimer
					end
				elseif
					actionTypeName == "Job"
					-- And anything else
				then
					action.type = df.unit_action_type.Move
					if not action.data.move.flags[consts.handledMoveActionFlagKey] then
						action.data.move.flags[consts.handledMoveActionFlagKey] = true
						action.type = df.unit_action_type[actionTypeName] -- Revert
						local tag = df.unit_action_type.attrs[actionTypeName].tag
						local data = action.data[tag]

						data.timer = math.max(1, math.floor(data.timer * multiplier))
					else
						action.type = df.unit_action_type[actionTypeName] -- Revert
					end
				end
			end
		end

	    ::continue::
	end
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

local function recordMiningJobDropInfo(job)
	if not isMiningJob(job) then
		return
	end

	local x, y, z = pos2xyz(job.pos)

	miningJobDropInfoCache[x] = miningJobDropInfoCache[x] or {}
	miningJobDropInfoCache[x][y] = miningJobDropInfoCache[x][y] or {}
	miningJobDropInfoCache[x][y][z] = miningJobDropInfoCache[x][y][z] or getTileDigInfo(x, y, z)
end

-- TODO: Do NOT use proper timekeeping when the every-n-ticks function gets to; this must always have run before a tick completes and repeat running what it schedules is fine for that
-- It needs to know what tile a dig job was digging right before the dig job completed
local function everyTick()
	miningJobDropInfoCache = {}
	iterateJobs(recordMiningJobDropInfo)
end

function enable()
	repeatUtil.scheduleEvery(consts.scriptKey .. "_tiletype", 1, "ticks", everyTick)
	repeatUtil.scheduleEvery(consts.scriptKey .. "_slowdown", consts.repeatInterval, "ticks", rubbleSlowdown)
	eventful.onJobCompleted[consts.scriptKey] = processCompletedMiningJob
	eventful.enableEvent(eventful.eventType.JOB_COMPLETED, 0)
	enabled = true
	print("rubble enabled")
end

function disable()
	repeatUtil.cancel(consts.scriptKey .. "_tiletype")
	repeatUtil.cancel(consts.scriptKey .. "_slowdown")
	eventful.onJobCompleted[consts.scriptKey] = nil
	enabled = false
	print("rubble disabled")
end

local args = {...}
if dfhack_flags.enable then
	if dfhack_flags.enable_state then
		enable()
	else
		disable()
	end
elseif args[1] == "plugin-yes" then
	usePlugin = true
	print("rubblecompute plugin will be run if present (error if not)")
elseif args[1] == "plugin-no" then
	usePlugin = false
	print("rubblecompute plugin won't be run; rubble will run in Lua only")
else
	print(usage)
end
