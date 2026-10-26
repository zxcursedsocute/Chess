--!nonstrict
-- ============================================================================
--  ChessAutoClient.lua  —  ЛОГИКА АВТОИГРЫ (без интерфейса)
-- ============================================================================
--  Отдельный файл ChessAutoGui.lua рисует панель и меняет AutoChess.settings.
--  Этот файл можно запускать и без GUI — тогда работают значения по умолчанию.
--
--  Консоль: AutoChess.status() / tryNow() / move("e2e4") / sync() / resend()
-- ============================================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

-- ============================================================================
--  Конфиг по умолчанию (всё это потом меняется в GUI)
-- ============================================================================
local CFG = {
	apiUrl = "https://stockfish.online/api/s/v2.php",
	settingsFile = "AutoChessSettings.json",
	useFileSettings = true,     -- сохранять настройки между запусками (если умеет экзекьютор)
	verbose = true,
	logWaitReasons = true,
}

local DEFAULT_SETTINGS = {
	enabled = true,
	dryRun = false,

	kinds = { bot = true, online = true, puzzle = false, rush = false, tutorial = false },

	-- сила
	strength = {
		depth = 12,        -- 1..15 — лимит публичного stockfish.online
		eloEnabled = false,
		elo = 2000,        -- работает только на своём apiUrl
	},

	-- тайминг
	timing = {
		mode = "random",   -- "fixed" | "random"
		fixed = 0.6,       -- сек
		min = 0.35,
		max = 0.9,
	},

	cooldown = 1.1,        -- мин. между запросами к API
	poll = 0.25,           -- частота проверки «мой ли ход»
	resendAfter = 3.5,     -- онлайн: через сколько переслать ход
	maxSendAttempts = 3,
	autoRematch = false,
	guiCollapsed = false,   -- первый запуск: показываем панель целиком
	guiPos = nil,          -- {x, y} панели
	dotPos = nil,          -- {x, y} точки
}

-- ============================================================================
--  Настройки (+ загрузка с диска)
-- ============================================================================
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

-- ============================================================================
--  HTTP экзекьютора
-- ============================================================================
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

-- ============================================================================
--  Клиент игры
-- ============================================================================
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

if not loadSettings() and CFG.verbose then
	print("[AutoChess] настройки по умолчанию")
end

-- ============================================================================
--  Утилиты
-- ============================================================================
local state = {
	lastFen = nil,
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
}

local function log(...)
	if CFG.verbose then
		print("[AutoChess]", ...)
	end
end

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

-- ============================================================================
--  Сила и тайминг
-- ============================================================================
local function clampNumber(value, low, high)
	value = tonumber(value) or low
	return math.max(low, math.min(high, value))
end

-- Пауза перед ходом по текущим настройкам тайминга.
local function computeDelay()
	local timing = S.timing

	if timing.mode == "fixed" then
		return clampNumber(timing.fixed, 0.05, 10)
	end

	local low = clampNumber(timing.min, 0.05, 10)
	local high = clampNumber(timing.max, 0.05, 10)
	if low > high then
		low, high = high, low
	end
	return low + math.random() * (high - low)
end

-- Глубина 1..15 -> «человеческая» подпись
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

	-- Elo понимает только свой сервис (stockfish.online игнорирует лишние поля)
	if S.strength.eloEnabled and not isPublicApi() then
		url = url .. string.format("&elo=%d", math.floor(clampNumber(S.strength.elo, 1320, 3190)))
	end

	if not isPublicApi() then
		url = url .. "&format=lines"
	end

	return url
end

-- ============================================================================
--  StockfishApi
-- ============================================================================
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

-- ============================================================================
--  Отправка хода — существующими путями клиента
-- ============================================================================
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

-- Порядок: onBoardMove (родной обработчик, упаковывает мув) -> playMove/sendUci
-- -> сырой send -> debug. Ручной пакет {type="move", uci=...} сервер игнорирует.
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

-- ============================================================================
--  Состояние / условия
-- ============================================================================
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
	if not CFG.logWaitReasons then
		return
	end
	if reason == state.lastReasonShown and os.clock() - state.lastReasonAt < 4 then
		return
	end
	state.lastReasonShown = reason
	state.lastReasonAt = os.clock()
	log("жду:", reason)
end

