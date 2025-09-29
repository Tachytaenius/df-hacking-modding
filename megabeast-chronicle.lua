local args = {...}
local contentId = tonumber(args[1])
local deityId = tonumber(args[2])

local content = df.written_content.find(contentId)

local function isMegabeast(histfigId)
	local histfig = df.historical_figure.find(histfigId)
	if histfig.race == -1 then
		return false
	end
	local flags = df.creature_raw.find(histfig.race).caste[histfig.caste].flags
	return flags.MEGABEAST or flags.SEMIMEGABEAST or flags.TITAN or flags.FEATURE_BEAST
end

local events = {}
for _, event in ipairs(df.global.world.history.events_death) do
	if isMegabeast(event.victim_hf) then
		events[#events + 1] = event.id
	end
end

content.refs:resize(0)
content.ref_aux:resize(0)

local function newRef(ref, aux)
	content.refs:insert("#", ref)
	content.ref_aux:insert("#", aux)
end

for _, sphereName in ipairs({"LOVE", "PEACE", "WISDOM", "VALOR"}) do
	local ref = df.general_ref_spherest:new()
	ref.sphere_type = df.sphere_type[sphereName]
	newRef(ref, 0)
end

local ref = df.general_ref_historical_figurest:new()
ref.hist_figure_id = deityId
newRef(ref, 6)

for _, eventId in ipairs(events) do
	local eventRef = df.general_ref_historical_eventst:new()
	eventRef.event_id = eventId
	newRef(eventRef, 5)
end
