local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

local CFG = {
	apiUrl = "https://stockfish.online/api/s/v2.php",
	settingsFile = "AutoChessSettings.json",
	useFileSettings = true,
}

local DEFAULT_SETTINGS = {
	enabled = true,
	dryRun = false,

	kinds = { bot = true, online = true, puzzle = false, rush = false, tutorial = false },

	strength = {
		depth = 12,
		eloEnabled = false,
		elo = 2000,
	},

	timing = {
		mode = "human",
		fixed = 0.6,
		min = 0.35,
		max = 0.9,

		thinkMin = 1.5,
		thinkMax = 8,
		longChance = 22,
		openingFast = true
	},

	cooldown = 1.1,
	poll = 0.25,
	resendAfter = 3.5,
	maxSendAttempts = 3,
	autoRematch = false,
	guiCollapsed = false,
	guiPos = nil,
	dotPos = nil,
}

local function deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in pairs(value) do
		copy[key] = deepCopy(item)
	end
	return copy
end

local function mergeInto(target, source)
	if type(source) ~= "table" then
		return target
	end
	for key, value in pairs(source) do
		if type(value) == "table" and type(target[key]) == "table" then
			mergeInto(target[key], value)
		elseif target[key] ~= nil or type(value) == "table" then
			target[key] = value
		end
	end
	return target
end

local S = deepCopy(DEFAULT_SETTINGS)

local execEnv = (getfenv and getfenv(0)) or _G

local function canUseFile()
	return CFG.useFileSettings
		and type(execEnv.writefile) == "function"
		and type(execEnv.readfile) == "function"
end

local function loadSettings()
	if not canUseFile() then
		return false
	end
	local ok, body = pcall(execEnv.readfile, CFG.settingsFile)
	if not ok or type(body) ~= "string" or body == "" then
		return false
	end
	local decodedOk, decoded = pcall(HttpService.JSONDecode, HttpService, body)
	if not decodedOk or type(decoded) ~= "table" then
		return false
	end
	mergeInto(S, decoded)
	return true
end

local function saveSettings()
	if not canUseFile() then
		return false
	end
	local ok = pcall(execEnv.writefile, CFG.settingsFile, HttpService:JSONEncode(S))
	return ok
end

local function resolveHttp()
	if type(execEnv.request) == "function" then
		return function(url)
			local ok, res = pcall(execEnv.request, { Url = url, Method = "GET" })
			if ok and type(res) == "table" then return res end
			return nil, tostring(res)
		end
	end

	local syn = execEnv.syn or (type(getgenv) == "function" and getgenv().syn)
	if type(syn) == "table" and type(syn.request) == "function" then
		return function(url)
			local ok, res = pcall(syn.request, { Url = url, Method = "GET" })
			if ok and type(res) == "table" then return res end
			return nil, tostring(res)
		end
	end

	if type(execEnv.http_request) == "function" then
		return function(url)
			local ok, res = pcall(execEnv.http_request, url)
			if ok and type(res) == "table" then return res end
			return nil, tostring(res)
		end
	end

	if type(execEnv.http) == "table" and type(execEnv.http.request) == "function" then
		return function(url)
			local ok, res = pcall(execEnv.http.request, { Url = url, Method = "GET" })
			if ok and type(res) == "table" then return res end
			return nil, tostring(res)
		end
	end

	return nil
end

local httpGet = resolveHttp()
if not httpGet then
	error("[AutoChess] у экзекьютора нет HTTP (request / syn.request / http_request)")
end

local function waitForChess(timeout)
	local deadline = os.clock() + (timeout or 60)
	while os.clock() < deadline do
		local container = ReplicatedStorage:FindFirstChild("ChessClient")
		local appScript = container and container:FindFirstChild("App")
		if appScript then
			local ok, module = pcall(require, appScript)
			if ok and type(module) == "table" and module.session ~= nil then
				return module
			end
		end
		task.wait(0.5)
	end
	return nil
end

local chess = waitForChess(60)
if not chess then
	error("[AutoChess] не дождался ChessClient.App — зайди в игру и запусти скрипт снова")
end

local state = {
	lastFen = nil,
	lastMark = nil,
	lastRequestAt = 0,
	movesPlayed = 0,
	failures = 0,
	lastError = nil,
	lastPath = nil,
	lastReason = nil,
	lastReasonShown = nil,
	lastReasonAt = 0,
	lastApiUci = nil,
	pendingUci = nil,
	pendingFen = nil,
	pendingAt = 0,
	sendAttempts = 0,
	lastDelay = nil,
	lastThink = nil,
}

local function urlEncode(text)
	return (tostring(text):gsub("[^%w%-%._~]", function(char)
		return string.format("%%%02X", string.byte(char))
	end))
end

local function isValidUci(uci)
	return type(uci) == "string" and string.match(uci, "^%l%d%l%d%a?$") ~= nil
end

local function parseBestMove(raw)
	if type(raw) ~= "string" or raw == "(none)" or raw == "0000" then
		return nil
	end
	for token in string.gmatch(raw, "%S+") do
		local lowered = string.lower(token)
		if isValidUci(lowered) then
			return lowered
		end
	end
	return nil
end

local function isPublicApi()
	return string.find(CFG.apiUrl, "stockfish.online", 1, true) ~= nil
end

local function clampNumber(value, low, high)
	value = tonumber(value) or low
	return math.max(low, math.min(high, value))
end

local function computeDelay()
	local timing = S.timing

	if timing.mode == "fixed" then
		return clampNumber(timing.fixed, 0.05, 30)
	end

	local low = clampNumber(timing.min, 0.05, 30)
	local high = clampNumber(timing.max, 0.05, 30)
	if low > high then
		low, high = high, low
	end
	return low + math.random() * (high - low)
end

local function randomBetween(low, high)
	if low > high then
		low, high = high, low
	end
	return low + math.random() * (high - low)
end

local function evalOf(decoded)
	if type(decoded) ~= "table" then
		return nil
	end
	if tonumber(decoded.evaluation) then
		return tonumber(decoded.evaluation)
	end
	if tonumber(decoded.eval_cp) then
		return tonumber(decoded.eval_cp) / 100
	end
	if type(decoded.lines) == "table" and decoded.lines[1] then
		local line = decoded.lines[1]
		if line.mate then
			return 99
		end
		if tonumber(line.eval_cp) then
			return tonumber(line.eval_cp) / 100
		end
	end
	return nil
end

local function mateOf(decoded)
	if type(decoded) ~= "table" then
		return nil
	end
	if decoded.mate ~= nil then
		return tonumber(decoded.mate)
	end
	if type(decoded.lines) == "table" and decoded.lines[1] and decoded.lines[1].mate then
		return tonumber(decoded.lines[1].mate)
	end
	return nil
end

