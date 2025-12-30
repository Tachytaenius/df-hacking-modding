--@enable=true
--@module=true

-- site-load-detector
-- By Tachytaenius

-- Provides a way to tell if a site becomes active that was not active for any length of time, ignoring game save/load.
-- Useful if a script checks for changes the tick after they happen and should not be able to do so if a site is left for any length of time (a change might be detected that happened 10 years ago).

-- Place `enable site-load-detector` in onLoad.init (not in onMapLoad.init) or otherwise ensure that it runs on world load.
-- (Un)register callbacks by requiring with dfhack.reqscript and using unregisterCallback and registerNewCallback. Reregistering replaces.

-- As a module, isPosInSite is provided for convenience

-- Fortress mode and adventure mode are handled differently.

local repeatUtil = require("repeat-util")
local persistTable = require("persist-table")

local GLOBAL_KEY = "site-load-detector"

if enabled == nil then
	enabled = false
end

function isEnabled()
	return enabled
end

registeredCallbacks = registeredCallbacks or {}
onStateChangeAfterCallbacks = onStateChangeAfterCallbacks or {}
repeatTickAfterCallbacks = repeatTickAfterCallbacks or {}

function unregisterCallback(name)
	for i, callback in ipairs(registeredCallbacks) do
		if callback.name == name then
			table.remove(registeredCallbacks, i)
			return true
		end
	end
	return false
end

function registerNewCallback(name, func)
	unregisterCallback(name)
	table.insert(registeredCallbacks, {
		name = name,
		func = func
	})
end

function isPosInSite(site, x, y)
	local regionX = math.floor(x / 48) + df.global.world.map.region_x
	local regionY = math.floor(y / 48) + df.global.world.map.region_y

	if
		site.global_min_x <= regionX and regionX <= site.global_max_x and
		site.global_min_y <= regionY and regionY <= site.global_max_y
	then
		return true
	end
	return false
end

local function trigger(site)
	for _, callback in ipairs(registeredCallbacks) do
		local success, message = pcall(function() callback.func(site) end) -- Don't let one erroring function break the other registered functions from running
		if not success then
			dfhack.printerr("site-load-detector: site load callback \"" .. callback.name .. "\" errored with:\n" .. message)
		end
	end
end

local function checkNewFortress()
	-- NOTE: If you save and quit shortly after the fortress starts (doable if you have fpause in onMapLoad.init), this would trigger again after running without the logic around the saved info
	-- fortress_age (what on-new-fortress uses) goes up every 10 ticks, according to df-structures
	local site = df.global.ui.main.fortress_site
	if not (
		dfhack.world.isFortressMode() and
		site.created_year == df.global.cur_year and -- df-structures says that Bay 12 calls these "last visited", and it seems to be suitable. Also, even when forcing the 2 week game simulation not to happen and retiring instantly while paused, the game still seems to advance by one tick between embarks. This is good
		site.created_tick == df.global.cur_year_tick
	) then
		-- Can't be a new fortress, clear any saved info
		persistTable.GlobalTable.siteLoadDetectorNewFortressInfo = nil
		return false
	end
	-- Might be a new fortress, check for matching saved info
	if
		persistTable.GlobalTable.siteLoadDetectorNewFortressInfo and
		tonumber(persistTable.GlobalTable.siteLoadDetectorNewFortressInfo.siteId) == site.id and
		tonumber(persistTable.GlobalTable.siteLoadDetectorNewFortressInfo.siteLastVisitedYear) == df.global.cur_year and
		tonumber(persistTable.GlobalTable.siteLoadDetectorNewFortressInfo.siteLastVisitedYearTick) == df.global.cur_year_tick
	then
		-- Already seen this start. Don't clear the saved info in case we see it once again
		return false
	end
	-- New start, save it
	persistTable.GlobalTable.siteLoadDetectorNewFortressInfo = {}
	persistTable.GlobalTable.siteLoadDetectorNewFortressInfo.siteId = tostring(site.id)
	persistTable.GlobalTable.siteLoadDetectorNewFortressInfo.siteLastVisitedYear = tostring(site.created_year)
	persistTable.GlobalTable.siteLoadDetectorNewFortressInfo.siteLastVisitedYearTick = tostring(site.created_tick)
	return true
end

local function validGamestate()
	return dfhack.isWorldLoaded()
end

