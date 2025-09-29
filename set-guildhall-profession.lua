-- set-guildhall-profession
-- By Tachytaenius

local args = {...}
local professionName = args[1]
if not professionName then
	qerror("Must supply profession name")
end
local professionId = df.profession[professionName]
if not professionId then
	qerror("Unrecognised profession " .. professionName .. ". Get list with `:lua @df.profession`")
end

local screen = dfhack.gui.getCurViewscreen()
if screen._type ~= df.viewscreen_locationsst then
	qerror("Not in the locations menu")
end

local location = screen.locations[screen.location_idx]
if location._type ~= df.abstract_building_guildhallst then
	qerror("Selected location is not a guildhall")
end

location.contents.profession = professionId
print("Guildhall profession changed to " .. professionName)
