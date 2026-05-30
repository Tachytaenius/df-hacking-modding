-- speak-demon-name
-- Make an appropriate unit speak the name of a demon in order to banish it or bind it to servitude. Works in fortress mode.
-- For DF v0.47.05
-- By Tachytaenius

local helpText =
	"Usage: `speak-demon-name <speakerUnitId> <demonUnitId> banish|servitude [<actionTimer>]`\n" ..
	"To find unit id, run `:lua !unit.id` with a unit selected.\n"

local args = {...}

if #args == 0 or args[1] == "help" then
	print(helpText)
	return
end

local function neatAssert(condition, text)
	if not condition then
		qerror(text)
	end
end

-- Get speaker unit and histfig
local speakerId = tonumber(args[1])
neatAssert(speakerId, "No speaker id specified or is not number literal")
local speaker = df.unit.find(speakerId)
neatAssert(speaker, "No speaker unit found with given id")
local speakerHistfig = df.historical_figure.find(speaker.hist_figure_id)
neatAssert(speakerHistfig, "Speaker unit is not a historical figure; it cannot know the true name")

-- Get demon unit and histfig
local demonId = tonumber(args[2])
neatAssert(demonId, "No demon id specified or is not number literal")
local demon = df.unit.find(demonId)
neatAssert(demon, "No demon unit found with given id")
local demonHistfig = df.historical_figure.find(demon.hist_figure_id)
neatAssert(demonHistfig, "Demon unit is not a historical figure; it cannot have a true name")

-- Get intent
local intent = args[3]
neatAssert(intent == "banish" or intent == "servitude", "Intent must be banish or servitude")

local timerLength
if args[4] then
	timerLength = tonumber(args[4])
	neatAssert(timerLength, "Timer length is invalid")
else
	timerLength = 10
end

-- Get/check demon true name identity
-- TODO: Can demon hear?, and is that necessary in the vanilla path?
neatAssert(demonHistfig.info and demonHistfig.info.reputation, "Not enough info on demon historical figure to have a true name")
local identityFlagsNumber = demonHistfig.info.reputation.next_identity_idx -- Wrongly named field
local hasTrueName = identityFlagsNumber % 2 == 1 -- Bit 0 is have_true_name
neatAssert(hasTrueName, "Demon does not have a true name to be revealed")
local identityId
for _, potentialIdentityId in ipairs(demonHistfig.info.reputation.all_identities) do
	local identity = df.identity.find(potentialIdentityId)
	if
		identity and
		identity.type == df.identity_type.TrueName and
		identity.histfig_id == demon.hist_figure_id
	then
		identityId = potentialIdentityId
		break
	end
end
neatAssert(identityId, "Could not find true name identity of demon")

-- Check that speaker knows identity
-- TODO: Can speaker speak?
neatAssert(speakerHistfig.info and speakerHistfig.info.known_info, "Not enough info on speaker historical figure to know the demon's true name")
local speakerKnows = false
for _, potentialIdentityId in ipairs(speakerHistfig.info.known_info.known_identities) do
	if potentialIdentityId == identityId then
		speakerKnows = true
		break
	end
end
neatAssert(speakerKnows, "Speaker does not know the demon's true name")

-- Now ready to make the data

-- Make and setup a new activity for the brief exchange
local activity = df.activity_entry:new()
activity.id = df.global.activity_next_id -- Not incremented in df.global until after successful insertion
activity.type = df.activity_entry_type.Conversation
local event = df.activity_event_conversationst:new()
event.activity_id = activity.id
event.event_id = activity.next_event_id
event.participants:insert("#", {new = true,
	unit_id = speaker.id,
	histfig_id = speaker.hist_figure_id
})
event.participants:insert("#", {new = true,
	unit_id = demon.id,
	histfig_id = demon.hist_figure_id
})
local activityEventIndex = #activity.events
activity.events:insert("#", event)
activity.next_event_id = activity.next_event_id + 1

-- Make and setup action. Probably best to use a new action in case any data is set wrong in a way that the game will use
local action = df.unit_action:new()
action.type = df.unit_action_type.Talk
action.id = speaker.next_action_id -- Not incremented on the speaker until after successful insertion
local data = action.data.talk
data.activity_id = activity.id
data.activity_event_idx = activityEventIndex
data.unk_0 = df.talk_choice_type[
	intent == "banish" and "InvokeNameBanish" or
	intent == "servitude" and "InvokeNameService"
]
data.timer = timerLength
data.unk_3c = demon.id
data.unk_40 = demon.hist_figure_id
data.unk_44 = 10000 -- Volume (as observed in adventure mode)
data.unk_48 = -1 -- Tact type
data.unk_4c = 0 -- Tact roll
data.unk_50 = demon.hist_figure_id -- "Conversation variable 1", historical figure id to be named
data.unk_54 = identityId -- "Conversation variable 2", identity to be revealed

-- Insert the data into the game
speaker.next_action_id = speaker.next_action_id + 1
df.global.activity_next_id = df.global.activity_next_id + 1
speaker.actions:insert("#", action)
df.global.world.activities.all:insert("#", activity)

-- Result print :)
local speakerName = dfhack.units.getVisibleName(speaker)
local demonName = dfhack.units.getVisibleName(demon)
local speakerString = speakerName and dfhack.TranslateName(speakerName) or "An unknown creature"
local demonString = demonName and dfhack.TranslateName(demonName) or "an unknown creature"
local demonPronoun = df.pronoun_type[demon.sex] -- We should at least respect the demon's pronouns :3
local speakerIntent =
	intent == "banish" and "cause " .. demonPronoun .. " to vanish" or
	intent == "servitude" and "bind " .. demonPronoun .. " into servitude"
local text =
	speakerString .. " is now speaking the true name of " .. demonString .. " to " .. speakerIntent .. ". Speak action timer is " .. timerLength .. "."

print(text)
