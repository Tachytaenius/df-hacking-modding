--@ enable = true

-- all-food-rots

qerror("TODO: Instead of recalculating food from age, allow rot timer to slow and speed up. This would also fix loading in an old world and losing all your food.")

local repeatUtil = require("repeat-util")
local eventful = require("plugins.eventful")
local utils = require("utils")

local consts = {
	scriptKey = "all-food-rots",
	handledJobFlagKey = 30,
	repeatInterval = 100,
	rotTimeMultiplier = 50,
	desiredRotTimeTicksModded = 100800 * 2, -- 2 seasons

	-- Game's own values
	ticksPerAge = 10, -- Age increments after this many ticks
	ticksPerRot = 100, -- Rot is calculated after this many ticks
	rotThreshold = 200
}
-- Derived consts
-- Game's own values
consts.agePerRot = consts.ticksPerRot / consts.ticksPerAge
consts.rotPerAge = 1 / consts.agePerRot
consts.totalRotTimeTicks = consts.rotThreshold * consts.ticksPerRot -- Vanilla
-- The mod's
consts.rotMultiplier = consts.totalRotTimeTicks / consts.desiredRotTimeTicksModded

local validArgs = utils.invert({
	"status"
})

local args = utils.processArgs({...}, validArgs)

local function foodTimeRemaining(item)
	
end

local function handleJob(job)
	qerror("TODO")

	if job.job_type ~= df.job_type.Eat then
		return
	end

	if job.flags[consts.handledJobFlagKey] then
		return
	end

	job.flags[consts.handledJobFlagKey] = true

	local ref = dfhack.job.getGeneralRef(job, df.general_ref_type.BUILDING_USE_TARGET_1)
	if ref then
		-- Already picked a chair
		return
	end

	local unit = dfhack.job.getWorker(job)

	local item = qerror("TODO")
	if not item then
		return
	end

	local newItem = searchForHigherPriorityFood(item, xyz2pos(dfhack.units.getPosition(unit)))
	if not newItem then
		return
	end

	local newItemX, newItemY, newItemZ = dfhack.items.getPosition(newItem)

	unit.path.dest.x = newItemX
	unit.path.dest.y = newItemY
	unit.path.dest.z = newItemZ

	unit.path.path.x:resize(0)
	unit.path.path.y:resize(0)
	unit.path.path.z:resize(0)
end

local function manageRot()
	for _, vec in ipairs({
		"FOOD", -- Prepared meals
		"CHEESE",
		"PLANT_GROWTH",
		"PLANT",
		"EGG",
		"FISH_RAW",
		"FISH",
		"MEAT"
	}) do
		for _, item in ipairs(df.global.world.items.other[vec]) do
			if item:materialRots() and not item.flags.rotten then -- If rotten, the game will rot it normally even if within a stockpile
				local rot = math.floor(item.age * consts.rotPerAge * consts.rotMultiplier)
				item:setRotTimer(rot)
				if rot >= consts.rotThreshold then
					item.flags.rotten = true
					item:setRotTimer(0)
					item:uncategorize()
					item:categorize(true)
				end
			end
		end
	end
	-- TODO: Handle misc liquid if it rots, even though it doesn't have a rot timer
end

if args.status then
	print("all-food-rots is " .. (enabled and "enabled" or "disabled"))
	return
end

local function start()
	repeatUtil.scheduleEvery(consts.scriptKey, consts.repeatInterval, "ticks", manageRot)
	eventful.onJobInitiated[consts.scriptKey] = handleJob
	eventful.enableEvent(eventful.eventType.JOB_INITIATED, 0)
	enabled = true
	print("all-food-rots enabled")
end

local function stop()
	repeatUtil.cancel(consts.scriptKey)
	eventful.onJobInitiated[consts.scriptKey] = nil
	enabled = false
	print("all-food-rots disabled")
end

if dfhack_flags.enable then
	if dfhack_flags.enable_state then
		start()
	else
		stop()
	end
end