-- ============================================================================
--  Один шаг
-- ============================================================================
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

	if not force and fen == state.lastFen then
		return report
	end
	state.lastFen = fen

	local uci, askErr = askStockfish(fen, force)
	report.apiError = askErr
	report.uci = uci

	if not uci then
		state.failures += 1
		log("API:", askErr or "пустой ответ")
		state.lastFen = nil
		if not force then
			task.wait(1.0)
		end
		return report
	end
	state.lastApiUci = uci

	if S.dryRun then
		log("dryRun: ход", uci, "не играю")
		report.ok = true
		report.dryRun = true
		return report
	end

	if not force then
		local pause = computeDelay()
		state.lastDelay = pause
		task.wait(pause)
	end

	if chess.session ~= session or session.over or fenOf(session) ~= fen then
		state.lastFen = nil
		report.reason = "позиция сменилась, пока думали"
		return report
	end

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
		log(string.format("ход %d: %s (ply %d, %s)", state.movesPlayed, uci, #session.ucis + 1, session.kind))
		report.ok = true
	else
		state.failures += 1
		log("не удалось сыграть", uci, "—", tostring(state.lastError))
		state.lastFen = nil
		if not force then
			task.wait(0.6)
		end
	end

	return report
end

-- Онлайн: если сервер не подтвердил ход — досылаем тот же
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
		log(string.format("сервер не подтвердил %s за %d попыток — жду смены позиции", stuck, maxAttempts))
		return
	end

	if not canAct(session) then
		state.pendingUci = nil
		return
	end

	state.sendAttempts += 1
	state.pendingAt = os.clock()
	log(string.format("пересылаю %s (попытка %d/%d)", state.pendingUci, state.sendAttempts, maxAttempts))
	if not playMove(session, state.pendingUci) then
		log("переотправка не удалась:", tostring(state.lastError))
	end
end

local function loop()
	while true do
		task.wait(clampNumber(S.poll, 0.05, 2))

		if S.enabled then
			pcall(resendIfStuck)
			local ok, err = pcall(step, false)
			if not ok then
				log("ошибка шага:", tostring(err))
				state.lastError = tostring(err)
				state.lastFen = nil
				task.wait(1.0)
			end
		end
	end
end

-- ============================================================================
--  Публичное API (консоль)
-- ============================================================================
local api = {
	config = CFG,
	settings = S,
	state = state,
	chess = chess,
	ask = askStockfish,
	play = playMove,
	delay = computeDelay,
	save = saveSettings,
}

function api.status()
	local info = snapshot()

	print("========== AutoChess status ==========")
	local fields = { "enabled", "dryRun", "kind", "kindsAllowed", "over", "moves", "viewPly",
		"myColor", "isMyTurn", "movesPlayed", "failures", "lastApiMove", "lastPath",
		"lastReason", "lastError", "depth", "timingMode" }
	for _, key in ipairs(fields) do
		print(string.format("  %-14s %s", key, tostring(info[key])))
	end
	print("  fen            " .. tostring(info.fen))
	print("======================================")

	return info
end

function api.tryNow()
	log("=== принудительный ход ===")
	local report = step(true)
	print("  fen        ", report.fen)
	print("  api move   ", tostring(report.uci))
	print("  api error  ", tostring(report.apiError))
	print("  played     ", tostring(report.played))
	if report.reason then
		print("  причина    ", report.reason)
	end
	if state.lastError then
		print("  lastError  ", state.lastError)
	end
	return report
end

function api.move(uci)
	uci = string.lower(tostring(uci or ""))
	if not isValidUci(uci) then
		log("move: нужен uci вида e2e4")
		return false
	end
	local session = chess.session
	if not session then
		return false
	end
	state.lastPath = nil
	local played = playMove(session, uci)
	log(string.format("move(%s) -> %s, путь=%s, ошибка=%s",
		uci, tostring(played), tostring(state.lastPath), tostring(state.lastError)))
	return played
end

function api.sync()
	if type(chess.send) ~= "function" then
		return false
	end
	chess.send({ type = "sync" })
	state.pendingUci = nil
	state.pendingFen = nil
	log("отправил {type=sync}")
	return true
end

function api.resend()
	local before = state.sendAttempts
	resendIfStuck()
	log(string.format("resend: попыток было %d, стало %d", before, state.sendAttempts))
	return state.sendAttempts
end

function api.setEnabled(value)
	S.enabled = value == true
	state.lastFen = nil
	saveSettings()
	return S.enabled
end

-- снимок состояния для внешнего GUI
api.snapshot = snapshot
api.canAct = canAct

-- ============================================================================
--  Тумблер вкл/выкл
-- ============================================================================
UserInputService.InputBegan:Connect(function(input, processed)
	if processed or input.KeyCode ~= Enum.KeyCode.RightShift then
		return
	end
	api.setEnabled(not S.enabled)
	log(S.enabled and "ВКЛ" or "ВЫКЛ")
	if type(chess.toast) == "function" then
		pcall(chess.toast, S.enabled and "AutoChess: ON" or "AutoChess: OFF")
	end
end)

-- ============================================================================
--  Старт
-- ============================================================================
if type(getgenv) == "function" then
	getgenv().AutoChess = api
end

local info = snapshot()
log(string.format("логика запущена | kind=%s | глубина %d | тайминг %s",
	tostring(info.kind), S.strength.depth,
	S.timing.mode == "fixed" and string.format("фикс %.2f", S.timing.fixed)
		or string.format("рандом %.2f-%.2f", S.timing.min, S.timing.max)))
log("RightShift — ON/OFF | AutoChess.status() | GUI: запусти ChessAutoGui.lua")

if not S.kinds[info.kind] then
	log(string.format("ВНИМАНИЕ: сейчас '%s' — ходить не буду", tostring(info.kind)))
end

task.spawn(loop)

return api
