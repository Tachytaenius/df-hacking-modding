-- Usage: make-artifact item unit
-- By Tachytaenius
-- item and unit can either be "selected" (to be what's in the gui) or an id number.
-- item is the target item to turn into an artifact.
-- unit (optional) is (as well as another things) the unit + histfig to be set as "creator" on the created historical event. This is the name-giver; it's shown as "[artifact] received its name from [figure]" in legends mode. If unit is left out, it says "an unknown creature". And if the item is not given a name after elevation to artifact status, it will say "Untitled" for the name.
-- unit also gets a direct/family claim to the item. Entity claims are TODO
-- Also, wear doesn't reset on naming.

print("This script had an erroring print at the top guarding from use saying: \"Claims aren't implemented yet. I'll make it for v50 and backport :)\". I feel it is appropriate to be cautious about the state of this tool, since I kept coming back to it and forgetting what I had done and known beforehand.")

local args = {...}

local item
if args[1] == "selected" then
	item = dfhack.gui.getSelectedItem()
else -- item id
	local itemId = tonumber(args[1])
	if itemId then
		item = df.item.find(itemId)
	end
end
if not item then
	qerror("Need to supply an item.")
end

local unit
if args[2] == "selected" then
	unit = dfhack.gui.getSelectedUnit()
else -- unit id
	local unitId = tonumber(args[2])
	if unitId then
		unit = df.unit.find(unitId)
	end
end
if args[2] and not unit then
	qerror("Unit specified but no unit found.")
end

if item.flags.artifact then
	print("Item is already an artifact, aborting.")
	return
end

local artifactRecord = df.artifact_record:new()
artifactRecord.id = df.global.artifact_next_id
df.global.artifact_next_id = df.global.artifact_next_id + 1
-- Name unset
artifactRecord.item = item
artifactRecord.abs_tile_x = -1000000
artifactRecord.abs_tile_y = -1000000
artifactRecord.abs_tile_z = -1000000
artifactRecord.unk_1 = -1 -- last_global_bld_id
artifactRecord.name.type = df.language_name_type.Artifact
-- artifactRecord.name.language = -1 causes crashes. It should be set manually
-- Remaining default fields seem to match adventure mode naming result
df.global.world.artifacts.all:insert("#", artifactRecord)
-- print("Artifact record created.")

item.flags.artifact = true
local ref = df.general_ref_is_artifactst:new()
ref.artifact_id = artifactRecord.id
item.general_refs:insert("#", ref)
-- print("Item modified to be an artifact.")

local event = df.history_event_artifact_createdst:new()
event.year = df.global.cur_year
event.seconds = df.global.cur_year_tick
event.id = df.global.hist_event_next_id
df.global.hist_event_next_id = df.global.hist_event_next_id + 1
event.artifact_id = artifactRecord.id
if unit then
	if not unit.hist_figure_id then
		dfhack.printerr("Won't set creator data on creation event because unit has no historical figure id, I doubt that's good for the event.")
	else
		event.creator_unit_id = unit.id
		event.creator_hfid = unit.hist_figure_id
		-- print("Set creator data on creation event.")
	end
else
	-- print("No unit; left creator data unset on creation event.")
end
event.flags2.name_only = true
df.global.world.history.events:insert("#", event)
-- print("name_only artifact creation event created.")

if df.global.gamemode == df.game_mode.DWARF then
	event.site = df.global.ui.site_id
	-- Apparently site.artifacts isn't added to for named things like weapons with names bestowed
	-- No artifact claims made on site government or civilisation entity, either...
	if unit then
		if not unit.hist_figure_id then
			dfhack.printerr("Won't set direct/family claim on artifact record because unit has no historical figure id to use.")
		else
			artifactRecord.direct_claims:insert("#", unit.hist_figure_id)
			-- print("Set claim data on artifact.")
		end
	else
		-- print("No unit; left claim data unset on artifact record.")
	end
	print("Fort mode adjustments made. Save and reload to see the item in the artifacts list.")
else
	-- print("Not making fort mode adjustments.")
end

print("Done. Consider giving the item a name. The following command may help:")
print("gui/gm-editor df.artifact_record.find(" .. artifactRecord.id .. ").name")
print("The name is disabled (has_name is false), but type is set to Artifact and language id is set to 0 to avoid crashing due to invalid language, but you should set it to the id of your desired language. first_name allows for custom text")
