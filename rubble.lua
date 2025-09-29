--@ enable = true

-- TODO: Convert to an installable mod like tool-wear or tachy-guns

local usage = [[
Usage
-----

enable rubble
disable rubble
]]

-- Encourages minecart use

-- TODO: Fewer blocks per boulder
-- TODO: Test edge cases for item dropping
-- TODO: Drop extra boulder if digging channels or carving ramps-- if one should be dropped. Also, do we let gravity do its thing or move it down ourselves? Test what the game does.
-- TODO: Specify that only layer materials are dropped, so no extra ore or gems are acquired

local eventful = require("plugins.eventful")
local repeatUtil = require("repeat-util")
local tileMaterialUtil = require("tile-material")

local consts = {
	scriptKey = "rubble",

	repeatInterval = 6,
	actionTimerAdd = 5, -- If this is greater than or equal to repeatInterval then units won't move
	dropSoilItems = true,

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

local function blockImpedesMotionAtTile(block, lx, ly)
	-- local rubbleEvent = searchForBlockEvent(block, df.block_square_event_material_spatterst, 0, -1, df.matter_state.Solid, consts.temperatureNone, consts.temperatureNone)
	-- if rubbleEvent and rubbleEvent.amount[lx][ly] > 0 then
	-- 	return true
	-- end

	if not block.occupancy[lx][ly].item then
		return false
	end
	for _, itemId in ipairs(block.items) do-- Does not contain hauled items
		local item = df.item.find(itemId)
		if item and item._type == df.item_boulderst then
			local ix, iy, iz = dfhack.items.getPosition(item)
			local ilx, ily = ix % 16, iy % 16
			if ilx == lx and ily == ly then
				return true
			end
		end
	end

	return false
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

-- TODO: Use proper timekeeping
local function rubbleSlowdown()
	local boulderCache = {}
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
		if boulderCache[x] and boulderCache[x][y] ~= nil then
			boulderPresent = boulderCache[x][y]
		else
			boulderPresent = blockImpedesMotionAtTile(block, x % 16, y % 16)
			boulderCache[x] = boulderCache[x] or {}
			boulderCache[x][y] = boulderPresent
		end

		if boulderPresent then
			-- TODO: Don't let talking be slowed down by sitting on a boulder lol
			dfhack.units.subtractGroupActionTimers(unit, -consts.actionTimerAdd, df.unit_action_type_group.All)
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

if dfhack_flags.enable then
	if dfhack_flags.enable_state then
		enable()
	else
		disable()
	end
else
	print(usage)
end