local function computeThinkTime(session, decoded)
	local timing = S.timing

	if timing.mode == "fixed" then
		return clampNumber(timing.fixed, 0.05, 30)
	end
	if timing.mode == "random" then
		return computeDelay()
	end

	local low = clampNumber(timing.thinkMin, 0.2, 20)
	local high = clampNumber(timing.thinkMax, 0.5, 45)
	if low > high then
		low, high = high, low
	end

	local ply = session and session.ucis and #session.ucis or 0
	local mate = mateOf(decoded)
	local eval = evalOf(decoded)

	local factor = 1

	if mate ~= nil then
		factor = 0.3
	elseif eval ~= nil then
		local absolute = math.abs(eval)
		if absolute >= 3 then
			factor = 0.55
		elseif absolute <= 0.5 then
			factor = 1.35
		end
	end

	if timing.openingFast ~= false and ply <= 8 then
		factor = factor * 0.45
	end

	local base = randomBetween(low, high) * factor * randomBetween(0.85, 1.2)

	local longChance = clampNumber(timing.longChance, 0, 100)
	if math.random() * 100 < longChance then
		local deepLow = high
		local deepHigh = math.min(45, math.max(high + 2, high * 2))
		base = randomBetween(deepLow, deepHigh)
	end

	base = clampNumber(base, 0.2, 45)

	local clocks = session and session.clocks
	local myColor = session and session.myColor
	if clocks and myColor and tonumber(clocks[myColor]) then
		local left = tonumber(clocks[myColor]) / 1000
		local cap = math.max(0.3, left * 0.12)
		if left < 30 then
			cap = math.min(cap, 3)
		end
		if left - base < 1 then
			cap = math.min(cap, math.max(0.3, left - 1))
		end
		base = math.min(base, cap)
	end

	return base
end

local function strengthLabel(depth)
	depth = clampNumber(depth, 1, 15)
	if depth <= 2 then return "очень слабо (~800)" end
	if depth <= 4 then return "слабо (~1200)" end
	if depth <= 6 then return "средне (~1500)" end
	if depth <= 8 then return "клубный (~1800)" end
	if depth <= 11 then return "сильно (~2100)" end
	if depth <= 13 then return "очень сильно (~2400)" end
	return "максимум (~2600+)"
end

local function buildUrl(fen)
	local depth = math.floor(clampNumber(S.strength.depth, 1, 15))
	local url = string.format("%s?fen=%s&depth=%d", CFG.apiUrl, urlEncode(fen), depth)

	if S.strength.eloEnabled and not isPublicApi() then
		url = url .. string.format("&elo=%d", math.floor(clampNumber(S.strength.elo, 1320, 3190)))
	end

	if not isPublicApi() then
		url = url .. "&format=lines"
	end

	return url
end

local function askStockfish(fen, ignoreCooldown)
	if not ignoreCooldown then
		local since = os.clock() - state.lastRequestAt
		local wait = clampNumber(S.cooldown, 0, 10) - since
		if wait > 0 then
			task.wait(wait)
		end
	end
	state.lastRequestAt = os.clock()

	local res, err = httpGet(buildUrl(fen))
	if not res then
		state.lastError = "http: " .. tostring(err)
		return nil, state.lastError
	end

	local status = res.StatusCode or res.Status or res.status or 200
	local body = res.Body or res.body or res.ResponseBody or ""

	if typeof and typeof(body) == "table" then
		return parseBestMove(body.bestmove or body.bestMove), nil, body
	end

	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, body)
	if not ok or type(decoded) ~= "table" then
		state.lastError = string.format("bad json (http %s)", tostring(status))
		return nil, state.lastError
	end

	if decoded.success == false then
		state.lastError = tostring(decoded.message or "api said no")
		return nil, state.lastError
	end

	return parseBestMove(decoded.bestmove), nil, decoded
end

local PROMO = { q = 5, r = 4, b = 3, n = 2 }

local engineLib = nil
local engineTried = false

local function getEngineLib()
	if engineTried then
		return engineLib
	end
	engineTried = true
	local ok, value = pcall(require, ReplicatedStorage.Chess.Engine)
	if ok and type(value) == "table" then
		engineLib = value
	end
	return engineLib
end

local function squareIndex(alg)
	local engine = getEngineLib()
	if engine and type(engine.algToIndex64) == "function" then
		local ok, index = pcall(engine.algToIndex64, alg)
		if ok and type(index) == "number" then
			return index
		end
	end
	local file = string.byte(alg, 1) - 96
	local rank = tonumber(string.sub(alg, 2, 2))
	if file >= 1 and file <= 8 and rank and rank >= 1 and rank <= 8 then
		return (file - 1) + (rank - 1) * 8
	end
	return nil
end

