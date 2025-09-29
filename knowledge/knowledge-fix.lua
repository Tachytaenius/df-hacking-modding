-- knowledge-fix
-- By Tachytaenius

-- I had a hermit save where a hermit was working on discovering every single topic in the game.
-- She stopped at 310/312 topics learned-- Research! instead of Ponder [remaining topic]!
-- The topics (at least in my case) are philosophy's philosophy_logic_propositional_logic and engineering2's engineering_design_models_and_templates.
-- This script forces your hermit (currently selected unit) to ponder those two remaining topics by unlearning an already-known topic, causing the hermit to ponder it,
-- and then switching the pondering to be about the actual topic (also relearning the unlearned topic).
-- To start the script, run (while your hermit is selected): knowledge-fix start [name of topic to unlearn to trigger pondering] [name of topic to try to learn]
-- and allow research to happen. An example topic to unlearn is engineering_machine_trip_hammer.
-- To stop it, just run knowledge-fix.
-- You should set breakthrough announcements to pause and stop this script once a discovery happens. Otherwise they continue pondering the broken topic after discovering it.
-- To do this temporarily, run:
-- gui/gm-editor df.global.d_init.announcements.flags.RESEARCH_BREAKTHROUGH
-- and set DO_MEGA, PAUSE, and RECENTER to true.
-- This script is hacky and focused on a specific case, so be sure to use it right.

local repeatUtil = require("repeat-util")
local repeatName = "knowledgeFix"

local start = select(1, ...) == "start"
if not start then
	repeatUtil.cancel(repeatName)
	print("Cancelling")
	return
end

local knowledgeCategories = { -- Indices here start at 1 but should start at 0 for DF
	"philosophy", "philosophy2",
	"math", "math2",
	"history",
	"astronomy",
	"naturalist",
	"chemistry",
	"geography",
	"medicine", "medicine2", "medicine3",
	"engineering", "engineering2"
}
local function getTopicInfo(knowledgeName) -- Given topic name, returns knowledge category name, knowledge category id, and topic id within category
	for luaCategoryIndex, categoryName in ipairs(knowledgeCategories) do
		local categoryIndex = luaCategoryIndex - 1
		local bitfieldType = df["knowledge_scholar_flags_" .. categoryIndex]
		for topicIndex, topicName in ipairs(bitfieldType) do
			if topicName == knowledgeName then
				return categoryName, categoryIndex, topicIndex
			end
		end
	end
	error("Couldn't find this topic")
end

local unlearnTopicName = select(2, ...) -- Anything of the working ones they've already learned
local learnTopicName = select(3, ...) -- philosophy_logic_propositional_logic or engineering_design_models_and_templates

local unlearnCategoryName, unlearnCategoryId, unlearnTopicId = getTopicInfo(unlearnTopicName)
local learnCategoryName, learnCategoryId, learnTopicId = getTopicInfo(learnTopicName)

local unit = dfhack.gui.getSelectedUnit()
local figure = df.historical_figure.find(unit.hist_figure_id)
local knowledge = figure.info.known_info.knowledge

local function tickFunction()
	-- Make sure research is going okay (temporary?)
	knowledge.knowledge_goal_category = learnCategoryId
	knowledge.unk_1 = learnCategoryId
	knowledge.unk_2 = learnCategoryId
	knowledge.unk_3 = learnCategoryId
	for i in ipairs(knowledge.knowledge_goal) do
		knowledge.knowledge_goal[i] = false
	end
	knowledge.knowledge_goal[learnTopicId] = true
	knowledge.research_points = 100000
	knowledge.times_pondered = 100

	if #unit.social_activities == 0 then
		return
	end

	local activity = df.activity_entry.find(unit.social_activities[0])
	if activity.type ~= df.activity_entry_type.Research then
		return
	end

	local ponderEvent
	for _, event in ipairs(activity.events) do
		if event._type == df.activity_event_ponder_topicst then
			ponderEvent = event
			break
		end
	end

	if not ponderEvent then
		-- Unlearn a topic so that the hermit starts pondering it
		-- We relearn it after and switch the pondering's topic to the topic we actually want to learn
		knowledge[unlearnCategoryName][unlearnTopicName] = false
		return
	end

	-- We've managed to create a ponder event previously, so if we're currently still on the unlearned topic, unset it from the unlearned topic and set it to the learned topic
	if ponderEvent.knowledge.flag_type == unlearnCategoryId and ponderEvent.knowledge.flag_data["flags_" .. unlearnCategoryId][unlearnTopicName] then
		-- Unset unlearned
		ponderEvent.knowledge.flag_data["flags_" .. unlearnCategoryId][unlearnTopicName] = false
		-- Set learned
		ponderEvent.knowledge.flag_type = learnCategoryId
		ponderEvent.knowledge.flag_data["flags_" .. learnCategoryId][learnTopicName] = true

		-- And relearn the unlearned topic
		knowledge[unlearnCategoryName][unlearnTopicName] = true
	end
end

repeatUtil.scheduleEvery(repeatName, 1, "ticks", tickFunction)
