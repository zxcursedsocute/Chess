--!nonstrict
-- ============================================================================
--  ChessAutoGui.lua  —  GUI for AutoChess (English)
-- ============================================================================
--  Run SECOND, after ChessAutoClient.lua.
--  Does not duplicate game logic: reads/writes AutoChess.settings only.
--
--  Tabs:
--    SETTINGS  — on/off, engine strength, move timing, status
--    AUTO PLAY — pick a time control, press AUTO PLAY: ON, it queues by itself
--
--  Console: AutoChessGui.toggle() / show() / hide() / refresh()
--           AutoChessGui.autoPlay.start("3+2") / .stop() / .state()
-- ============================================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local execEnv = (getfenv and getfenv(0)) or _G

-- ============================================================================
--  Wait for the logic module
-- ============================================================================
local function waitForLogic(timeout)
	local deadline = os.clock() + (timeout or 30)
	while os.clock() < deadline do
		local api = type(getgenv) == "function" and getgenv().AutoChess or execEnv.AutoChess
		if type(api) == "table" and type(api.settings) == "table" then
			return api
		end
		task.wait(0.25)
	end
	return nil
end

-- lower it before running if needed: getgenv().AutoChessGuiWait = 5
local WAIT_SECONDS = tonumber(
	(type(getgenv) == "function" and getgenv().AutoChessGuiWait) or execEnv.AutoChessGuiWait
) or 30

local AutoChess = waitForLogic(WAIT_SECONDS)

if not AutoChess then
	local canRead = type(execEnv.readfile) == "function" and type(execEnv.loadstring) == "function"
	if canRead then
		for _, name in ipairs({ "ChessAutoClient.lua", "chess-engine/client/ChessAutoClient.lua" }) do
			local ok, body = pcall(execEnv.readfile, name)
			if ok and type(body) == "string" and #body > 0 then
				local chunk = loadstring(body)
				if chunk then
					pcall(chunk)
					AutoChess = waitForLogic(15)
					if AutoChess then
						break
					end
				end
			end
		end
	end
end

if not AutoChess then
	error("[AutoChessGui] run ChessAutoClient.lua first (it holds the logic), then this file")
end

local S = AutoChess.settings
local CFG = AutoChess.config or {}
local chess = AutoChess.chess or {}

-- defaults for older logic versions
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

-- ============================================================================
--  Time controls from the game config
-- ============================================================================
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

-- ============================================================================
--  Theme + widget helpers
-- ============================================================================
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

-- ============================================================================
--  AUTO PLAY controller
-- ============================================================================
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

	-- match in progress: count it once
	if session.kind == "online" and not session.over then
		autoPlay.state = "inGame"
		if session.id ~= autoPlay.lastGameId then
			autoPlay.lastGameId = session.id
			autoPlay.games += 1
		end
		return
	end

	-- bot / puzzle / analysis: do not interfere
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

	-- previous online game finished -> ask the client for a new one
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

	-- idle and not searching -> start the queue
	if not chess.searching and type(chess.startSearch) == "function" and autoPlay.tc then
		autoPlay.nextActionAt = now + 5
		local ok, err = pcall(chess.startSearch, autoPlay.tc)
		autoPlay.state = "queueing"
		if not ok then
			autoPlay.lastNote = tostring(err)
		end
	end
end

-- exposed so the console can force one matchmaking decision: AutoChessGui.autoPlay.tick()
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

