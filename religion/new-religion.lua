local utils = require("utils")

local args = utils.processArgs({...}, utils.invert({
	"histfigSelection",
	"deityId",
	"religionName",
	"civId",
	"groupId",
	"siteId",
	"makePriestPosition",
	"makeHighPriestPosition"
}))

local histfigsToAdd = {}
if type(args.histfigSelection) == "table" then
	for _, histfigId in ipairs(args.histfigSelection) do
		histfigsToAdd[#histfigsToAdd+1] = df.historical_figure.find(histfigId)
	end
elseif tonumber(args.histfigSelection) then
	histfigsToAdd[#histfigsToAdd+1] = df.historical_figure.find(args.histfigSelection)
elseif args.histfigSelection == "fort" then
	for _, unit in ipairs(df.global.world.units.active) do
		if dfhack.units.isCitizen(unit) then
			histfigsToAdd[#histfigsToAdd+1] = df.historical_figure.find(unit.hist_figure_id)
		end
	end
end

local civId = args.civId == "fort" and df.global.ui.civ_id or args.civId
local civ = df.historical_entity.find(civId)
local govId = args.groupId == "fort" and df.global.ui.group_id or args.groupId
local gov = df.historical_entity.find(govId)
local siteId = args.siteId == "fort" and df.global.ui.site_id or args.siteId
local site = df.world_site.find(siteId)
local religionId = df.global.entity_next_id
local religion = df.historical_entity:new()
df.global.world.entities.all:insert("#", religion)
df.global.entity_next_id = df.global.entity_next_id + 1
religion.id = religionId
religion.save_file_id = df.global.unit_chunk_next_id
df.global.unit_chunk_next_id = df.global.unit_chunk_next_id + 1

religion.type = df.historical_entity_type.Religion
religion.entity_raw = gov.entity_raw

religion.name.has_name = true
religion.name.first_name = args.religionName

religion.race = gov.race
religion.flags.unk3 = true -- Discovered

religion.entity_links:insert("#", {new = true, type = df.entity_entity_link_type.PARENT, target = civId, strength = 100})
civ.entity_links:insert("#", {new = true, type = df.entity_entity_link_type.CHILD, target = religionId, strength = 100})

local link = df.entity_site_link:new()
link.target = siteId
link.entity_id = religionId
link.type = df.entity_site_link_type.Local_Activity
link.flags.residence = true
link.flags.base_of_operation = true
link.link_strength = 100
link.target_site_x = site.pos.x
link.target_site_y = site.pos.y
religion.site_links:insert("#", link)
local siteLink = utils.clone(link, true)
siteLink.new = true
site.entity_links:insert("#", siteLink)

for _, histfig in ipairs(histfigsToAdd) do
	religion.histfig_ids:insert("#", histfig.id)
	religion.hist_figures:insert("#", histfig)

	local nemesis = df.nemesis_record.find(histfig.nemesis_id)
	-- if nemesis then
		religion.nemesis_ids:insert("#", histfig.nemesis_id)
		religion.nemesis:insert("#", nemesis)
	-- end

	histfig.entity_links:insert("#", {new = df.histfig_entity_link_memberst, entity_id = religionId, link_strength = 100})
end

local deityId
if args.deityId == "firstHistfig" then
	for _, link in ipairs(histfigsToAdd[1].histfig_links) do
		if link._type == df.histfig_hf_link_deityst then
			deityId = link.target_hf
		end
	end
else
	deityId = args.deityId
end
religion.relations.deities:insert("#", deityId)
religion.relations.worship:insert("#", 1000000)

religion.founding_site_government = govId

local function fix(t)
	t.resize = false
	local len = #t
	for i = 1, len do
		t[i - 1] = t[i]
	end
	t[len] = nil
end
local clonedResources = utils.clone(gov.resources, true)
fix(clonedResources.ethic)
fix(clonedResources.values)
fix(clonedResources.permitted_skill)
clonedResources.unk13 = nil
religion.resources = clonedResources
for _, field in ipairs({
	"derived_resources",
	"performed_poetic_forms",
	"performed_musical_forms",
	"performed_dance_forms"
}) do
	religion[field] = utils.clone(gov[field], true)
end
religion.unknown2.weapon_proficiencies = utils.clone(gov.unknown2.weapon_proficiencies, true)

if args.makePriestPosition then
	religion.positions.own:insert("#", {new = true,
		code = "PRIEST",
		id = religion.positions.next_position_id,
		flags = {resize = false,
			IS_LAW_MAKER = false,
			ELECTED = true,
			DUTY_BOUND = true,
			MILITARY_SCREEN_ONLY = false,
			GENDER_MALE = false,
			GENDER_FEMALE = false,
			SUCCESSION_BY_HEIR = false,
			HAS_RESPONSIBILITIES = true,
			FLASHES = false,
			BRAG_ON_KILL = false,
			CHAT_WORTHY = true,
			DO_NOT_CULL = true,
			KILL_QUEST = false,
			IS_LEADER = true,
			IS_DIPLOMAT = true,
			EXPORTED_IN_LEGENDS = false,
			DETERMINES_COIN_DESIGN = false,
			ACCOUNT_EXEMPT = true,
			unk_12 = true,
			unk_13 = false,
			COLOR = false,
			RULES_FROM_LOCATION = true,
			MENIAL_WORK_EXEMPTION = true,
			MENIAL_WORK_EXEMPTION_SPOUSE = false,
			SLEEP_PRETENSION = false,
			PUNISHMENT_EXEMPTION = true,
			unk_1a = true,
			unk_1b = true,
			QUEST_GIVER = false,
			SPECIAL_BURIAL = false,
			REQUIRES_MARKET = false,
			unk_1f = true
		},
		name = {resize = false,
			[0] = "priest",
			"priests"
		},
		responsibilities = {resize = false,
			RELIGION = true
		}
	})
	religion.positions.next_position_id = religion.positions.next_position_id + 1
end

if args.makeHighPriestPosition then
	religion.positions.own:insert("#", {new = true,
		code = "HIGH_PRIEST",
		id = religion.positions.next_position_id,
		flags = {resize = false,
			IS_LAW_MAKER = true,
			ELECTED = true,
			DUTY_BOUND = true,
			MILITARY_SCREEN_ONLY = false,
			GENDER_MALE = false,
			GENDER_FEMALE = false,
			SUCCESSION_BY_HEIR = false,
			HAS_RESPONSIBILITIES = true,
			FLASHES = true,
			BRAG_ON_KILL = true,
			CHAT_WORTHY = true,
			DO_NOT_CULL = true,
			KILL_QUEST = true,
			IS_LEADER = true,
			IS_DIPLOMAT = true,
			EXPORTED_IN_LEGENDS = true,
			DETERMINES_COIN_DESIGN = true,
			ACCOUNT_EXEMPT = true,
			unk_12 = true,
			unk_13 = false,
			COLOR = false,
			RULES_FROM_LOCATION = true,
			MENIAL_WORK_EXEMPTION = true,
			MENIAL_WORK_EXEMPTION_SPOUSE = false,
			SLEEP_PRETENSION = false,
			PUNISHMENT_EXEMPTION = true,
			unk_1a = true,
			unk_1b = true,
			QUEST_GIVER = true,
			SPECIAL_BURIAL = true,
			REQUIRES_MARKET = false,
			unk_1f = true
		},
		name = {resize = false,
			[0] = "high priest",
			"high priests"
		},
		responsibilities = {resize = false,
			RELIGION = true
		}
	})
	religion.positions.next_position_id = religion.positions.next_position_id + 1
end

religion.children:insert("#", religionId)
