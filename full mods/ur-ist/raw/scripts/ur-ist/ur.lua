-- ur-ist's Ur simulation script
-- By Tachytaenius

-- This object is not really designed for interactive play; the code returning control to the rest of the program is mostly just for testing purposes

local function round(x)
	return math.floor(x + 0.5)
end

local ur = {}

-- While functions are defined on ur, within them the functions call other functions from self; they won't be the same table.

function ur:newPieces()
	local pieces = {}
	for i = 1, 7 do
		pieces[i] = 0
	end
	return pieces
end

function ur:init()
	self.aPieces = self:newPieces()
	self.bPieces = self:newPieces()
	self.turnSwaps = 0
	self.winner = nil
	self.waiting = nil
	self:setFirstPlayer()
end

function ur:singleDiceRoll()
	return self.randomInt(0, 1)
end

function ur:roll()
	local total = 0
	for _=1, 4 do
		total = total + self:singleDiceRoll()
	end
	return total
end

function ur:setFirstPlayer()
	local aRoll, bRoll
	repeat
		aRoll = self:roll()
		bRoll = self:roll()
	until aRoll ~= bRoll
	self.turn = aRoll > bRoll and "a" or "b"
end

function ur:getTurnPieces()
	local moverPieces = self.turn == "a" and self.aPieces or self.bPieces
	local otherPieces = self.turn == "a" and self.bPieces or self.aPieces
	return moverPieces, otherPieces
end

function ur:canMakeMove(piece, roll)
	if roll == 0 then
		return false
	end

	local moverPieces, otherPieces = self:getTurnPieces()
	local currentPosition = moverPieces[piece]

	if currentPosition == "scored" then
		return false
	end

	local nextPosition = currentPosition + roll
	local nextIsRosette = self.rosettes[nextPosition]
	local nextIsCommonTile = self.common[nextPosition]

	if nextPosition > self.destination then
		return false
	end

	local presentPiece
	for _, otherPosition in ipairs(moverPieces) do
		if otherPosition == nextPosition then
			presentPiece = "own"
			break
		end
	end
	if not presentPiece and nextIsCommonTile then
		for _, otherPosition in ipairs(otherPieces) do
			if otherPosition == nextPosition then
				presentPiece = "opponent"
				break
			end
		end
	end

	if presentPiece == "own" then
		return false
	end
	if presentPiece == "opponent" and nextIsRosette then -- Already checked if common tile
		return false
	end

	return true
end

function ur:swapTurns()
	self.turn = self.turn == "a" and "b" or "a"
	self.turnSwaps = self.turnSwaps + 1
end

function ur:makeMove(piece, roll) -- Changes turn (or not, depending on rosette) and moves and captures pieces, but doesn't roll the dice or check win condition
	-- Assume it was already checked...

	local moverPieces, otherPieces = self:getTurnPieces()
	local currentPosition = moverPieces[piece]
	local nextPosition = currentPosition + roll
	local nextIsCommonTile = self.common[nextPosition]

	local presentOpponentPiece
	if nextIsCommonTile then
		for i, otherPosition in ipairs(otherPieces) do
			if otherPosition == nextPosition then
				presentOpponentPiece = i
				break
			end
		end
	end
	if presentOpponentPiece then -- We assume it is not on a rosette since this move was checked
		otherPieces[presentOpponentPiece] = 0
	end

	if nextPosition == self.destination then
		moverPieces[piece] = "scored"
	else
		moverPieces[piece] = nextPosition
	end

	if not self.rosettes[nextPosition] then
		self:swapTurns()
	end
end