-- ============================================================================
--  Build UI
-- ============================================================================
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

	-- ---------------- panel ----------------
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

	-- header (drag handle)
	local header = make("TextButton", {
		Name = "Header",
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

	-- ---------------- tabs ----------------
	local tabsRow = make("Frame", {
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

	-- ============ SETTINGS TAB ============
	local toggleBtn = makeButton(body, { text = "", size = UDim2.new(1, 0, 0, 34), radius = 10 })
	local toggleText = label({
		Size = UDim2.new(1, 0, 1, 0),
		Text = "",
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = toggleBtn,
	})

	local strengthSection = makeSection(body, "ENGINE STRENGTH")

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

	local timingSection = makeSection(body, "MOVE TIMING")

	local modeRow = make("Frame", {
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundTransparency = 1,
		Parent = timingSection,
	})

	local fixedModeBtn = makeButton(modeRow, { size = UDim2.new(0.5, -3, 1, 0), text = "Fixed", radius = 8 })
	local randomModeBtn = makeButton(modeRow, {
		size = UDim2.new(0.5, -3, 1, 0),
		position = UDim2.new(0.5, 3, 0, 0),
		text = "Random",
		radius = 8,
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

	local behaviorSection = makeSection(body, "BEHAVIOR")

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

	local statusSection = makeSection(body, "STATUS")

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

	-- ============ AUTO PLAY TAB ============
	local playSection = makeSection(body, "TIME CONTROL")
	local tcList = make("ScrollingFrame", {
		Size = UDim2.new(1, 0, 0, 152),
		BackgroundColor3 = Color3.fromRGB(26, 26, 31),
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(0, 0, 0, 0),
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

	local autoBtn = makeButton(body, { text = "", size = UDim2.new(1, 0, 0, 36), radius = 10 })
	local autoBtnText = label({
		Size = UDim2.new(1, 0, 1, 0),
		Text = "",
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = autoBtn,
	})

	local playStatusSection = makeSection(body, "AUTO PLAY STATUS")
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
		Parent = body,
	})

	local playWidgets = { playSection, autoBtn, playStatusSection, hintLabel }

	-- ============ rounded dot ============
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

	-- restore positions
	if type(S.guiPos) == "table" and S.guiPos.x and S.guiPos.y then
		panel.Position = UDim2.fromOffset(S.guiPos.x, S.guiPos.y)
	end
	if type(S.dotPos) == "table" and S.dotPos.x and S.dotPos.y then
		dot.Position = UDim2.fromOffset(S.dotPos.x, S.dotPos.y)
	end

	-- ============ state rendering ============
	local function refreshToggle()
		local on = S.enabled == true
		toggleBtn.BackgroundColor3 = on and THEME.accent or THEME.accentOff
		toggleText.Text = on and "PLAYING · ON" or "PAUSED · OFF"
		toggleText.TextColor3 = on and THEME.onText or THEME.text
		dot.BackgroundColor3 = (on or autoPlay.enabled) and THEME.accent or THEME.accentOff
	end

	local function refreshMode()
		local fixed = S.timing.mode == "fixed"
		fixedModeBtn.BackgroundColor3 = fixed and THEME.accent or THEME.row
		fixedModeBtn.TextColor3 = fixed and THEME.onText or THEME.text
		randomModeBtn.BackgroundColor3 = (not fixed) and THEME.accent or THEME.row
		randomModeBtn.TextColor3 = (not fixed) and THEME.onText or THEME.text

		fixedSlider.row.Visible = fixed
		minSlider.row.Visible = not fixed
		maxSlider.row.Visible = not fixed
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
		showTab(currentTab)
	end

	gui.refresh = refreshAll
	gui.refreshToggle = refreshToggle
	gui.refreshAutoPlay = refreshAutoPlay
	gui.showTab = showTab

	-- ============ events ============
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

	-- collapse / expand
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

	-- drag panel by header
	do
		local dragging, dragStart, startPos = false, nil, nil

		header.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				dragStart = input.Position
				startPos = panel.Position
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
			local delta = input.Position - dragStart
			panel.Position = UDim2.fromOffset(startPos.X.Offset + delta.X, startPos.Y.Offset + delta.Y)
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

	-- dot: tap to expand, drag to move
	do
		local dragging, moved, dragStart, startPos = false, false, nil, nil

		dot.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				moved = false
				dragStart = input.Position
				startPos = dot.Position
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
			local delta = input.Position - dragStart
			if math.abs(delta.X) + math.abs(delta.Y) > 6 then
				moved = true
			end
			if moved then
				dot.Position = UDim2.fromOffset(startPos.X.Offset + delta.X, startPos.Y.Offset + delta.Y)
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

	-- ============ refresh loops ============
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

-- ============================================================================
--  Public API
-- ============================================================================
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

gui.screen = build()

if type(getgenv) == "function" then
	getgenv().AutoChessGui = api
end

print(string.format("[AutoChessGui] ready | %d time controls | AutoChessGui.toggle()", #TIME_CONTROLS))

return api