local function saveKnownActiveSites()
	persistTable.GlobalTable.siteLoadDetectorKnownActiveSites = {}
	for i, site in ipairs(df.global.world.world_data.active_site) do
		-- i starts at 0, not that it will matter here
		persistTable.GlobalTable.siteLoadDetectorKnownActiveSites[tostring(i)] = tostring(site.id)
	end
end

local function checkNewLoadedSites()
	local sitesPersistent = persistTable.GlobalTable.siteLoadDetectorKnownActiveSites
	local knownActiveSitesSet = {}
	for _, key in ipairs(sitesPersistent._children) do
		local id = sitesPersistent[key]
		knownActiveSitesSet[tonumber(id)] = true
	end

	for _, site in ipairs(df.global.world.world_data.active_site) do
		if not knownActiveSitesSet[site.id] then
			trigger(site)
		end
	end

	saveKnownActiveSites()
end

local function disable()
	if not enabled then
		print("site-load-detector already disabled, redisabling")
	end
	enabled = false
	registeredCallbacks = {}
	onStateChangeAfterCallbacks = {}
	repeatTickAfterCallbacks = {}
	repeatUtil.cancel(GLOBAL_KEY)
	dfhack.onStateChange[GLOBAL_KEY] = nil
	print("site-load-detector disabled")
end

local function runSubordinateOnTickRepeats()
	-- Fix issues with site-load-detector triggering callbacks too late on tick by causing it to trigger callbacks and then handle other scripts' tick repeats afterwards. The order of tick repeat calls can be made unreliable.
	for key, callback in pairs(repeatTickAfterCallbacks) do
		local success, message = pcall(function() callback() end) -- Don't let one erroring function break the other registered functions from running
		if not success then
			dfhack.printerr("site-load-detector: on tick callback \"" .. key .. "\" errored with:\n" .. message)
		end
	end
end

local function tick()
	if not validGamestate() then -- Won't check for not enabled because enable() schedules this function (which calls it) before setting enabled to true, in case of errors
		-- Shouldn't happen because of the state change callback
		disable()
		return
	end

	if dfhack.world.isFortressMode() then
		persistTable.GlobalTable.siteLoadDetectorKnownActiveSites = {}
		runSubordinateOnTickRepeats()
		return
	end
	if not persistTable.GlobalTable.siteLoadDetectorKnownActiveSites then
		persistTable.GlobalTable.siteLoadDetectorKnownActiveSites = {}
	end

	checkNewLoadedSites()

	runSubordinateOnTickRepeats()
end

local function enable()
	if not validGamestate() then
		print("Can't enable site-load-detector in this state")
		if enabled then
			-- Shouldn't happen
			disable()
		end
		return
	end

	if enabled then
		print("site-load-detector already enabled, doing nothing")
		return
	end

	dfhack.onStateChange[GLOBAL_KEY] = function(stateChange)
		if stateChange == SC_MAP_UNLOADED then
			repeatUtil.cancel(GLOBAL_KEY)
			-- assert(#df.global.world.world_data.active_site == 0, "Number of active sites is greater than 0 on map unload??") -- Does happen in fort mode
			if dfhack.isWorldLoaded() then
				persistTable.GlobalTable.siteLoadDetectorKnownActiveSites = {}
			end
		elseif stateChange == SC_MAP_LOADED then
			local isNewFortress = checkNewFortress()
			if isNewFortress then
				trigger(df.global.ui.main.fortress_site)
			end
			repeatUtil.scheduleEvery(GLOBAL_KEY, 1, "ticks", tick) -- tick will run upon being scheduled here. It will save the sites
		end

		-- Fix issues with site-load-detector triggering callbacks too late on map load by causing it to trigger callbacks and then handle other scripts' onStateChange afterwards. The order of onStateChange calls is unreliable.
		for key, callback in pairs(onStateChangeAfterCallbacks) do
			local success, message = pcall(function() callback(stateChange) end) -- Don't let one erroring function break the other registered functions from running
			if not success then
				dfhack.printerr("site-load-detector: state change callback \"" .. key .. "\" errored with:\n" .. message)
			end
		end

		if not validGamestate() then
			disable()
			return
		end
	end

	print("site-load-detector enabled")
	enabled = true
end

if dfhack_flags.module then
	return
end

if dfhack_flags.enable then
	if dfhack_flags.enable_state then
		if not validGamestate() then
			qerror("Can't enable site-load-detector without a world loaded")
		end
		enable()
	else
		disable()
	end
end