function ur:getPossibleMoves(roll)
	local moverPieces, otherPieces = self:getTurnPieces()
	local possibleMoves = {}
	for i in ipairs(moverPieces) do
		if self:canMakeMove(i, roll) then
			possibleMoves[#possibleMoves+1] = i
		end
	end
	return possibleMoves
end

function ur:startTurn()
	local roll = self:roll()
	local possibleMoves = self:getPossibleMoves(roll)
	if #possibleMoves == 0 then
		return nil
	end
	return possibleMoves, roll
end

function ur:giveInput(moveId)
	assert(self.waiting, "Attempted to give input but game wasn't waiting for input")
	local piece = self.waiting.possibleMoves[moveId]
	self:makeMove(piece, self.waiting.roll)
	self.waiting = nil
	self:checkWin()
end

function ur:pickBotMove(possibleMoves, roll, intelligence) -- Returns move id, not piece id
	-- Rudimentary agent

	local moverPieces, otherPieces = self:getTurnPieces()

	local furthestPieceId, furthestPiecePosition
	for pieceId, position in ipairs(moverPieces) do
		if position ~= "scored" and (not furthestPieceId or position > furthestPiecePosition) then
			furthestPieceId, furthestPiecePosition = pieceId, position
		end
	end

	local analysedMoves = {}
	for moveId, pieceId in ipairs(possibleMoves) do
		local analysis = {}
		analysis.moveId = moveId
		analysedMoves[moveId] = analysis

		local currentPosition = moverPieces[pieceId]
		local nextPosition = currentPosition + roll

		analysis.toSafe = not self.common[nextPosition]
		if not analysis.toSafe then
			for _, otherPosition in ipairs(otherPieces) do
				if otherPosition == nextPosition then
					analysis.captures = true
					break
				end
			end
		end
		if self.rosettes[nextPosition] then
			analysis.toRosette = true
		else
			-- Opponent goes next
			for consideredOpponentRoll = 1, 4 do
				for _, ownPiecePosition in ipairs(moverPieces) do
					if ownPiecePosition ~= "scored" and self.common[ownPiecePosition] and not self.rosettes[ownPiecePosition] then
						-- This piece could be taken?
						for _, opponentPiecePosition in ipairs(otherPieces) do
							if opponentPiecePosition ~= "scored" and opponentPiecePosition + consideredOpponentRoll == ownPiecePosition then
								analysis["capturable" .. consideredOpponentRoll] = true
								break
							end
						end
					end
				end
			end
		end
		analysis.scores = nextPosition >= self.destination
		analysis.furthest = pieceId == furthestPieceId

		local quality = 0
		for field, weight in pairs(self.weights) do
			if analysis[field] then
				quality = quality + weight
			end
		end
		analysis.quality = quality
	end

	-- I would much rather pick moves in a better way (TODO?)

	local tieBreakers = {}
	table.sort(analysedMoves, function(a, b)
		if a.quality == b.quality then
			tieBreakers[a] = tieBreakers[a] or self.randomFloat()
			tieBreakers[b] = tieBreakers[b] or self.randomFloat()
			return tieBreakers[a] < tieBreakers[b]
		end
		return a.quality > b.quality
	end)

	local maxListMove = math.max(1, math.min(#analysedMoves, round(#analysedMoves * (1 - intelligence))))
	local sortedAnalysisPosition = self.randomInt(1, maxListMove)
	return analysedMoves[sortedAnalysisPosition].moveId

	-- local qualityMin, qualityMax = 0, 0
	-- for _, moveAnalysis in ipairs(analysedMoves) do
	-- 	qualityMin = math.min(qualityMin, moveAnalysis.quality)
	-- 	qualityMax = math.max(qualityMin, moveAnalysis.quality)
	-- end
end

function ur:checkWin()
	if self.winner then
		return
	end

	local function checkPiecesWon(pieces)
		local nonScorePosition = false
		for _, position in ipairs(pieces) do
			if position ~= "scored" then
				nonScorePosition = true
				break
			end
		end
		return not nonScorePosition
	end

	if checkPiecesWon(self.aPieces) then
		self.winner = "a"
	end

	if checkPiecesWon(self.bPieces) then
		self.winner = "b"
	end
end

function ur:isBotTurn()
	local aBot = self.turn == "a" and self.aPlayer ~= "player"
	local bBot = self.turn == "b" and self.bPlayer ~= "player"
	return aBot or bBot
end

function ur:tick()
	if self.winner or self.waiting then
		return
	end

	if not self:isBotTurn() and not (self.winner or self.waiting) then
		local possibleMoves, roll = self:startTurn()
		if possibleMoves then
			self.waiting = {
				possibleMoves = possibleMoves,
				roll = roll
			}
		end
	end

	while self:isBotTurn() and not self.winner do
		local possibleMoves, roll = self:startTurn()
		if possibleMoves and #possibleMoves > 0 then
			local moveId = self:pickBotMove(possibleMoves, roll, self.turn == "a" and self.aPlayer or self.bPlayer)
			self:makeMove(possibleMoves[moveId], roll) -- Sets turn for next iteration
		else
			self:swapTurns()
		end
		self:checkWin()
	end
end

function ur:piecesOnBoard(player)
	local pieces = self[player .. "Pieces"]
	local total = 0
	for _, position in ipairs(pieces) do
		if position ~= "scored" and position ~= 0 then
			total = total + 1
		end
	end
	return total
end

function ur:piecesScored(player)
	local pieces = self[player .. "Pieces"]
	local total = 0
	for _, position in ipairs(pieces) do
		if position == "scored" then
			total = total + 1
		end
	end
	return total
end

local function newUrInstance(parameters)
	local new = {}
	for k, v in pairs(ur) do
		new[k] = v
	end

	-- Meant to be added to other projects that may have their own random number generators, so we can't just use math.random
	new.randomInt = parameters.randomInt or error("Need to supply randomInt where randomInt(a, b) returns an integer within [a, b]") -- Includes a and b
	new.randomFloat = parameters.randomFloat or error("Need to suppy randomFloat where randomFloat() returns a float within [0, 1)") -- Excludes 1

	new.aPlayer = parameters.aPlayer -- "player" or a float in [0, 1] for bot intelligence
	new.bPlayer = parameters.bPlayer

	new.destination = 15
	new.rosettes = {
		[4] = true,
		[8] = true,
		[14] = true
	}
	new.common = { }
	for i = 5, 12 do
		new.common[i] = true
	end

	new.weights = { -- Determined by my own program
		toSafe = 0.025047,
		furthest = -0.009670,
		scores = 0.019902,
		captures = 0.067971,
		toRosette = 0.012164,
		capturable1 = -0.000680,
		capturable2 = -0.047117,
		capturable3 = -0.011649,
		capturable4 = -0.006169
	}

	new:init()

	return new
end

return newUrInstance
