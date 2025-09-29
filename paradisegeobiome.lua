qerror("TODO: ADD KAOLINITE!!!!!!!!!!!!!!!!!!!!!!! Also do we have the right tin ore for glazing??")

local layers = df.global.world.world_data.geo_biomes[tonumber((...))].layers
local find = function(name)
	local info = dfhack.matinfo.find(name)
	return info.index
end
local function getMatPair(name)
	local info = find()
	return info.type, info.index
end
while #layers > 0 do
	layers:erase(0)
end
while #layers < 16 do
	layers:insert(0, {new = true})
end
local i = 0
local function vein(mat, nestedIn, type, proportion)
	mat2 = find(mat)
	layers[i].vein_mat:insert(#layers[i].vein_mat, mat2)
	layers[i].vein_nested_in:insert(#layers[i].vein_nested_in, nestedIn)
	layers[i].vein_type:insert(#layers[i].vein_type, type)
	layers[i].vein_unk_38:insert(#layers[i].vein_unk_38, proportion)
end

layers[i].type = 0
layers[i].mat_index = find("LOAM")
layers[i].top_height, layers[i].bottom_height = 0, 0
i = i + 1

layers[i].type = 0
layers[i].mat_index = find("CLAY")
layers[i].top_height, layers[i].bottom_height = layers[i-1].bottom_height - 1, -1
i = i + 1

layers[i].type = 0
layers[i].mat_index = find("FIRE_CLAY")
layers[i].top_height, layers[i].bottom_height = layers[i-1].bottom_height - 1, -2
i = i + 1

layers[i].type = 0
layers[i].mat_index = find("SAND_BLACK")
layers[i].top_height, layers[i].bottom_height = layers[i-1].bottom_height - 1, -3
i = i + 1

layers[i].type = 1
layers[i].mat_index = find("CHERT")
layers[i].top_height, layers[i].bottom_height = layers[i-1].bottom_height - 1, -4
i = i + 1

layers[i].type = 4
layers[i].mat_index = find("GRANITE")
layers[i].top_height, layers[i].bottom_height = layers[i-1].bottom_height - 1, -19
i = i + 1

layers[i].type = 1
layers[i].mat_index = find("CHALK")
layers[i].top_height, layers[i].bottom_height = layers[i-1].bottom_height - 1, -21
i = i + 1

layers[i].type = 2
layers[i].mat_index = find("SLATE")
layers[i].top_height, layers[i].bottom_height = layers[i-1].bottom_height - 1, -23
vein("CRYSTAL_ROCK", -1, 3, 50)
vein("SPHALERITE", -1, 1, 50)
vein("MOSS OPAL", -1, 3, 50)
vein("AMETHYST", -1, 3, 50)
i = i + 1

layers[i].type = 1
layers[i].mat_index = find("CHERT")
layers[i].top_height, layers[i].bottom_height = layers[i-1].bottom_height - 1, -31
vein("HEMATITE", -1, 1, 50)
vein("COAL_BITUMINOUS", -1, 1, 50)
vein("PETRIFIED_WOOD", -1, 1, 50)
vein("ROCK_SALT", -1, 3, 50)
vein("SALTPETER", -1, 3, 50)
vein("GYPSUM", -1, 2, 5)
vein("BAUXITE", -1, 2, 10)
vein("RUBY", 6, 3, 50)
vein("RUBY_STAR", 7, 4, 25)
vein("SAPPHIRE", 6, 3, 50)
vein("SAPPHIRE_STAR", 9, 4, 25)
i = i + 1

layers[i].type = 2
layers[i].mat_index = find("MARBLE")
layers[i].top_height, layers[i].bottom_height = layers[i-1].bottom_height - 1, -36
vein("MALACHITE", -1, 1, 50)
vein("EMERALD", -1, 3, 50)
vein("LAPIS LAZULI", -1, 3, 50)
vein("MOONSTONE", -1, 3, 50)
i = i + 1

layers[i].type = 2
layers[i].mat_index = find("GNEISS")
layers[i].top_height, layers[i].bottom_height = layers[i-1].bottom_height - 1, -40
vein("GALENA", -1, 1, 50)
vein("SUNSTONE", -1, 3, 50)
vein("ORTHOCLASE", -1, 2, 50)
i = i + 1

layers[i].type = 3
layers[i].mat_index = find("GRANITE")
layers[i].top_height, layers[i].bottom_height = layers[i-1].bottom_height - 1, -45
vein("NATIVE_SILVER", -1, 1, 50)
vein("BISMUTHINITE", -1, 3, 50)
vein("CASSITERITE", -1, 1, 50)
vein("RUTILE", -1, 1, 50)
vein("TOPAZ", -1, 3, 50)
i = i + 1

layers[i].type = 4
layers[i].mat_index = find("ANDESITE")
layers[i].top_height, layers[i].bottom_height = layers[i-1].bottom_height - 1, -50
vein("NATIVE_ALUMINUM", -1, 3, 50)
vein("MICROCLINE", -1, 2, 15)
vein("COBALTITE", -1, 1, 50)
i = i + 1

layers[i].type = 4
layers[i].mat_index = find("OBSIDIAN")
layers[i].top_height, layers[i].bottom_height = layers[i-1].bottom_height - 1, -55
vein("NATIVE_GOLD", -1, 1, 15)
vein("BRIMSTONE", -1, 3, 50)
vein("BONE OPAL", -1, 3, 50)
i = i + 1

layers[i].type = 3
layers[i].mat_index = find("GABBRO")
layers[i].top_height, layers[i].bottom_height = layers[i-1].bottom_height - 1, -65
vein("KIMBERLITE", -1, 1, 50)
vein("DIAMOND_LY", 0, 3, 40)
vein("DIAMOND_FY", 0, 3, 20)
vein("DIAMOND_CLEAR", 2, 4, 20)
vein("DIAMOND_RED", 2, 4, 10)
vein("DIAMOND_GREEN", 2, 4, 10)
vein("DIAMOND_BLUE", 2, 4, 20)
vein("DIAMOND_YELLOW", 2, 4, 10)
vein("DIAMOND_BLACK", 2, 4, 10)
vein("OLIVINE", -1, 2, 50)
vein("NATIVE_PLATINUM", 9, 1, 50)
vein("SERPENTINE", 9, 3, 50)
vein("CHROMITE", 9, 1, 50)
vein("DEMANTOID", 12, 3, 50)
vein("GARNIERITE", -1, 1, 50)
i = i + 1

layers[i].type = 3
layers[i].mat_index = find("BASALT")
layers[i].top_height, layers[i].bottom_height = layers[i-1].bottom_height - 1, -66
i = i + 1
