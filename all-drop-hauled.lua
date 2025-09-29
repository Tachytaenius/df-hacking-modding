-- For emergencies

local function removeItemFromJob(job, item)
	for _, itemRef in ipairs(job.items) do
		if not itemRef.item then
			goto continue
		end

		if itemRef.item == item then
			local refCount = #itemRef.item.specific_refs
			local stillHasJobs = false
			for i = refCount - 1, 0, -1 do
				local ref = itemRef.item.specific_refs[i]
				if ref.type == df.specific_ref_type.JOB then
					if ref.data.job == job then
						itemRef.item.specific_refs:erase(i)
						ref:delete()
					end
				end
			end
			if not stillHasJobs then
				itemRef.item.flags.in_job = false
			end
			break
		end

	    ::continue::
	end
end

local modeSwap -- Otherwise moveToGround won't work
if df.global.ui.main.mode == df.ui_sidebar_mode.ViewUnits then
	df.global.ui.main.mode = df.ui_sidebar_mode.Default
	modeSwap = true
end

for _, unit in ipairs(df.global.world.units.active) do
	if not dfhack.units.isCitizen(unit) then
		goto continue
	end
	local toDrop = {}
	for _, inventoryItem in ipairs(unit.inventory) do
		if inventoryItem.mode ~= df.unit_inventory_item.T_mode.Hauled then
			goto continue
		end
		toDrop[#toDrop+1] = inventoryItem.item
	    ::continue::
	end
	local pos = xyz2pos(dfhack.units.getPosition(unit))
	for _, item in ipairs(toDrop) do
		local refCount = #item.specific_refs
		for i = refCount - 1, 0, -1 do
			local ref = item.specific_refs[i]
			if ref.type == df.specific_ref_type.JOB then
				removeItemFromJob(ref.data.job, item)
			end
		end

		local success = dfhack.items.moveToGround(item, pos) -- Remoevs from unit.inventory, making iteration unsafe (the above code that iterates backwards was made after this)
		if not success then
			print("Unit " .. unit.id .. " could not drop item " .. item.id)
		end
	end
	::continue::
end

if modeSwap then
	df.global.ui.main.mode = df.ui_sidebar_mode.ViewUnits
end
