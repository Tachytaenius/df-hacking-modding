--@ enable = true

-- religious-conversion
-- Allows units outside of a religion hearing religious sermons to be converted to those religions

local repeatUtil = require("repeat-util")
local utils = require("utils")

local consts = {
	scriptKey = "religious-conversion",
	repeatInterval = 40,
	chance = 0.004 -- Per histfig per repeat
}

local validArgs = utils.invert({
	"status"
})

local args = utils.processArgs({...}, validArgs)

local function convert(figure, religion)
	-- TODO: History events

	local nemesis = df.nemesis_record.find(figure.nemesis_id)

	if not nemesis then
		dfhack.printerr("religious-conversion: Histfig " .. figure.id .. " does not have a nemesis record, not sure what to do. Skipping conversion")
		return
	end

	religion.histfig_ids:insert("#", figure.id)
	religion.hist_figures:insert("#", figure)

	religion.nemesis_ids:insert("#", figure.nemesis_id)
	religion.nemesis:insert("#", nemesis)

	figure.entity_links:insert("#", {new = df.histfig_entity_link_memberst, entity_id = religion.id, link_strength = 100})
end

local function getReligion(figure) -- Assume only one
	for _, link in ipairs(figure.entity_links) do
		if link._type == df.histfig_entity_link_memberst then
			local entity = df.historical_entity.find(link.entity_id)
			if entity and entity.type == df.historical_entity_type.Religion then
				return entity
			end
		end
	end
end

local function isConvertable(figure)
	return not getReligion(figure)
end

local function onTick()
	for _, activity in ipairs(df.global.world.activities.all) do
		if activity.type ~= df.activity_entry_type.Prayer then
			goto continue
		end

		for _, event in ipairs(activity.events) do
			if event._type ~= df.activity_event_performancest then
				goto continue
			end

			local eventTypeName = df.performance_event_type[event.type]
			if not (
				eventTypeName == "SERMON_EVENT" or
				eventTypeName == "SERMON_SPHERE" or
				eventTypeName == "SERMON_PROMOTE_VALUE" or
				eventTypeName == "SERMON_INVEIGH_AGAINST_VALUE"
			) then
				goto continue
			end
			if event.flags.dismissed then -- Presumably would mean it's over
				goto continue
			end

			local religion
			for _, action in ipairs(event.participant_actions) do
				if action.type == 6 then -- df.performance_participant_type.PREACHER
					local figure = df.historical_figure.find(action.histfig_id)
					if figure then
						religion = getReligion(figure)
						break
					end
				end
			end

			if not religion then
				goto continue
			end

			for _, action in ipairs(event.participant_actions) do
				if not (action.type == df.performance_participant_type.LISTEN or action.type == df.performance_participant_type.HEAR) then
					goto continue
				end

				local process = rng:drandom() < consts.chance
				if not process then
					goto continue
				end

				local figure = df.historical_figure.find(action.histfig_id)
				local unit = df.unit.find(action.unit_id)
				if figure and unit and isConvertable(figure) then
					convert(figure, religion)

					local figureName = dfhack.TranslateName(figure.name)
					local religionName = dfhack.TranslateName(religion.name, true)
					local text = figureName .. " has converted to " .. religionName .. "."

					dfhack.gui.showZoomAnnouncement(-1, xyz2pos(dfhack.units.getPosition(unit)), text, COLOR_CYAN, 1)
					local announcements = df.global.world.status.announcements
					local announcement = announcements[#announcements - 1]
					if not announcement or announcement.text ~= text then
						dfhack.printerr("Could not find religion conversion announcement that was just made...?")
					else
						announcement.zoom_type = df.report_zoom_type.Unit
					end
				end
			    ::continue::
			end
		    ::continue::
		end
	    ::continue::
	end
end

if args.status then
	print("religious-conversion is " .. (enabled and "enabled" or "disabled"))
	return
end

local function start()
	if not rng then
		rng = dfhack.random.new()
		rng:init()
	end
	repeatUtil.scheduleEvery(consts.scriptKey, consts.repeatInterval, "ticks", onTick)
	enabled = true
	print("religious-conversion enabled")
end

local function stop()
	repeatUtil.cancel(consts.scriptKey)
	eventful.onJobInitiated[consts.scriptKey] = nil
	enabled = false
	print("religious-conversion disabled")
end

if dfhack_flags.enable then
	if dfhack_flags.enable_state then
		start()
	else
		stop()
	end
end
