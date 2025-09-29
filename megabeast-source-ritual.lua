-- megabeast-source-ritual
-- By Tachytaenius

qerror("TODO: Properly load art image")

local function isMegabeast(histfig)
	if histfig.race == -1 then
		return false
	end
	local flags = df.creature_raw.find(histfig.race).caste[histfig.caste].flags
	return flags.MEGABEAST or flags.SEMIMEGABEAST or flags.TITAN or flags.FEATURE_BEAST
end

local function isDead(figure)
	return figure.died_year ~= -1 -- No other way?
end

local function attemptRitual(item)
	-- Is it a figurine?
	if not item._type == df.item_figurinest then
		return false, "Not a figurine."
	end

	-- Couldn't get the item to be destroyed.
	-- Is it non-artifact (we destroy it)?
	-- if item.flags.artifact then
	-- 	return false, "Can't use an artifact in the ritual."
	-- end

	-- Is there an image?
	local image
	local foundChunk
	if item.image and item.image.id ~= -1 then
		for _, chunk in ipairs(df.global.world.art_image_chunks) do
			if chunk.id == item.image.id then
				foundChunk = true
				local imageAtIndex = chunk.images[item.image.subid]
				if imageAtIndex and imageAtIndex.subid == item.image.subid then
					image = imageAtIndex
					break
				else
					-- Is this even possible?
					for _, chunkImage in ipairs(chunk.images) do
						if chunkImage.subid == item.image.subid then
							image = chunkImage
							break
						end
					end
				end
			end
			if image then
				break
			end
		end
	end
	if not foundChunk then
		qerror("Could not find art image chunk for the figurine; no idea how to load it from disk. Looking at the figurine's description will do so. Unsure if/when it will unload, so do it paused?")
	end
	if not image then
		return false, "Couldn't find the item's image!"
	end

	-- Is the image of a dead megabeast?
	local imageOK = false
	local figure
	if #image.elements == 1 and #image.properties == 1 then
		local element = image.elements[0]
		if element.count == 1 and element._type == df.art_image_element_creaturest then
			figure = df.historical_figure.find(element.histfig)
			if figure and isMegabeast(figure) then
				local property = image.properties[0]
				if property._type == df.art_image_property_intransitive_verbst then
					if property.subject == 0 and property.verb == df.art_image_property_verb.Dead then
						imageOK = true
					end
				end
			end
		end
	end
	if not imageOK then
		return false, "Wrong sort of image! Must be of a megabeast historical figure who is dead in the image."
	end

	-- Is the figure dead?
	if not (figure and isDead(figure)) then
		return false, "Historical figure itself is not dead."
	end

	-- Is it in a building?
	local buildingRef = dfhack.items.getGeneralRef(item, df.general_ref_type.BUILDING_HOLDER)
	if buildingRef then
		local building = df.building.find(buildingRef.building_id)
		if building and building._type == df.building_offering_placest then
			-- Are we in the building in the right way?
			local itemContainment
			for _, containment in ipairs(building.contained_items) do
				if containment.item and containment.item.id then
					itemContainment = containment
				end
			end
			if not itemContainment or itemContainment.use_mode ~= 0 then
				return false, "Item is not on the offering place properly."
			end

			for _, link in ipairs(figure.site_links) do
				if link._type == df.histfig_site_link_lairst then
					local site = df.world_site.find(link.site)
					if site then
						if site.flags.Undiscovered then
							site.flags.Undiscovered = false
							-- dfhack.items.remove(item) -- Didn't work...
							return true, "Lair site now discovered! Site id: " .. link.site
						else
							return false, "Lair site already discovered."
						end
					end
				end
			end
			return false, "No lair on this figure."
		end
	end
	return false, "The item is not on an offering place building."
end

local item = dfhack.gui.getSelectedItem()
if not item then
	return
end
local result, message = attemptRitual(item)
if not result then
	print("Ritual failed...")
	if not message then
		qerror("No failure message...?")
	end
	print(message)
else
	print("Ritual success!!")
	if not message then
		qerror("No success message...?")
	end
	print(message)
end