local function playMove(session, uci)
	local kind = session.kind
	local from = squareIndex(string.sub(uci, 1, 2))
	local to = squareIndex(string.sub(uci, 3, 4))
	local promo = PROMO[string.sub(uci, 5, 5)] or 0

	if type(chess.onBoardMove) == "function" and from and to then
		local ok, result = pcall(chess.onBoardMove, from, to, promo, false)
		if ok and result == true then
			state.lastPath = "onBoardMove"
			return true
		end
		state.lastError = "onBoardMove -> " .. tostring(result)
	end

	if kind == "online" then
		for _, name in ipairs({ "playMove", "submitMove" }) do
			if type(chess[name]) == "function" then
				local ok, result = pcall(chess[name], uci)
				if ok and result ~= false and result ~= nil then
					state.lastPath = name
					return true
				end
				if not ok then
					state.lastError = name .. " -> " .. tostring(result)
				end
			end
		end

		if type(chess.send) == "function" then
			chess.send({ type = "move", id = session.id, uci = string.lower(uci), ply = #session.ucis })
			state.lastPath = "send"
			return true
		end

		state.lastError = state.lastError or "нет ни onBoardMove, ни playMove, ни send"
		return false
	end

	if type(chess.debug) == "function" then
		local ok, result = pcall(chess.debug, { type = "move", uci = uci })
		if ok and result ~= false and result ~= nil then
			state.lastPath = "debug"
			return true
		end
		state.lastError = "debug -> " .. tostring(result)
	end

	return false
end

local function fenOf(session)
	if session and session.engine and type(session.engine.getFen) == "function" then
		local ok, fen = pcall(session.engine.getFen, session.engine)
		if ok then
			return fen
		end
	end
	return nil
end

local function isMyTurn(session)
	if not session or type(session.isMyTurn) ~= "function" then
		return nil
	end
	local ok, mine = pcall(session.isMyTurn, session)
	if not ok then
		return nil
	end
	return mine
end

local function snapshot()
	local session = chess.session
	return {
		enabled = S.enabled,
		dryRun = S.dryRun,
		kind = session and session.kind or "nil",
		over = session and session.over or nil,
		moves = session and #session.ucis or 0,
		viewPly = session and session.viewPly or nil,
		myColor = session and session.myColor or nil,
		isMyTurn = isMyTurn(session),
		fen = session and fenOf(session) or nil,
		movesPlayed = state.movesPlayed,
		failures = state.failures,
		lastApiMove = state.lastApiUci,
		lastPath = state.lastPath,
		lastReason = state.lastReason,
		lastError = state.lastError,
		lastDelay = state.lastDelay,
		kindsAllowed = session and S.kinds[session.kind] or nil,
		depth = S.strength.depth,
		timingMode = S.timing.mode,
	}
end

local function canAct(session)
	if not session then
		return false, "нет session (клиент ещё не загрузился)"
	end
	if session.over then
		return false, "партия окончена"
	end
	if not S.kinds[session.kind] then
		return false, string.format("вид '%s' выключен", tostring(session.kind))
	end
	if session.viewPly ~= nil and session.ucis ~= nil and session.viewPly ~= #session.ucis then
		return false, string.format("открыта история (%d из %d)", session.viewPly, #session.ucis)
	end
	local mine = isMyTurn(session)
	if mine == false then
		return false, "не мой ход"
	end
	return true
end

local function noteReason(reason)
	state.lastReason = reason
end

local function pvLines(decoded)
	if type(decoded) ~= "table" then
		return nil
	end

	local moves = {}

	if type(decoded.continuation) == "string" then
		for move in string.gmatch(decoded.continuation, "%S+") do
			if isValidUci(move) then
				table.insert(moves, move)
			end
		end
	elseif type(decoded.pv) == "table" then
		for _, move in ipairs(decoded.pv) do
			if isValidUci(move) then
				table.insert(moves, move)
			end
		end
	end

	if #moves == 0 then
		return nil
	end

	return { { pv = moves, eval_cp = decoded.evaluation, mate = decoded.mate } }
end

local HINT_COLOR = Color3.fromRGB(150, 190, 70)
local HINT_REPLY_COLOR = Color3.fromRGB(90, 150, 210)

local function boardOf()
	local board = chess.board
	if board and type(board.setArrow) == "function" then
		return board
	end
	return nil
end

local function clearHints()
	local board = boardOf()
	if not board then
		return
	end
	pcall(board.setArrow, board, "autohint", nil)
	pcall(board.setArrow, board, "autohintReply", nil)
	state.hintUci = nil
end

local function showHints(session, uci, lines)
	local board = boardOf()
	if not board then
		return false
	end

	if session.kind == "online" then
		clearHints()
		state.hintBlocked = true
		return false
	end

	state.hintBlocked = nil

	local from = squareIndex(string.sub(uci, 1, 2))
	local to = squareIndex(string.sub(uci, 3, 4))
	if not from or not to then
		return false
	end

	pcall(board.setArrow, board, "autohint", from, to, HINT_COLOR, 0.1)
	state.hintUci = uci

	local reply = nil
	if type(lines) == "table" then
		for _, line in ipairs(lines) do
			if type(line.pv) == "table" and #line.pv >= 2 then
				reply = line.pv[2]
				break
			end
		end
	end

	if reply and #reply >= 4 then
		local rFrom = squareIndex(string.sub(reply, 1, 2))
		local rTo = squareIndex(string.sub(reply, 3, 4))
		if rFrom and rTo then
			pcall(board.setArrow, board, "autohintReply", rFrom, rTo, HINT_REPLY_COLOR, 0.45)
		end
	else
		pcall(board.setArrow, board, "autohintReply", nil)
	end

	return true
end

local function markOf(session, fen)
	return string.format("%s|%s|%s", tostring(session.kind), tostring(session.id or ""), tostring(fen))
end

local function resetMark()
	state.lastMark = nil
	state.lastFen = nil
end

local function step(force)
	local report = {}

	local session = chess.session
	local allowed, reason = canAct(session)
	if not allowed then
		noteReason(reason)
		report.reason = reason
		return report
	end

	local fen = fenOf(session)
	if not fen then
		noteReason("не смог получить FEN")
		report.reason = "no fen"
		return report
	end
	report.fen = fen

	local mark = markOf(session, fen)

	if not force and mark == state.lastMark then
		return report
	end
	state.lastMark = mark
	state.lastFen = fen

	local uci, askErr, decoded = askStockfish(fen, force)
	report.apiError = askErr
	report.uci = uci
	report.lines = pvLines(decoded)

	if not uci then
		state.failures += 1
		state.lastMark = nil
		state.lastFen = nil
		if not force then
			task.wait(1.0)
		end
		return report
	end
	state.lastApiUci = uci

	if S.dryRun then
		local shown = showHints(session, uci, report.lines)
		report.ok = true
		report.dryRun = true
		report.hint = shown
		return report
	end

	if not force then
		local pause = computeThinkTime(session, decoded)
		state.lastDelay = pause
		state.lastThink = pause
		task.wait(pause)
	end

	if chess.session ~= session or session.over or fenOf(session) ~= fen then
		state.lastMark = nil
		state.lastFen = nil
		report.reason = "позиция сменилась, пока думали"
		return report
	end

	clearHints()
	local played = playMove(session, uci)
	report.played = played

	if played then
		state.movesPlayed += 1
		if session.kind == "online" and state.lastPath ~= "onBoardMove" then
			state.pendingUci = uci
			state.pendingFen = fen
			state.pendingAt = os.clock()
			state.sendAttempts = 1
		else
			state.pendingUci = nil
			state.pendingFen = nil
		end
		report.ok = true
	else
		state.failures += 1
		state.lastFen = nil
		if not force then
			task.wait(0.6)
		end
	end

	return report
end

local function resendIfStuck()
	if not state.pendingUci or not state.pendingFen then
		return
	end

	local session = chess.session
	if not session or session.kind ~= "online" or session.over then
		state.pendingUci = nil
		return
	end
	if fenOf(session) ~= state.pendingFen then
		state.pendingUci = nil
		state.pendingFen = nil
		return
	end
	if os.clock() - state.pendingAt < clampNumber(S.resendAfter, 0.5, 60) then
		return
	end

	local maxAttempts = math.floor(clampNumber(S.maxSendAttempts, 1, 10))
	if state.sendAttempts >= maxAttempts then
		local stuck = state.pendingUci
		state.pendingUci = nil
		return
	end

	if not canAct(session) then
		state.pendingUci = nil
		return
	end

	state.sendAttempts += 1
	state.pendingAt = os.clock()
end

local function loop()
	while true do
		task.wait(clampNumber(S.poll, 0.05, 2))

		if S.enabled then
			pcall(resendIfStuck)
			local ok, err = pcall(step, false)
			if not ok then
				state.lastError = tostring(err)
				state.lastFen = nil
				task.wait(1.0)
			end
		end
	end
end

local api = {
	config = CFG,
	settings = S,
	state = state,
	chess = chess,
	ask = askStockfish,
	play = playMove,
	delay = computeDelay,
	think = computeThinkTime,
	save = saveSettings,
}

function api.status()
	local info = snapshot()

	local fields = { "enabled", "dryRun", "kind", "kindsAllowed", "over", "moves", "viewPly",
		"myColor", "isMyTurn", "movesPlayed", "failures", "lastApiMove", "lastPath",
		"lastReason", "lastError", "depth", "timingMode" }

	return info
end

function api.tryNow()
	local report = step(true)
	return report
end

function api.tick()
	return step(false)
end

function api.move(uci)
	uci = string.lower(tostring(uci or ""))
	if not isValidUci(uci) then
		return false
	end
	local session = chess.session
	if not session then
		return false
	end
	state.lastPath = nil
	local played = playMove(session, uci)
	return played
end

function api.sync()
	if type(chess.send) ~= "function" then
		return false
	end
	chess.send({ type = "sync" })
	state.pendingUci = nil
	state.pendingFen = nil
	return true
end

function api.resend()
	local before = state.sendAttempts
	resendIfStuck()
	return state.sendAttempts
end

function api.setEnabled(value)
	S.enabled = value == true
	resetMark()
	clearHints()
	saveSettings()
	return S.enabled
end

api.snapshot = snapshot
api.canAct = canAct

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or input.KeyCode ~= Enum.KeyCode.RightShift then
		return
	end
	api.setEnabled(not S.enabled)
	if type(chess.toast) == "function" then
		pcall(chess.toast, S.enabled and "AutoChess: ON" or "AutoChess: OFF")
	end
end)

if type(getgenv) == "function" then
	getgenv().AutoChess = api
end

local info = snapshot()

task.spawn(loop)

task.spawn(loop)

local guiApi

do
	local AutoChess = api

	local S = AutoChess.settings
	local CFG = AutoChess.config or {}
	local chess = AutoChess.chess or {}

	S.timing = S.timing or { mode = "random", fixed = 0.6, min = 0.35, max = 0.9 }
	S.strength = S.strength or { depth = 12, eloEnabled = false, elo = 2000 }
	S.kinds = S.kinds or { bot = true, online = true }

	local function save()
		if type(AutoChess.save) == "function" then
			pcall(AutoChess.save)
		end
	end

	local function clampNumber(value, low, high)
		value = tonumber(value) or low
		return math.max(low, math.min(high, value))
	end

	local function isPublicApi()
		return string.find(tostring(CFG.apiUrl or ""), "stockfish.online", 1, true) ~= nil
	end

	local function strengthLabel(depth)
		depth = clampNumber(depth, 1, 15)
		if depth <= 2 then return "very weak (~800)" end
		if depth <= 4 then return "weak (~1200)" end
		if depth <= 6 then return "medium (~1500)" end
		if depth <= 8 then return "club (~1800)" end
		if depth <= 11 then return "strong (~2100)" end
		if depth <= 13 then return "very strong (~2400)" end
		return "max (~2600+)"
	end

	local function tcLabel(tc, id)
		if type(tc.name) == "string" and tc.name ~= "" then
			return tc.name
		end

		local base = tonumber(tc.base)
		local inc = tonumber(tc.inc) or 0
		if not base then
			return tostring(id)
		end

		if base % 60 == 0 then
			return string.format("%d+%d", base / 60, inc)
		end
		return string.format("%ds+%d", base, inc)
	end

	local function loadTimeControls()
		local list = {}

		local ok, config = pcall(function()
			return require(ReplicatedStorage.Chess.Config)
		end)

		if ok and type(config) == "table" and type(config.TC_BY_ID) == "table" then
			for id, tc in pairs(config.TC_BY_ID) do
				if type(tc) == "table" then
					table.insert(list, {
						id = id,
						base = tonumber(tc.base) or 0,
						inc = tonumber(tc.inc) or 0,
						label = tcLabel(tc, id),
						class = tc.class,
					})
				end
			end
		end

		table.sort(list, function(left, right)
			if left.base == right.base then
				return left.inc < right.inc
			end
			return left.base < right.base
		end)

		local defaultId = nil
		if ok and type(config) == "table" then
			defaultId = config.DEFAULT_TC
		end

		return list, defaultId
	end

	local TIME_CONTROLS, DEFAULT_TC = loadTimeControls()

	local THEME = {
		panel = Color3.fromRGB(32, 32, 38),
		row = Color3.fromRGB(42, 42, 50),
		accent = Color3.fromRGB(120, 185, 90),
		accentOff = Color3.fromRGB(90, 90, 100),
		text = Color3.fromRGB(238, 238, 240),
		dim = Color3.fromRGB(150, 150, 160),
		track = Color3.fromRGB(58, 58, 68),
		onText = Color3.fromRGB(20, 26, 16),
		divider = Color3.fromRGB(58, 58, 68),
	}

	local gui = {}

	local function make(class, props, children)
		local object = Instance.new(class)
		for key, value in pairs(props or {}) do
			if key ~= "Parent" then
				object[key] = value
			end
		end
		for _, child in ipairs(children or {}) do
			child.Parent = object
		end
		if props and props.Parent then
			object.Parent = props.Parent
		end
		return object
	end

	local function corner(radius)
		return make("UICorner", { CornerRadius = UDim.new(0, radius or 8) })
	end

	local function label(props)
		props.BackgroundTransparency = 1
		props.Font = props.Font or Enum.Font.GothamMedium
		props.TextColor3 = props.TextColor3 or THEME.text
		props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
		props.TextSize = props.TextSize or 13
		return make("TextLabel", props)
	end

	local function makeButton(parent, props)
		return make("TextButton", {
			Size = props.size or UDim2.new(1, 0, 0, 30),
			Position = props.position,
			BackgroundColor3 = props.color or THEME.row,
			Text = props.text or "",
			Font = Enum.Font.GothamBold,
			TextSize = props.textSize or 13,
			TextColor3 = props.textColor or THEME.text,
			AutoButtonColor = true,
			BorderSizePixel = 0,
			Parent = parent,
		}, { corner(props.radius or 8) })
	end

	local function makeSlider(parent, config)
		local row = make("Frame", {
			Size = UDim2.new(1, 0, 0, 40),
			BackgroundTransparency = 1,
			Parent = parent,
		})

		label({
			Size = UDim2.new(0.55, 0, 0, 16),
			Text = config.name,
			TextColor3 = THEME.dim,
			TextSize = 12,
			Parent = row,
		})

		local valueLabel = label({
			Size = UDim2.new(0.45, 0, 0, 16),
			Position = UDim2.new(0.55, 0, 0, 0),
			Text = "",
			TextXAlignment = Enum.TextXAlignment.Right,
			TextSize = 12,
			Parent = row,
		})

		local hitArea = make("TextButton", {
			Size = UDim2.new(1, 0, 0, 22),
			Position = UDim2.new(0, 0, 0, 16),
			BackgroundTransparency = 1,
			Text = "",
			AutoButtonColor = false,
			Parent = row,
		})

		local track = make("Frame", {
			Size = UDim2.new(1, 0, 0, 5),
			Position = UDim2.new(0, 0, 0.5, 0),
			AnchorPoint = Vector2.new(0, 0.5),
			BackgroundColor3 = THEME.track,
			BorderSizePixel = 0,
			Parent = hitArea,
		}, { corner(3) })

		local fill = make("Frame", {
			Size = UDim2.new(0, 0, 1, 0),
			BackgroundColor3 = THEME.accent,
			BorderSizePixel = 0,
			Parent = track,
		}, { corner(3) })

		local knob = make("Frame", {
			Size = UDim2.fromOffset(13, 13),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0, 0, 0.5, 0),
			BackgroundColor3 = THEME.text,
			BorderSizePixel = 0,
			Parent = track,
		}, { corner(7) })

		local min, max, step = config.min, config.max, config.step or 1
		local value = config.value
		local dragging = false

		local function render()
			local alpha = 0
			if max > min then
				alpha = (value - min) / (max - min)
			end
			alpha = math.clamp(alpha, 0, 1)
			fill.Size = UDim2.new(alpha, 0, 1, 0)
			knob.Position = UDim2.new(alpha, 0, 0.5, 0)
			valueLabel.Text = config.format and config.format(value) or tostring(value)
		end

		local function setValue(raw, silent)
			local clamped = math.clamp(raw, min, max)
			if step > 0 then
				clamped = min + math.floor((clamped - min) / step + 0.5) * step
			end
			clamped = math.clamp(clamped, min, max)

			local changed = clamped ~= value
			value = clamped
			render()

			if changed and not silent and config.onChanged then
				config.onChanged(value)
			end
		end

		local function setFromX(x)
			local width = track.AbsoluteSize.X
			if width <= 0 then
				return
			end
			local alpha = (x - track.AbsolutePosition.X) / width
			setValue(min + math.clamp(alpha, 0, 1) * (max - min))
		end

		hitArea.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				setFromX(input.Position.X)
			end
		end)

		hitArea.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				dragging = false
			end
		end)

		UserInputService.InputChanged:Connect(function(input)
			if dragging
				and (input.UserInputType == Enum.UserInputType.MouseMovement
					or input.UserInputType == Enum.UserInputType.Touch) then
				setFromX(input.Position.X)
			end
		end)

		render()

		return {
			row = row,
			setValue = setValue,
			getValue = function()
				return value
			end,
			refresh = function()
				value = clampNumber(config.value, min, max)
				render()
			end,
		}
	end

	local function makeSection(parent, title)
		local holder = make("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Parent = parent,
		}, { make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }) })

		label({
			Size = UDim2.new(1, 0, 0, 16),
			Text = title,
			Font = Enum.Font.GothamBold,
			TextSize = 11,
			TextColor3 = THEME.accent,
			Parent = holder,
		})

		return holder
	end

	local function makeDivider(parent)
		return make("Frame", {
			Size = UDim2.new(1, 0, 0, 1),
			BackgroundColor3 = THEME.divider,
			BackgroundTransparency = 0.4,
			BorderSizePixel = 0,
			Parent = parent,
		})
	end

	local autoPlay = {
		enabled = false,
		tc = S.autoPlayTc or DEFAULT_TC,
		state = "off",
		games = 0,
		lastGameId = nil,
		nextActionAt = 0,
		lastNote = nil,
	}

	local function tcExists(id)
		for _, tc in ipairs(TIME_CONTROLS) do
			if tc.id == id then
				return true
			end
		end
		return false
	end

	if autoPlay.tc == nil and TIME_CONTROLS[1] then
		autoPlay.tc = TIME_CONTROLS[1].id
	elseif autoPlay.tc ~= nil and not tcExists(autoPlay.tc) then
		autoPlay.tc = TIME_CONTROLS[1] and TIME_CONTROLS[1].id or nil
	end

	local function autoPlayDescribe()
		local session = chess.session

		if not autoPlay.enabled then
			return "Auto play is off"
		end
		if chess.joining then
			return "Match found — joining…"
		end
		if chess.searching then
			local tc = chess.searching.tc
			return string.format("Searching %s…", tostring(tc or autoPlay.tc))
		end
		if session and session.kind == "online" and not session.over then
			local opponent = session.black
			if session.myColor == -1 then
				opponent = session.white
			end
			local name = opponent and (opponent.display or opponent.name) or "opponent"
			return string.format("In game vs %s", tostring(name))
		end
		if session and session.kind == "online" and session.over then
			return "Game over — queueing next…"
		end
		if session and session.kind ~= "online" and session.kind ~= "idle" then
			return string.format("Busy (%s) — auto play paused", tostring(session.kind))
		end
		return "Waiting for matchmaking…"
	end

	local function autoPlayTick()
		if not autoPlay.enabled then
			autoPlay.state = "off"
			return
		end

		local now = os.clock()
		local session = chess.session

		if not session then
			autoPlay.state = "waiting"
			return
		end

		if session.kind == "online" and not session.over then
			autoPlay.state = "inGame"
			if session.id ~= autoPlay.lastGameId then
				autoPlay.lastGameId = session.id
				autoPlay.games += 1
			end
			return
		end

		if session.kind ~= "online" and session.kind ~= "idle" then
			autoPlay.state = "busy"
			return
		end

		if chess.joining then
			autoPlay.state = "joining"
			return
		end

		if now < autoPlay.nextActionAt then
			return
		end

		if session.kind == "online" and session.over then
			autoPlay.nextActionAt = now + 5
			if type(chess.newGame) == "function" then
				local ok, err = pcall(chess.newGame)
				autoPlay.state = "queueing"
				if not ok then
					autoPlay.lastNote = tostring(err)
				end
			else
				autoPlay.lastNote = "client has no newGame()"
			end
			return
		end

		if not chess.searching and type(chess.startSearch) == "function" and autoPlay.tc then
			autoPlay.nextActionAt = now + 5
			local ok, err = pcall(chess.startSearch, autoPlay.tc)
			autoPlay.state = "queueing"
			if not ok then
				autoPlay.lastNote = tostring(err)
			end
		end
	end

	autoPlay.tick = autoPlayTick

	function autoPlay.start(tcId)
		if tcId then
			autoPlay.tc = tcId
			S.autoPlayTc = tcId
			save()
		end

		if not autoPlay.tc then
			autoPlay.lastNote = "no time control selected"
			return false
		end

		autoPlay.enabled = true
		autoPlay.nextActionAt = 0
		autoPlay.lastGameId = nil
		autoPlay.lastNote = nil
		autoPlay.state = "queueing"
		save()
		return true
	end

	function autoPlay.stop()
		autoPlay.enabled = false
		autoPlay.state = "off"
		autoPlay.nextActionAt = 0

		if chess.searching and type(chess.cancelSearch) == "function" then
			pcall(chess.cancelSearch)
		end
		save()
		return true
	end

	function autoPlay.status()
		return {
			enabled = autoPlay.enabled,
			tc = autoPlay.tc,
			state = autoPlay.state,
			games = autoPlay.games,
			note = autoPlay.lastNote,
			text = autoPlayDescribe(),
		}
	end

	local function build()
		local playerGui = LocalPlayer:WaitForChild("PlayerGui")

		local old = playerGui:FindFirstChild("AutoChessUI")
		if old then
			old:Destroy()
		end

		local screen = make("ScreenGui", {
			Name = "AutoChessUI",
			ResetOnSpawn = false,
			IgnoreGuiInset = true,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
			DisplayOrder = 10000,
			Parent = playerGui,
		})
		gui.screen = screen

		local panel = make("Frame", {
			Name = "Panel",
			Size = UDim2.fromOffset(268, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Position = UDim2.new(0, 24, 0, 120),
			BackgroundColor3 = THEME.panel,
			BorderSizePixel = 0,
			Visible = not S.guiCollapsed,
			Parent = screen,
		}, {
			corner(12),
			make("UIStroke", { Color = Color3.fromRGB(60, 60, 70), Thickness = 1, Transparency = 0.4 }),
			make("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }),
		})
		gui.panel = panel

		local body = make("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Parent = panel,
		}, {
			make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }),
			make("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
		})

		local content = make("ScrollingFrame", {
			Name = "Content",
			LayoutOrder = 2,
			Size = UDim2.new(1, 0, 0, 400),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 4,
			ScrollBarImageColor3 = THEME.track,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			CanvasSize = UDim2.new(0, 0, 0, 0),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			Parent = body,
		}, {
			make("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
			make("UIPadding", {
				PaddingLeft = UDim.new(0, 2),
				PaddingRight = UDim.new(0, 6),
				PaddingBottom = UDim.new(0, 4),
			}),
		})

		local header = make("TextButton", {
			Name = "Header",
			LayoutOrder = 0,
			Size = UDim2.new(1, 0, 0, 26),
			BackgroundTransparency = 1,
			Text = "",
			AutoButtonColor = false,
			Parent = body,
		})

		label({
			Size = UDim2.new(1, -30, 1, 0),
			Text = "AutoChess",
			Font = Enum.Font.GothamBold,
			TextSize = 14,
			Parent = header,
		})

		local collapseBtn = make("TextButton", {
			Size = UDim2.fromOffset(26, 26),
			Position = UDim2.new(1, -26, 0, 0),
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Text = "—",
			Font = Enum.Font.GothamBold,
			TextSize = 16,
			TextColor3 = THEME.dim,
			Parent = header,
		})

		local tabsRow = make("Frame", {
			Name = "Tabs",
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, 28),
			BackgroundTransparency = 1,
			Parent = body,
		})

		local settingsTabBtn = makeButton(tabsRow, { size = UDim2.new(0.5, -3, 1, 0), text = "Settings", radius = 8 })
		local autoTabBtn = makeButton(tabsRow, {
			size = UDim2.new(0.5, -3, 1, 0),
			position = UDim2.new(0.5, 3, 0, 0),
			text = "Auto play",
			radius = 8,
		})

		local toggleBtn = makeButton(content, { text = "", size = UDim2.new(1, 0, 0, 34), radius = 10 })
		local toggleText = label({
			Size = UDim2.new(1, 0, 1, 0),
			Text = "",
			Font = Enum.Font.GothamBold,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Center,
			Parent = toggleBtn,
		})

		local strengthSection = makeSection(content, "ENGINE STRENGTH")

		local depthSlider = makeSlider(strengthSection, {
			name = "Depth",
			min = 1,
			max = 15,
			step = 1,
			value = S.strength.depth,
			format = function(value)
				return string.format("%d · %s", value, strengthLabel(value))
			end,
			onChanged = function(value)
				S.strength.depth = value
				save()
			end,
		})

		local eloRow = makeButton(strengthSection, { text = "", size = UDim2.new(1, 0, 0, 26), radius = 8 })
		local eloText = label({
			Size = UDim2.new(1, -8, 1, 0),
			Position = UDim2.new(0, 8, 0, 0),
			Text = "",
			TextSize = 12,
			Parent = eloRow,
		})

		local eloSlider = makeSlider(strengthSection, {
			name = "Elo cap",
			min = 1320,
			max = 3190,
			step = 10,
			value = S.strength.elo,
			format = function(value)
				return tostring(value)
			end,
			onChanged = function(value)
				S.strength.elo = value
				save()
			end,
		})

		local timingSection = makeSection(content, "MOVE TIMING")

		local modeRow = make("Frame", {
			Size = UDim2.new(1, 0, 0, 28),
			BackgroundTransparency = 1,
			Parent = timingSection,
		})

		local third = 1 / 3
		local humanModeBtn = makeButton(modeRow, {
			size = UDim2.new(third, -2, 1, 0),
			text = "Human",
			radius = 8,
			textSize = 12,
		})
		local fixedModeBtn = makeButton(modeRow, {
			size = UDim2.new(third, -2, 1, 0),
			position = UDim2.new(third, 0, 0, 0),
			text = "Fixed",
			radius = 8,
			textSize = 12,
		})
		local randomModeBtn = makeButton(modeRow, {
			size = UDim2.new(third, -2, 1, 0),
			position = UDim2.new(third * 2, 2, 0, 0),
			text = "Random",
			radius = 8,
			textSize = 12,
		})

		local fixedSlider = makeSlider(timingSection, {
			name = "Delay",
			min = 0.1,
			max = 5,
			step = 0.05,
			value = S.timing.fixed,
			format = function(value)
				return string.format("%.2f s", value)
			end,
			onChanged = function(value)
				S.timing.fixed = value
				save()
			end,
		})

		local thinkMinSlider = makeSlider(timingSection, {
			name = "Think min",
			min = 0.2,
			max = 20,
			step = 0.1,
			value = S.timing.thinkMin,
			format = function(value)
				return string.format("%.1f s", value)
			end,
			onChanged = function(value)
				S.timing.thinkMin = value
				if S.timing.thinkMax < value then
					S.timing.thinkMax = value
					thinkMaxSlider.setValue(value, true)
				end
				save()
			end,
		})

		local thinkMaxSlider = makeSlider(timingSection, {
			name = "Think max",
			min = 0.5,
			max = 45,
			step = 0.5,
			value = S.timing.thinkMax,
			format = function(value)
				return string.format("%.1f s", value)
			end,
			onChanged = function(value)
				S.timing.thinkMax = value
				if S.timing.thinkMin > value then
					S.timing.thinkMin = value
					thinkMinSlider.setValue(value, true)
				end
				save()
			end,
		})

		local longChanceSlider = makeSlider(timingSection, {
			name = "Long think chance",
			min = 0,
			max = 100,
			step = 1,
			value = S.timing.longChance,
			format = function(value)
				return string.format("%d %%", value)
			end,
			onChanged = function(value)
				S.timing.longChance = value
				save()
			end,
		})

		local minSlider, maxSlider

		minSlider = makeSlider(timingSection, {
			name = "Min delay",
			min = 0.1,
			max = 5,
			step = 0.05,
			value = S.timing.min,
			format = function(value)
				return string.format("%.2f s", value)
			end,
			onChanged = function(value)
				S.timing.min = value
				if S.timing.max < value then
					S.timing.max = value
					maxSlider.setValue(value, true)
				end
				save()
			end,
		})

		maxSlider = makeSlider(timingSection, {
			name = "Max delay",
			min = 0.1,
			max = 5,
			step = 0.05,
			value = S.timing.max,
			format = function(value)
				return string.format("%.2f s", value)
			end,
			onChanged = function(value)
				S.timing.max = value
				if S.timing.min > value then
					S.timing.min = value
					minSlider.setValue(value, true)
				end
				save()
			end,
		})

		local behaviorSection = makeSection(content, "BEHAVIOR")

		local dryRunBtn = makeButton(behaviorSection, { text = "", size = UDim2.new(1, 0, 0, 26), radius = 8 })
		local dryRunText = label({
			Size = UDim2.new(1, -8, 1, 0),
			Position = UDim2.new(0, 8, 0, 0),
			Text = "",
			TextSize = 12,
			Parent = dryRunBtn,
		})

		local onlineBtn = makeButton(behaviorSection, { text = "", size = UDim2.new(1, 0, 0, 26), radius = 8 })
		local onlineText = label({
			Size = UDim2.new(1, -8, 1, 0),
			Position = UDim2.new(0, 8, 0, 0),
			Text = "",
			TextSize = 12,
			Parent = onlineBtn,
		})

		local statusSection = makeSection(content, "STATUS")

		local statusLabel = label({
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Text = "…",
			TextSize = 11,
			TextColor3 = THEME.dim,
			TextWrapped = true,
			Parent = statusSection,
		})

		local settingsWidgets = { toggleBtn, strengthSection, timingSection, behaviorSection, statusSection }

		local playSection = makeSection(content, "TIME CONTROL")
		local tcList = make("ScrollingFrame", {
			Size = UDim2.new(1, 0, 0, 152),
			BackgroundColor3 = Color3.fromRGB(26, 26, 31),
			BorderSizePixel = 0,
			CanvasSize = UDim2.new(0, 0, 0, 0),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			ScrollBarThickness = 4,
			ScrollBarImageColor3 = THEME.dim,
			Parent = playSection,
		}, {
			corner(8),
			make("UIPadding", {
				PaddingTop = UDim.new(0, 4),
				PaddingBottom = UDim.new(0, 4),
				PaddingLeft = UDim.new(0, 4),
				PaddingRight = UDim.new(0, 4),
			}),
			make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
		})

		local tcButtons = {}

		local function refreshTcSelection()
			for id, button in pairs(tcButtons) do
				local selected = id == autoPlay.tc
				button.BackgroundColor3 = selected and THEME.accent or THEME.row
				button.TextColor3 = selected and THEME.onText or THEME.text
			end
		end

		local function selectTc(id)
			if autoPlay.tc == id then
				return
			end
			autoPlay.tc = id
			S.autoPlayTc = id
			refreshTcSelection()
			save()
		end

		for _, tc in ipairs(TIME_CONTROLS) do
			local button = makeButton(tcList, {
				text = tc.label,
				size = UDim2.new(1, -8, 0, 28),
				radius = 6,
				textSize = 12,
			})
			tcButtons[tc.id] = button

			button.Activated:Connect(function()
				selectTc(tc.id)
			end)
		end

		if #TIME_CONTROLS == 0 then
			label({
				Size = UDim2.new(1, -8, 0, 28),
				Text = "No time controls found",
				TextSize = 12,
				TextColor3 = THEME.dim,
				Parent = tcList,
			})
		end

		local autoBtn = makeButton(content, { text = "", size = UDim2.new(1, 0, 0, 36), radius = 10 })
		local autoBtnText = label({
			Size = UDim2.new(1, 0, 1, 0),
			Text = "",
			Font = Enum.Font.GothamBold,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Center,
			Parent = autoBtn,
		})

		local playStatusSection = makeSection(content, "AUTO PLAY STATUS")
		local playStatusLabel = label({
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Text = "…",
			TextSize = 11,
			TextColor3 = THEME.dim,
			TextWrapped = true,
			Parent = playStatusSection,
		})

		local hintLabel = label({
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Text = "Uses the game's own matchmaking. If the server teleports you to another server, re-inject both scripts.",
			TextSize = 10,
			TextColor3 = Color3.fromRGB(120, 120, 130),
			TextWrapped = true,
			Parent = content,
		})

		local playWidgets = { playSection, autoBtn, playStatusSection, hintLabel }

		local dot = make("TextButton", {
			Name = "Dot",
			Size = UDim2.fromOffset(56, 56),
			Position = UDim2.new(0, 24, 0, 220),
			BackgroundColor3 = THEME.accent,
			Text = "♟",
			Font = Enum.Font.GothamBold,
			TextSize = 24,
			TextColor3 = THEME.onText,
			AutoButtonColor = false,
			Visible = S.guiCollapsed and true or false,
			Parent = screen,
		}, {
			make("UICorner", { CornerRadius = UDim.new(1, 0) }),
			make("UIStroke", { Color = Color3.fromRGB(255, 255, 255), Thickness = 1, Transparency = 0.6 }),
		})
		gui.dot = dot

		if type(S.guiPos) == "table" and S.guiPos.x and S.guiPos.y then
			panel.Position = UDim2.fromOffset(S.guiPos.x, S.guiPos.y)
		end
		if type(S.dotPos) == "table" and S.dotPos.x and S.dotPos.y then
			dot.Position = UDim2.fromOffset(S.dotPos.x, S.dotPos.y)
		end

		local function refreshToggle()
			local on = S.enabled == true
			toggleBtn.BackgroundColor3 = on and THEME.accent or THEME.accentOff
			toggleText.Text = on and "PLAYING · ON" or "PAUSED · OFF"
			toggleText.TextColor3 = on and THEME.onText or THEME.text
			dot.BackgroundColor3 = (on or autoPlay.enabled) and THEME.accent or THEME.accentOff
		end

		local function refreshMode()
			local mode = S.timing.mode
			local human = mode == "human"
			local fixed = mode == "fixed"

			local function paint(button, active)
				button.BackgroundColor3 = active and THEME.accent or THEME.row
				button.TextColor3 = active and THEME.onText or THEME.text
			end

			paint(humanModeBtn, human)
			paint(fixedModeBtn, fixed)
			paint(randomModeBtn, not human and not fixed)

			thinkMinSlider.row.Visible = human
			thinkMaxSlider.row.Visible = human
			longChanceSlider.row.Visible = human
			fixedSlider.row.Visible = fixed
			minSlider.row.Visible = not human and not fixed
			maxSlider.row.Visible = not human and not fixed
		end

		local function refreshToggles()
			local eloOn = S.strength.eloEnabled == true
			local publicApi = isPublicApi()

			eloRow.BackgroundColor3 = eloOn and THEME.row or THEME.panel
			eloText.Text = string.format("[%s] Elo cap%s",
				eloOn and "x" or " ", publicApi and " — not supported by this API" or "")
			eloText.TextColor3 = eloOn and THEME.text or THEME.dim
			eloSlider.row.Visible = eloOn and not publicApi

			dryRunBtn.BackgroundColor3 = S.dryRun and THEME.row or THEME.panel
			dryRunText.Text = string.format("[%s] Calculate only, don't play", S.dryRun and "x" or " ")
			dryRunText.TextColor3 = S.dryRun and THEME.text or THEME.dim

			onlineBtn.BackgroundColor3 = S.kinds.online and THEME.row or THEME.panel
			onlineText.Text = string.format("[%s] Play online games too", S.kinds.online and "x" or " ")
			onlineText.TextColor3 = S.kinds.online and THEME.text or THEME.dim
		end

		local function refreshAutoPlay()
			local on = autoPlay.enabled == true
			autoBtn.BackgroundColor3 = on and THEME.accent or THEME.accentOff
			autoBtnText.Text = on and "AUTO PLAY: ON" or "AUTO PLAY: OFF"
			autoBtnText.TextColor3 = on and THEME.onText or THEME.text
			refreshTcSelection()
			refreshToggle()
		end

		local currentTab = "settings"

		local function showTab(name)
			currentTab = name
			local settings = name == "settings"

			for _, widget in ipairs(settingsWidgets) do
				widget.Visible = settings
			end
			for _, widget in ipairs(playWidgets) do
				widget.Visible = not settings
			end

			settingsTabBtn.BackgroundColor3 = settings and THEME.accent or THEME.row
			settingsTabBtn.TextColor3 = settings and THEME.onText or THEME.text
			autoTabBtn.BackgroundColor3 = (not settings) and THEME.accent or THEME.row
			autoTabBtn.TextColor3 = (not settings) and THEME.onText or THEME.text
		end

		local function refreshAll()
			refreshMode()
			refreshToggles()
			refreshAutoPlay()
			depthSlider.refresh()
			eloSlider.refresh()
			fixedSlider.refresh()
			minSlider.refresh()
			maxSlider.refresh()
			thinkMinSlider.refresh()
			thinkMaxSlider.refresh()
			longChanceSlider.refresh()
			showTab(currentTab)
		end

		gui.refresh = refreshAll
		gui.refreshToggle = refreshToggle
		gui.refreshAutoPlay = refreshAutoPlay
		gui.showTab = showTab

		toggleBtn.Activated:Connect(function()
			if type(AutoChess.setEnabled) == "function" then
				AutoChess.setEnabled(not (S.enabled == true))
			else
				S.enabled = not S.enabled
			end
			refreshToggle()
			save()
		end)

		settingsTabBtn.Activated:Connect(function()
			showTab("settings")
		end)

		autoTabBtn.Activated:Connect(function()
			showTab("auto")
		end)

		humanModeBtn.Activated:Connect(function()
			S.timing.mode = "human"
			refreshMode()
			save()
		end)

		fixedModeBtn.Activated:Connect(function()
			S.timing.mode = "fixed"
			refreshMode()
			save()
		end)

		randomModeBtn.Activated:Connect(function()
			S.timing.mode = "random"
			refreshMode()
			save()
		end)

		eloRow.Activated:Connect(function()
			S.strength.eloEnabled = not (S.strength.eloEnabled == true)
			refreshToggles()
			save()
		end)

		dryRunBtn.Activated:Connect(function()
			S.dryRun = not (S.dryRun == true)
			refreshToggles()
			save()
		end)

		onlineBtn.Activated:Connect(function()
			S.kinds.online = not (S.kinds.online == true)
			refreshToggles()
			save()
		end)

		autoBtn.Activated:Connect(function()
			if autoPlay.enabled then
				autoPlay.stop()
			else
				autoPlay.start(autoPlay.tc)
			end
			refreshAutoPlay()
		end)

		local function setCollapsed(collapsed)
			S.guiCollapsed = collapsed
			panel.Visible = not collapsed
			dot.Visible = collapsed
			save()
		end

		gui.setCollapsed = setCollapsed

		collapseBtn.Activated:Connect(function()
			setCollapsed(true)
		end)

		local function pointOf(input)
			local position = input.Position
			if typeof then
				local kind = typeof(position)
				if kind == "Vector3" then
					return position.X, position.Y
				elseif kind == "Vector2" then
					return position.X, position.Y
				end
			end
			return position.X or 0, position.Y or 0
		end

		do
			local dragging, startX, startY, baseX, baseY = false, 0, 0, 0, 0

			header.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch then
					dragging = true
					startX, startY = pointOf(input)
					baseX = panel.Position.X.Offset
					baseY = panel.Position.Y.Offset
				end
			end)

			header.InputEnded:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch then
					dragging = false
				end
			end)

			UserInputService.InputChanged:Connect(function(input)
				if not dragging then
					return
				end
				if input.UserInputType ~= Enum.UserInputType.MouseMovement
					and input.UserInputType ~= Enum.UserInputType.Touch then
					return
				end
				local x, y = pointOf(input)
				panel.Position = UDim2.fromOffset(baseX + (x - startX), baseY + (y - startY))
			end)

			UserInputService.InputEnded:Connect(function(input)
				if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch) then
					dragging = false
					S.guiPos = { x = panel.Position.X.Offset, y = panel.Position.Y.Offset }
					save()
				end
			end)
		end

		do
			local dragging, moved = false, false
			local startX, startY, baseX, baseY = 0, 0, 0, 0

			dot.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch then
					dragging = true
					moved = false
					startX, startY = pointOf(input)
					baseX = dot.Position.X.Offset
					baseY = dot.Position.Y.Offset
				end
			end)

			UserInputService.InputChanged:Connect(function(input)
				if not dragging then
					return
				end
				if input.UserInputType ~= Enum.UserInputType.MouseMovement
					and input.UserInputType ~= Enum.UserInputType.Touch then
					return
				end
				local x, y = pointOf(input)
				local dx, dy = x - startX, y - startY
				if math.abs(dx) + math.abs(dy) > 6 then
					moved = true
				end
				if moved then
					dot.Position = UDim2.fromOffset(baseX + dx, baseY + dy)
				end
			end)

			UserInputService.InputEnded:Connect(function(input)
				if not dragging then
					return
				end
				if input.UserInputType ~= Enum.UserInputType.MouseButton1
					and input.UserInputType ~= Enum.UserInputType.Touch then
					return
				end
				dragging = false
				if moved then
					S.dotPos = { x = dot.Position.X.Offset, y = dot.Position.Y.Offset }
					save()
				else
					setCollapsed(false)
				end
			end)
		end

		refreshAll()

		task.spawn(function()
			while screen.Parent do
				task.wait(0.5)
				if S.enabled ~= gui._lastEnabled then
					gui._lastEnabled = S.enabled
					refreshToggle()
				end
			end
		end)

		task.spawn(function()
			while screen.Parent do
				task.wait(2)
				pcall(autoPlayTick)
				if panel.Visible then
					refreshAutoPlay()
				end
			end
		end)

		task.spawn(function()
			while screen.Parent do
				task.wait(0.5)
				if panel.Visible then
					if currentTab == "auto" then
						local lines = { autoPlayDescribe() }
						table.insert(lines, string.format("selected: %s · games: %d",
							tostring(autoPlay.tc or "—"), autoPlay.games))
						table.insert(lines, string.format("depth %d · %s",
							math.floor(clampNumber(S.strength.depth, 1, 15)),
							S.dryRun and "DRY RUN (not playing)" or "live"))
						if autoPlay.lastNote then
							table.insert(lines, "note: " .. tostring(autoPlay.lastNote))
						end
						playStatusLabel.Text = table.concat(lines, "\n")
					else
						local info = {}
						if type(AutoChess.snapshot) == "function" then
							local ok, value = pcall(AutoChess.snapshot)
							if ok and type(value) == "table" then
								info = value
							end
						end

						local turn = "—"
						if info.isMyTurn == true then
							turn = "my move"
						elseif info.isMyTurn == false then
							turn = "opponent's move"
						end

						local timing
						if S.timing.mode == "fixed" then
							timing = string.format("fixed %.2f s", S.timing.fixed)
						else
							timing = string.format("random %.2f–%.2f s",
								math.min(S.timing.min, S.timing.max),
								math.max(S.timing.min, S.timing.max))
						end

						local lines = {
							string.format("%s · %s · moves %s", tostring(info.kind or "—"), turn, tostring(info.moves or 0)),
							string.format("depth %d · %s", math.floor(clampNumber(S.strength.depth, 1, 15)), timing),
							string.format("played %s · errors %s", tostring(info.movesPlayed or 0), tostring(info.failures or 0)),
						}
						if info.lastPath then
							table.insert(lines, "path: " .. tostring(info.lastPath))
						end
						if info.lastReason then
							table.insert(lines, "waiting: " .. tostring(info.lastReason))
						end
						if info.lastError then
							table.insert(lines, "error: " .. tostring(info.lastError))
						end

						statusLabel.Text = table.concat(lines, "\n")
					end
				end
			end
		end)

		return screen
	end

	local api = {
		settings = S,
		autoPlay = autoPlay,
		timeControls = TIME_CONTROLS,
		show = function()
			gui.setCollapsed(false)
		end,
		hide = function()
			gui.setCollapsed(true)
		end,
		toggle = function()
			gui.setCollapsed(not S.guiCollapsed)
			return S.guiCollapsed
		end,
		tab = function(name)
			if gui.showTab then
				gui.showTab(name)
			end
		end,
		refresh = function()
			if gui.refresh then
				gui.refresh()
			end
		end,
		destroy = function()
			if gui.screen then
				gui.screen:Destroy()
				gui.screen = nil
			end
		end,
	}

	local buildOk, buildResult = xpcall(build, function(err)
		return tostring(err) .. "\n" .. tostring(debug and debug.traceback and debug.traceback() or "")
	end)

	if not buildOk then
		error("[AutoChessGui] build failed: " .. tostring(buildResult))
	end

	gui.screen = buildResult

	guiApi = api
end

api.gui = guiApi

if type(getgenv) == "function" then
	getgenv().AutoChess = api
	getgenv().AutoChessGui = guiApi
end

return api
