local knowledge = df.historical_figure.find(dfhack.gui.getSelectedUnit().hist_figure_id).info.known_info.knowledge

local keys = {
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

local knownThings, thingsToKnow = 0, 0

for _, key in ipairs(keys) do
	for knowledge, known in pairs(knowledge[key]) do
		if not tonumber(knowledge) then -- skip unnamed bits
			thingsToKnow = thingsToKnow + 1
			if known then
				knownThings = knownThings + 1
			end
		end
	end
end

print("Knowledge: " .. knownThings .. "/" .. thingsToKnow)
