-- ARMY CLIENT
-- LocalScript: place in StarterPlayer > StarterPlayerScripts
--
-- Tap the gear button to show / hide the menu (AIRCRAFT, RADAR, LOCK UI, TUTORIAL, DELETE CLIENT). The menu, the gear
-- button and the aircraft panel can all be dragged (the menu by its title) unless
-- LOCK UI is on.
-- Sit in a VehicleSeat, then tap AIRCRAFT.
-- Below 7 studs (on the ground) aircraft stays on for 7 seconds, then turns off.
-- If you get 7+ studs up before the timer runs out it stays on (the timer resets).
--
-- The plane keeps flying under its own scripts (guns, thrust...). This script
-- controls the plane's ROTATION, so it can really loop and barrel roll:
--   Drag the screen (touch, or hold right mouse) :
--       left/right = steer left/right, up/down = pitch with NO limit
--       (go up and over and the plane flips upside down through the loop)
--   L YAW / R YAW buttons (or Q / E) : barrel roll the plane left / right, endlessly
-- The camera follows the plane's heading and pitch but never rolls.
-- Below 7 studs all of these controls fail (nothing happens) until you are 7+ studs up.

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- SETTINGS
local MIN_AIRCRAFT_HEIGHT = 7         -- below this many studs you count as on the ground
local GROUND_TIMEOUT = 7              -- seconds aircraft stays on while on the ground
local BUTTON_ROLL_SPEED = math.rad(180) -- deg/sec the plane barrel rolls while holding L/R YAW
local DRAG_SENSITIVITY = 0.006        -- radians per pixel of drag
local INPUT_SMOOTHING = 10
local CAMERA_SMOOTHING = 12           -- trailing swing of the camera
local CAMERA_DISTANCE = 45
local CAMERA_HEIGHT = 6

local RWR_RANGE = 1500                -- studs the RWR can see enemies
local RWR_LOCK_ANGLE = 12               -- degrees: enemy aiming this close at you = LOCK warning
local RWR_SIZE = 120                    -- pixels, diameter of the radar circle
local ELEV_SIZE = 46                   -- pixels, diameter of the small height circle under the radar

local DRAG_THRESHOLD = 12

-- STATE
local camera = workspace.CurrentCamera
local character, humanoid
local aircraftOn = false
local uiLocked = false
local menuOpen = false

local aircraftConnection
local cameraConnection
local seatConnection
local aircraftSeat
local aircraftRoot
local aircraftIgnore = {}

local btnYaw = 0
local keyRoll = 0
local yawRate = 0
local dragYaw, dragPitch = 0, 0
local camRot = CFrame.new()
local camRotSmooth = CFrame.new()
local rollAngle = 0
local lowTime = 0
local airborne = false  -- true while aircraft is on AND the plane is 7+ studs above the ground
local radarEnabled = true
local rwrBlips = {}      -- [Player] = blip Frame on the RWR
local lastShown = -1
local seatToRoot = CFrame.new()

local clientConnections = {} -- every global connection, so DELETE CLIENT can remove them all
local function track(conn)
	table.insert(clientConnections, conn)
	return conn
end

local onSeatChanged -- assigned below

local function setupCharacter(char)
	character = char
	humanoid = char:WaitForChild("Humanoid")

	if seatConnection then seatConnection:Disconnect() end
	seatConnection = humanoid:GetPropertyChangedSignal("SeatPart"):Connect(function()
		if onSeatChanged then onSeatChanged() end
	end)
end

-- GUI
local oldGui = playerGui:FindFirstChild("ArmyClient")
if oldGui then oldGui:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = "ArmyClient"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 10
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling -- children always draw above their parent
gui.Parent = playerGui

local function button(parent, text, size, position, color)
	local b = Instance.new("TextButton")
	b.Size = size
	b.Position = position
	b.BackgroundColor3 = color or Color3.fromRGB(40, 75, 120)
	b.BorderSizePixel = 0
	b.Text = text
	b.TextColor3 = Color3.new(1, 1, 1)
	b.TextScaled = true
	b.Font = Enum.Font.GothamBold
	b.Active = true
	b.AutoButtonColor = true
	b.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = b

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 4)
	pad.PaddingRight = UDim.new(0, 4)
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 4)
	pad.Parent = b

	return b
end

-- Settings button (tap = show / hide the menu)
local settingsButton = button(
	gui, "⚙️",
	UDim2.fromOffset(52, 52),
	UDim2.new(0, 15, 0.5, -26),
	Color3.fromRGB(30, 30, 38)
)
settingsButton.TextColor3 = Color3.fromRGB(235, 235, 240)

-- Round gear button
local settingsCorner = settingsButton:FindFirstChildOfClass("UICorner")
if settingsCorner then
	settingsCorner.CornerRadius = UDim.new(1, 0)
end

-- MENU
local menu = Instance.new("Frame")
menu.Name = "ArmyMenu"
menu.Size = UDim2.fromOffset(215, 290)
menu.Position = UDim2.new(0, 85, 0.5, -145)
menu.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
menu.BorderSizePixel = 0
menu.Visible = false
menu.Active = true
menu.Parent = gui

Instance.new("UICorner", menu).CornerRadius = UDim.new(0, 10)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 34)
title.BackgroundTransparency = 1
title.Text = "ARMY CLIENT"
title.Active = true
title.TextColor3 = Color3.new(1, 1, 1)
title.TextScaled = true
title.Font = Enum.Font.GothamBold
title.Parent = menu

local aircraftButton = button(
	menu, "AIRCRAFT: OFF",
	UDim2.new(1, -20, 0, 38),
	UDim2.fromOffset(10, 42)
)

local radarButton = button(
	menu, "RADAR: ON",
	UDim2.new(1, -20, 0, 38),
	UDim2.fromOffset(10, 86),
	Color3.fromRGB(40, 120, 60)
)

local lockButton = button(
	menu, "LOCK UI: OFF",
	UDim2.new(1, -20, 0, 38),
	UDim2.fromOffset(10, 130),
	Color3.fromRGB(70, 70, 70)
)

local tutorialButton = button(
	menu, "TUTORIAL",
	UDim2.new(1, -20, 0, 38),
	UDim2.fromOffset(10, 174),
	Color3.fromRGB(40, 90, 150)
)

local deleteButton = button(
	menu, "DELETE CLIENT",
	UDim2.new(1, -20, 0, 38),
	UDim2.fromOffset(10, 218),
	Color3.fromRGB(150, 40, 40)
)

-- SETTINGS LOOK - TOP GUN theme (gray + black) (only the style of the menu + gear; the buttons are untouched)
local ACCENT_A = Color3.fromRGB(170, 172, 178) -- gray (was yellow)
local ACCENT_B = Color3.fromRGB(8, 8, 10)      -- black (was orange)
local accentSequence = ColorSequence.new({
	ColorSequenceKeypoint.new(0, ACCENT_A),
	ColorSequenceKeypoint.new(0.5, ACCENT_B),
	ColorSequenceKeypoint.new(1, ACCENT_A),
})

-- menu body: dark glass with a soft top-to-bottom shade
menu.BackgroundColor3 = Color3.new(1, 1, 1)
menu.BackgroundTransparency = 0.04

local menuCorner = menu:FindFirstChildOfClass("UICorner")
if menuCorner then
	menuCorner.CornerRadius = UDim.new(0, 14)
end

local menuShade = Instance.new("UIGradient")
menuShade.Rotation = 90
menuShade.Color = ColorSequence.new(Color3.fromRGB(22, 36, 66), Color3.fromRGB(5, 9, 18)) -- navy blue flight deck
menuShade.Parent = menu

-- glowing border that slowly spins through gray / black
local menuStroke = Instance.new("UIStroke")
menuStroke.Thickness = 2
menuStroke.Color = Color3.new(1, 1, 1)
menuStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
menuStroke.Parent = menu

local menuStrokeGradient = Instance.new("UIGradient")
menuStrokeGradient.Color = accentSequence
menuStrokeGradient.Parent = menuStroke

-- title: gray gradient text + glowing underline
title.TextColor3 = Color3.new(1, 1, 1)
title.TextStrokeTransparency = 0.75
title.TextStrokeColor3 = ACCENT_A

local titleGradient = Instance.new("UIGradient")
titleGradient.Color = ColorSequence.new(Color3.fromRGB(240, 240, 245), ACCENT_A) -- light gray -> gray so it stays readable
titleGradient.Parent = title

local titleLine = Instance.new("Frame")
titleLine.Size = UDim2.new(1, -28, 0, 2)
titleLine.Position = UDim2.fromOffset(14, 37)
titleLine.BackgroundColor3 = Color3.new(1, 1, 1)
titleLine.BorderSizePixel = 0
titleLine.Parent = menu

local titleLineGradient = Instance.new("UIGradient")
titleLineGradient.Color = ColorSequence.new(ACCENT_A, ACCENT_B)
titleLineGradient.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.25, 0),
	NumberSequenceKeypoint.new(0.75, 0),
	NumberSequenceKeypoint.new(1, 1),
})
titleLineGradient.Parent = titleLine

-- title
title.Text = "TOP GUN: CLIENT"

-- gray / black hazard stripe along the bottom (like a carrier deck) + tagline
local stripeKeys = {}
local stripeCount = 9 -- 9 stripes = 18 keypoints (Roblox allows max 20)
for k = 0, stripeCount - 1 do
	local c = (k % 2 == 0) and ACCENT_A or ACCENT_B
	local t0 = (k == 0) and 0 or (k / stripeCount + 0.0005)
	local t1 = (k == stripeCount - 1) and 1 or ((k + 1) / stripeCount - 0.0005)
	table.insert(stripeKeys, ColorSequenceKeypoint.new(t0, c))
	table.insert(stripeKeys, ColorSequenceKeypoint.new(t1, c))
end

local hazardBar = Instance.new("Frame")
hazardBar.Size = UDim2.new(1, -28, 0, 5)
hazardBar.Position = UDim2.fromOffset(14, 264)
hazardBar.BackgroundColor3 = Color3.new(1, 1, 1)
hazardBar.BorderSizePixel = 0
hazardBar.Parent = menu
Instance.new("UICorner", hazardBar).CornerRadius = UDim.new(0, 2)

local hazardGradient = Instance.new("UIGradient")
hazardGradient.Color = ColorSequence.new(stripeKeys)
hazardGradient.Rotation = 35
hazardGradient.Parent = hazardBar

local tagline = Instance.new("TextLabel")
tagline.Size = UDim2.new(1, -28, 0, 14)
tagline.Position = UDim2.fromOffset(14, 272)
tagline.BackgroundTransparency = 1
tagline.Text = "DANGER ZONE"
tagline.TextColor3 = ACCENT_A
tagline.TextSize = 11
tagline.Font = Enum.Font.GothamBold
tagline.Parent = menu

-- gear button: glowing ring + soft shade
local gearShade = Instance.new("UIGradient")
gearShade.Rotation = 90
gearShade.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(110, 110, 125))
gearShade.Parent = settingsButton

local gearStroke = Instance.new("UIStroke")
gearStroke.Thickness = 2
gearStroke.Color = Color3.new(1, 1, 1)
gearStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
gearStroke.Parent = settingsButton

local gearStrokeGradient = Instance.new("UIGradient")
gearStrokeGradient.Color = accentSequence
gearStrokeGradient.Parent = gearStroke

-- pop-in when the menu opens, and the gear spins
local menuScale = Instance.new("UIScale")
menuScale.Parent = menu

local function setMenuOpen(open)
	menuOpen = open

	if open then
		menuScale.Scale = 0.8
		menu.Visible = true
		TweenService:Create(
			menuScale,
			TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = 1 }
		):Play()
	else
		menu.Visible = false
	end

	TweenService:Create(
		settingsButton,
		TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Rotation = open and 90 or 0 }
	):Play()
end

-- borders slowly spin their colours
track(RunService.RenderStepped:Connect(function()
	local spin = (os.clock() * 70) % 360
	if menu.Visible then
		menuStrokeGradient.Rotation = spin
	end
	gearStrokeGradient.Rotation = spin
end))

-- AIRCRAFT CONTROLS (drag by the title)
local panel = Instance.new("Frame")
panel.Name = "AircraftControls"
panel.Size = UDim2.fromOffset(120, 68)
panel.Position = UDim2.new(0, 18, 1, -100)
panel.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
panel.BackgroundTransparency = 0.12
panel.BorderSizePixel = 0
panel.Visible = false
panel.Active = true
panel.Parent = gui

Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 10)

local panelTitle = Instance.new("TextLabel")
panelTitle.Name = "DragTitle"
panelTitle.Size = UDim2.new(1, 0, 0, 22)
panelTitle.BackgroundColor3 = Color3.fromRGB(35, 45, 70)
panelTitle.BackgroundTransparency = 0.2
panelTitle.BorderSizePixel = 0
panelTitle.Text = "AIRCRAFT  ::"
panelTitle.TextColor3 = Color3.new(1, 1, 1)
panelTitle.TextScaled = true
panelTitle.Font = Enum.Font.GothamBold
panelTitle.Active = true
panelTitle.Parent = panel

Instance.new("UICorner", panelTitle).CornerRadius = UDim.new(0, 10)

local leftButton = button(panel, "L YAW", UDim2.fromOffset(50, 34), UDim2.fromOffset(7, 28))
local rightButton = button(panel, "R YAW", UDim2.fromOffset(50, 34), UDim2.fromOffset(63, 28))

-- SPEED READOUT (blocks per second) - small, movable, follows Lock UI
local speedLabel = Instance.new("TextLabel")
speedLabel.Name = "SpeedReadout"
speedLabel.Size = UDim2.fromOffset(86, 26)
speedLabel.Position = UDim2.new(0.5, -43, 0, 12)
speedLabel.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
speedLabel.BackgroundTransparency = 0.25
speedLabel.BorderSizePixel = 0
speedLabel.Text = "0 BPS"
speedLabel.TextColor3 = Color3.new(1, 1, 1)
speedLabel.TextScaled = true
speedLabel.Font = Enum.Font.GothamBold
speedLabel.Active = true
speedLabel.Parent = gui

Instance.new("UICorner", speedLabel).CornerRadius = UDim.new(0, 8)

local speedPadding = Instance.new("UIPadding")
speedPadding.PaddingLeft = UDim.new(0, 6)
speedPadding.PaddingRight = UDim.new(0, 6)
speedPadding.PaddingTop = UDim.new(0, 4)
speedPadding.PaddingBottom = UDim.new(0, 4)
speedPadding.Parent = speedLabel

-- GROUND TIMER READOUT - small, movable, follows Lock UI (shown while aircraft is on)
local timerLabel = Instance.new("TextLabel")
timerLabel.Name = "TimerReadout"
timerLabel.Size = UDim2.fromOffset(110, 26)
timerLabel.Position = UDim2.new(0.5, -55, 0, 44)
timerLabel.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
timerLabel.BackgroundTransparency = 0.25
timerLabel.BorderSizePixel = 0
timerLabel.Text = "AIRBORNE"
timerLabel.TextColor3 = Color3.new(1, 1, 1)
timerLabel.TextScaled = true
timerLabel.Font = Enum.Font.GothamBold
timerLabel.Active = true
timerLabel.Visible = false
timerLabel.Parent = gui

Instance.new("UICorner", timerLabel).CornerRadius = UDim.new(0, 8)

local timerPadding = Instance.new("UIPadding")
timerPadding.PaddingLeft = UDim.new(0, 6)
timerPadding.PaddingRight = UDim.new(0, 6)
timerPadding.PaddingTop = UDim.new(0, 4)
timerPadding.PaddingBottom = UDim.new(0, 4)
timerPadding.Parent = timerLabel

-- RWR (radar warning receiver) - small round radar, movable, follows Lock UI.
-- Shows enemies around you relative to the way the plane is facing (top = nose).
-- A blip turns red and flashes when that enemy is aiming at you.
-- (The small height circle under it is created right after.)
local rwr = Instance.new("Frame")
rwr.Name = "RWR"
rwr.Size = UDim2.fromOffset(RWR_SIZE, RWR_SIZE)
rwr.Position = UDim2.new(1, -(RWR_SIZE + 15), 0, 80)
rwr.BackgroundColor3 = Color3.fromRGB(8, 25, 12)
rwr.BackgroundTransparency = 0.15
rwr.BorderSizePixel = 0
rwr.Active = true
rwr.Visible = false
rwr.ClipsDescendants = true
rwr.Parent = gui

Instance.new("UICorner", rwr).CornerRadius = UDim.new(1, 0)

local rwrStroke = Instance.new("UIStroke")
rwrStroke.Color = Color3.fromRGB(60, 220, 90)
rwrStroke.Thickness = 2
rwrStroke.Parent = rwr

local function rwrLine(size, position)
	local l = Instance.new("Frame")
	l.Size = size
	l.Position = position
	l.BackgroundColor3 = Color3.fromRGB(60, 220, 90)
	l.BackgroundTransparency = 0.7
	l.BorderSizePixel = 0
	l.Parent = rwr
	return l
end

rwrLine(UDim2.new(1, 0, 0, 1), UDim2.new(0, 0, 0.5, 0)) -- horizontal cross line
rwrLine(UDim2.new(0, 1, 1, 0), UDim2.new(0.5, 0, 0, 0)) -- vertical cross line

local rwrRing = Instance.new("Frame") -- half-range ring
rwrRing.Size = UDim2.fromScale(0.5, 0.5)
rwrRing.Position = UDim2.fromScale(0.25, 0.25)
rwrRing.BackgroundTransparency = 1
rwrRing.Parent = rwr
Instance.new("UICorner", rwrRing).CornerRadius = UDim.new(1, 0)
local rwrRingStroke = Instance.new("UIStroke")
rwrRingStroke.Color = Color3.fromRGB(60, 220, 90)
rwrRingStroke.Transparency = 0.7
rwrRingStroke.Thickness = 1
rwrRingStroke.Parent = rwrRing

local rwrSelf = Instance.new("Frame") -- you, in the middle
rwrSelf.Size = UDim2.fromOffset(6, 6)
rwrSelf.AnchorPoint = Vector2.new(0.5, 0.5)
rwrSelf.Position = UDim2.fromScale(0.5, 0.5)
rwrSelf.BackgroundColor3 = Color3.new(1, 1, 1)
rwrSelf.BorderSizePixel = 0
rwrSelf.Parent = rwr
Instance.new("UICorner", rwrSelf).CornerRadius = UDim.new(1, 0)

-- COMPASS letters around the radar edge. They slide around the ring as you turn,
-- like a compass card (N = north = -Z in Roblox).
local compassLetters = {
	{ letter = "N", dir = Vector3.new(0, 0, -1), color = Color3.fromRGB(255, 90, 90) },
	{ letter = "E", dir = Vector3.new(1, 0, 0), color = Color3.fromRGB(200, 235, 200) },
	{ letter = "S", dir = Vector3.new(0, 0, 1), color = Color3.fromRGB(200, 235, 200) },
	{ letter = "W", dir = Vector3.new(-1, 0, 0), color = Color3.fromRGB(200, 235, 200) },
}

for _, c in ipairs(compassLetters) do
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromOffset(14, 14)
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.BackgroundTransparency = 1
	label.Text = c.letter
	label.TextColor3 = c.color
	label.TextSize = 12
	label.Font = Enum.Font.GothamBold
	label.Parent = rwr
	c.label = label
end

-- Small HEIGHT circle that goes with the radar (movable, follows Lock UI).
-- It points at the enemy the radar cares about most (the one aiming at you, else the
-- closest): dot at the top = he is high above you, bottom = below you, middle = same height.
local elevCircle = Instance.new("Frame")
elevCircle.Name = "RWRHeight"
elevCircle.Size = UDim2.fromOffset(ELEV_SIZE, ELEV_SIZE)
elevCircle.Position = UDim2.new(1, -(RWR_SIZE / 2 + 15 + ELEV_SIZE / 2), 0, 80 + RWR_SIZE + 8)
elevCircle.BackgroundColor3 = Color3.fromRGB(8, 25, 12)
elevCircle.BackgroundTransparency = 0.15
elevCircle.BorderSizePixel = 0
elevCircle.Active = true
elevCircle.Visible = false
elevCircle.ClipsDescendants = true
elevCircle.Parent = gui

Instance.new("UICorner", elevCircle).CornerRadius = UDim.new(1, 0)

local elevStroke = Instance.new("UIStroke")
elevStroke.Color = Color3.fromRGB(60, 220, 90)
elevStroke.Thickness = 2
elevStroke.Parent = elevCircle

local elevLine = Instance.new("Frame") -- level (same height) line
elevLine.Size = UDim2.new(1, 0, 0, 1)
elevLine.Position = UDim2.new(0, 0, 0.5, 0)
elevLine.BackgroundColor3 = Color3.fromRGB(60, 220, 90)
elevLine.BackgroundTransparency = 0.6
elevLine.BorderSizePixel = 0
elevLine.Parent = elevCircle

local elevDot = Instance.new("Frame") -- slides up / down with the enemy's height
elevDot.Size = UDim2.fromOffset(8, 8)
elevDot.AnchorPoint = Vector2.new(0.5, 0.5)
elevDot.Position = UDim2.fromScale(0.5, 0.5)
elevDot.BackgroundColor3 = Color3.fromRGB(144, 238, 144)
elevDot.BorderSizePixel = 0
elevDot.Visible = false
elevDot.Parent = elevCircle
Instance.new("UICorner", elevDot).CornerRadius = UDim.new(1, 0)

-- TUTORIAL window (opened from the menu, draggable by its title)
local tutorial = Instance.new("Frame")
tutorial.Name = "Tutorial"
tutorial.Size = UDim2.fromOffset(310, 240)
tutorial.Position = UDim2.new(0.5, -155, 0.5, -120)
tutorial.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
tutorial.BorderSizePixel = 0
tutorial.Active = true
tutorial.Visible = false
tutorial.Parent = gui

Instance.new("UICorner", tutorial).CornerRadius = UDim.new(0, 10)

local tutorialTitle = Instance.new("TextLabel")
tutorialTitle.Size = UDim2.new(1, -40, 0, 28)
tutorialTitle.BackgroundTransparency = 1
tutorialTitle.Text = "TUTORIAL  ::"
tutorialTitle.TextColor3 = Color3.new(1, 1, 1)
tutorialTitle.TextScaled = true
tutorialTitle.Font = Enum.Font.GothamBold
tutorialTitle.Active = true
tutorialTitle.Parent = tutorial

local tutorialClose = button(
	tutorial, "X",
	UDim2.fromOffset(30, 24),
	UDim2.new(1, -36, 0, 3),
	Color3.fromRGB(150, 40, 40)
)

local tutorialScroll = Instance.new("ScrollingFrame")
tutorialScroll.Position = UDim2.fromOffset(8, 34)
tutorialScroll.Size = UDim2.new(1, -16, 1, -42)
tutorialScroll.BackgroundTransparency = 1
tutorialScroll.BorderSizePixel = 0
tutorialScroll.ScrollBarThickness = 4
tutorialScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
tutorialScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
tutorialScroll.Parent = tutorial

local tutorialText = Instance.new("TextLabel")
tutorialText.Size = UDim2.new(1, -8, 0, 0)
tutorialText.AutomaticSize = Enum.AutomaticSize.Y
tutorialText.BackgroundTransparency = 1
tutorialText.TextWrapped = true
tutorialText.RichText = true
tutorialText.TextSize = 14
tutorialText.Font = Enum.Font.Gotham
tutorialText.TextColor3 = Color3.fromRGB(225, 225, 230)
tutorialText.TextXAlignment = Enum.TextXAlignment.Left
tutorialText.TextYAlignment = Enum.TextYAlignment.Top
tutorialText.Text = table.concat({
	"<b>MENU</b>",
	"Tap the gear button to open / close the menu. Drag the menu by its title and drag the gear to move it.",
	"",
	"<b>AIRCRAFT</b>",
	"Sit in a vehicle seat, then tap AIRCRAFT to turn it on (tap again to turn it off). The plane can then loop and barrel roll.",
	"Below 7 studs (on the ground) aircraft stays on for 7 seconds, then turns off. Get 7+ studs up before the timer ends to keep it on. The timer shows at the top of the screen.",
	"",
	"<b>FLYING</b>",
	"Drag the screen (touch, or hold right mouse and move): left / right steers, up / down pitches with no limit. Go up and over to loop.",
	"L YAW / R YAW buttons (or Q / E) barrel roll the plane left / right. Your plane's own keys and guns still work. The camera follows you but never rolls.",
	"All of these controls only work 7+ studs above the ground. Below 7 studs the controls hide, the normal camera comes back and nothing steers the plane.",
	"",
	"<b>SPEED (BPS)</b>",
	"The number at the top is your vehicle's speed in blocks per second.",
	"",
	"<b>RADAR (RWR)</b>",
	"Round radar, the top of the circle is where your plane is facing. A blinking light green dot is an enemy nearby. A fast blinking red dot (and a red circle edge) means that enemy is aiming at you.",
	"The letters N E S W around the radar edge slide around as you turn, like a compass.",
	"The small circle under the radar shows how high that enemy is: dot near the top = he is high above you, near the bottom = below you, middle = same height.",
	"The radar only works 7+ studs above the ground (it shows nothing below that). Use the RADAR button to turn it on / off.",
	"",
	"<b>LOCK UI</b>",
	"Locks every movable button and panel so you can't drag them by accident.",
	"",
	"<b>DELETE CLIENT</b>",
	"Removes Army Client completely. It asks you to confirm with YES / NO first.",
}, "\n")
tutorialText.Parent = tutorialScroll

-- DELETE CLIENT confirmation (Yes / No box, no screen tint)
local confirmOverlay = Instance.new("Frame") -- just the box: no dark tint over the screen
confirmOverlay.Name = "ConfirmDelete"
confirmOverlay.Size = UDim2.fromOffset(280, 160)
confirmOverlay.AnchorPoint = Vector2.new(0.5, 0.5)
confirmOverlay.Position = UDim2.fromScale(0.5, 0.5)
confirmOverlay.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
confirmOverlay.BorderSizePixel = 0
confirmOverlay.Active = true
confirmOverlay.Visible = false
confirmOverlay.ZIndex = 100
confirmOverlay.Parent = gui

local confirmBox = confirmOverlay

local confirmStroke = Instance.new("UIStroke")
confirmStroke.Color = Color3.fromRGB(255, 70, 70)
confirmStroke.Thickness = 2
confirmStroke.Parent = confirmOverlay

Instance.new("UICorner", confirmBox).CornerRadius = UDim.new(0, 10)

local confirmTitle = Instance.new("TextLabel")
confirmTitle.Size = UDim2.new(1, 0, 0, 32)
confirmTitle.Position = UDim2.fromOffset(0, 8)
confirmTitle.BackgroundTransparency = 1
confirmTitle.Text = "WARNING"
confirmTitle.TextColor3 = Color3.fromRGB(255, 70, 70)
confirmTitle.TextScaled = true
confirmTitle.Font = Enum.Font.GothamBold
confirmTitle.Parent = confirmBox

local confirmText = Instance.new("TextLabel")
confirmText.Size = UDim2.new(1, -24, 0, 50)
confirmText.Position = UDim2.fromOffset(12, 44)
confirmText.BackgroundTransparency = 1
confirmText.Text = "This will completely remove Army Client.\nAre you sure?"
confirmText.TextColor3 = Color3.new(1, 1, 1)
confirmText.TextWrapped = true
confirmText.TextSize = 16
confirmText.Font = Enum.Font.GothamBold
confirmText.Parent = confirmBox

local yesButton = button(
	confirmBox, "YES",
	UDim2.fromOffset(118, 42),
	UDim2.fromOffset(14, 104),
	Color3.fromRGB(170, 40, 40)
)

local noButton = button(
	confirmBox, "NO",
	UDim2.fromOffset(118, 42),
	UDim2.fromOffset(148, 104),
	Color3.fromRGB(70, 70, 70)
)

-- Make sure the text and the YES / NO buttons always draw ABOVE the dark box
for _, d in ipairs(confirmOverlay:GetDescendants()) do
	if d:IsA("GuiObject") then
		d.ZIndex = 101
	end
end

-- DRAGGABLE UI
local function makeDraggable(object, handle)
	local dragging = false
	local dragStart
	local originalPosition
	local activeInput
	local moved = false

	handle.InputBegan:Connect(function(input)
		if uiLocked then return end

		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		dragging = true
		dragStart = input.Position
		originalPosition = object.Position
		activeInput = input
		moved = false

		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				dragging = false
			end
		end)
	end)

	track(UIS.InputChanged:Connect(function(input)
		if not dragging or uiLocked then return end

		if input == activeInput
			or input.UserInputType == Enum.UserInputType.MouseMovement then

			local delta = input.Position - dragStart

			if not moved and delta.Magnitude < DRAG_THRESHOLD then
				return
			end
			moved = true

			object.Position = UDim2.new(
				originalPosition.X.Scale,
				originalPosition.X.Offset + delta.X,
				originalPosition.Y.Scale,
				originalPosition.Y.Offset + delta.Y
			)
		end
	end))
end

makeDraggable(panel, panelTitle)
makeDraggable(timerLabel, timerLabel) -- drag the timer around (blocked while LOCK UI is on)
makeDraggable(speedLabel, speedLabel) -- drag the BPS number around (blocked while LOCK UI is on)
makeDraggable(rwr, rwr) -- drag the radar around (blocked while LOCK UI is on)
makeDraggable(elevCircle, elevCircle) -- drag the height circle around (blocked while LOCK UI is on)
makeDraggable(tutorial, tutorialTitle) -- drag the tutorial by its title (blocked while LOCK UI is on)
makeDraggable(settingsButton, settingsButton)
makeDraggable(menu, title) -- drag the menu by its ARMY CLIENT title (blocked while LOCK UI is on)

-- AIRCRAFT
-- Height above the ground. Bullets, muzzle flashes, shells and other small or
-- non-solid parts (including things welded to the plane while shooting) are
-- skipped so firing never makes the plane look "too low".
local function getHeight(rootPart, ignore)
	local filter = table.clone(ignore)

	for _ = 1, 8 do
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = filter
		params.RespectCanCollide = true

		local hit = workspace:Raycast(rootPart.Position, Vector3.new(0, -1000, 0), params)

		if not hit then
			return math.huge -- nothing below: treat as high up
		end

		local part = hit.Instance
		if part:IsA("Terrain") or part.Size.Magnitude >= 6 then
			return hit.Distance
		end

		table.insert(filter, part) -- small stuff: ignore it and look further down
	end

	return math.huge
end

local function flashAircraftText(text)
	aircraftButton.Text = text
	task.delay(1.5, function()
		if not aircraftOn then
			aircraftButton.Text = "AIRCRAFT: OFF"
		end
	end)
end

local function stopAircraft()
	local wasOn = aircraftOn

	aircraftOn = false
	btnYaw = 0
	keyRoll = 0
	yawRate = 0
	dragYaw, dragPitch = 0, 0
	airborne = false

	-- Aircraft is OFF: stop pushing the plane completely. Our forced velocity is
	-- removed (the plane does not keep flying), and gravity / the plane's own
	-- scripts take over again from a standstill.
	local rootPart = aircraftRoot
	if rootPart and rootPart.Parent then
		rootPart.AssemblyLinearVelocity = Vector3.zero
		rootPart.AssemblyAngularVelocity = Vector3.zero
	end

	if aircraftConnection then
		aircraftConnection:Disconnect()
		aircraftConnection = nil
	end

	if cameraConnection then
		cameraConnection:Disconnect()
		cameraConnection = nil
	end

	aircraftRoot = nil
	aircraftSeat = nil

	panel.Visible = false
	timerLabel.Visible = false
	aircraftButton.Text = "AIRCRAFT: OFF"
	UIS.MouseBehavior = Enum.MouseBehavior.Default

	-- Give the normal camera back
	if wasOn then
		camera.CameraType = Enum.CameraType.Custom
		if humanoid then
			camera.CameraSubject = humanoid
		end
	end
end

local function startAircraft(seat)
	if aircraftOn or not humanoid or humanoid.Health <= 0 then
		return
	end

	local vehicleRoot = seat.AssemblyRootPart
	if not vehicleRoot then
		flashAircraftText("NO VEHICLE ROOT")
		return
	end

	-- Vehicle parts + character are ignored when measuring height
	aircraftIgnore = seat:GetConnectedParts(true)
	local vehicleModel = seat:FindFirstAncestorOfClass("Model")
	if vehicleModel and vehicleModel ~= character
		and vehicleModel:GetExtentsSize().Magnitude < 400 then
		table.insert(aircraftIgnore, vehicleModel)
	end
	if character then
		table.insert(aircraftIgnore, character)
	end

	camera = workspace.CurrentCamera

	aircraftOn = true
	aircraftSeat = seat
	aircraftRoot = vehicleRoot
	yawRate = 0
	dragYaw, dragPitch = 0, 0

	-- Start looking the way the plane faces
	-- Remember how the plane's parts sit relative to the seat
	local seatRot = seat.CFrame.Rotation
	seatToRoot = seatRot:Inverse() * vehicleRoot.CFrame.Rotation

	-- Start from a level, roll-free orientation facing the way the plane faces
	local forward = seatRot.LookVector
	if math.abs(forward.Y) > 0.99 then
		camRot = seatRot
	else
		camRot = CFrame.lookAt(Vector3.zero, forward, Vector3.yAxis)
	end
	camRotSmooth = camRot
	rollAngle = 0
	lowTime = 0
	lastShown = -1

	-- Clicking AIRCRAFT on the ground starts the ground timer RIGHT AWAY. The controls
	-- stay off until the plane is 7+ studs up; the moment it is, they switch on.
	local startLow = getHeight(vehicleRoot, aircraftIgnore) < MIN_AIRCRAFT_HEIGHT
	airborne = not startLow

	timerLabel.Visible = true
	if startLow then
		lastShown = GROUND_TIMEOUT
		panel.Visible = false
		timerLabel.Text = "GROUND " .. GROUND_TIMEOUT .. "s"
		timerLabel.TextColor3 = Color3.fromRGB(255, 120, 100)
		aircraftButton.Text = "AIRCRAFT: ON (" .. GROUND_TIMEOUT .. "s)"
	else
		panel.Visible = true
		timerLabel.Text = "ACTIVE"
		timerLabel.TextColor3 = Color3.new(1, 1, 1)
		aircraftButton.Text = "AIRCRAFT: ON"
		camera.CameraType = Enum.CameraType.Scriptable
	end

	-- Camera: follows the plane, never rolls
	cameraConnection = RunService.RenderStepped:Connect(function(dt)
		if not aircraftOn or not aircraftRoot or not aircraftRoot.Parent then return end

		-- Below 7 studs there is NO aircraft control at all: the aircraft camera is
		-- released (normal camera back) and drag steering is thrown away.
		if not airborne then
			dragYaw, dragPitch = 0, 0
			camRotSmooth = camRot -- no swing when you climb past 7 studs

			if camera.CameraType ~= Enum.CameraType.Custom then
				camera.CameraType = Enum.CameraType.Custom
				if humanoid then
					camera.CameraSubject = humanoid
				end
			end
			return
		end

		local pitchStep = dragPitch
		local steerStep = dragYaw
		dragYaw, dragPitch = 0, 0

		-- Steer in world space (normal left/right), pitch with no limit
		camRot = CFrame.Angles(0, steerStep, 0) * camRot * CFrame.Angles(pitchStep, 0, 0)

		-- Keep the rotation clean over many loops
		camRot = CFrame.fromMatrix(Vector3.zero, camRot.RightVector, camRot.UpVector)

		-- Smooth trailing swing
		local swing = 1 - math.exp(-CAMERA_SMOOTHING * dt)
		camRotSmooth = camRotSmooth:Lerp(camRot, swing)

		local pos = aircraftRoot.Position
		local camPos = pos - camRotSmooth.LookVector * CAMERA_DISTANCE + camRotSmooth.UpVector * CAMERA_HEIGHT

		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = CFrame.new(camPos) * camRotSmooth
	end)

	-- Safety checks, ground timer, plane rotation (loops + barrel roll) and speed
	aircraftConnection = RunService.Heartbeat:Connect(function(dt)
		if not aircraftOn then return end

		if not humanoid or humanoid.Health <= 0
			or not aircraftSeat or not aircraftSeat.Parent
			or humanoid.SeatPart ~= aircraftSeat
			or not aircraftRoot or not aircraftRoot.Parent then
			stopAircraft()
			flashAircraftText("LEFT SEAT")
			return
		end

		-- On the ground (below 7 studs) aircraft stays on for GROUND_TIMEOUT seconds,
		-- then turns off. Getting 7+ studs up before that resets the timer.
		local isLow = getHeight(aircraftRoot, aircraftIgnore) < MIN_AIRCRAFT_HEIGHT
		airborne = not isLow

		if isLow then
			lowTime += dt

			if lowTime >= GROUND_TIMEOUT then
				stopAircraft()
				flashAircraftText("GROUND TIMEOUT")
				return
			end

			local shown = math.ceil(GROUND_TIMEOUT - lowTime)
			timerLabel.Text = "GROUND " .. shown .. "s"
			timerLabel.TextColor3 = Color3.fromRGB(255, 120, 100)
			if shown ~= lastShown then
				lastShown = shown
				aircraftButton.Text = "AIRCRAFT: ON (" .. shown .. "s)"
			end
		elseif lowTime > 0 then
			lowTime = 0
			lastShown = -1
			aircraftButton.Text = "AIRCRAFT: ON"
			timerLabel.Text = "ACTIVE" -- got 7+ studs up in time: controls switch on now
			timerLabel.TextColor3 = Color3.new(1, 1, 1)
		end

		-- Below 7 studs ALL controls fail (steering, pitch, L YAW / R YAW, Q / E).
		-- The plane is left alone and just flies on its own; the camera keeps
		-- following the way it faces so there is no jump when you climb past 7 studs.
		panel.Visible = not isLow -- the aircraft controls only exist 7+ studs up

		if isLow then
			yawRate = 0
			rollAngle = 0
			btnYaw = 0
			keyRoll = 0
			dragYaw, dragPitch = 0, 0

			local seatRot = aircraftSeat.CFrame.Rotation
			local forward = seatRot.LookVector
			if math.abs(forward.Y) > 0.99 then
				camRot = seatRot
			else
				camRot = CFrame.lookAt(Vector3.zero, forward, Vector3.yAxis)
			end
			return
		end

		-- R YAW / E = roll right, L YAW / Q = roll left
		local rollInput = math.clamp(btnYaw - keyRoll, -1, 1)
		local alpha = 1 - math.exp(-INPUT_SMOOTHING * dt)
		yawRate += (rollInput - yawRate) * alpha

		-- The plane's orientation = the camera's roll-free orientation (so it loops
		-- over the top and flips upside down) plus the barrel roll on top.
		rollAngle = (rollAngle + yawRate * BUTTON_ROLL_SPEED * dt) % (math.pi * 2)

		local planeRot = camRot * CFrame.Angles(0, 0, -rollAngle)

		aircraftRoot.AssemblyAngularVelocity = Vector3.zero
		aircraftRoot.CFrame = CFrame.new(aircraftRoot.Position) * (planeRot * seatToRoot)
	end)
end

-- Leaving the seat turns aircraft mode off
onSeatChanged = function()
	if not humanoid then return end

	local seat = humanoid.SeatPart

	if aircraftOn and (not seat or not (seat:IsA("VehicleSeat") or seat:IsA("Seat"))) then
		stopAircraft()
	end
end

local function toggleAircraft()
	if aircraftOn then
		stopAircraft()
		return
	end

	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local seat = humanoid.SeatPart

	if not seat or not (seat:IsA("VehicleSeat") or seat:IsA("Seat")) then
		flashAircraftText("SIT IN VEHICLE")
		return
	end

	local ok, err = pcall(startAircraft, seat)
	if not ok then
		warn("[ARMY CLIENT] aircraft error: " .. tostring(err))
		stopAircraft()
		flashAircraftText("ERROR - SEE OUTPUT")
	end
end

aircraftButton.Activated:Connect(toggleAircraft)

track(player.CharacterAdded:Connect(function(char)
	stopAircraft()
	setupCharacter(char)
	onSeatChanged()
end))

-- HOLD L YAW / R YAW
local function bindHold(b, callback)
	local heldInput

	b.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			heldInput = input
			callback(true)
		end
	end)

	local function release(input)
		if heldInput and (input == heldInput
			or (input.UserInputType == Enum.UserInputType.MouseButton1
				and heldInput.UserInputType == Enum.UserInputType.MouseButton1)) then
			heldInput = nil
			callback(false)
		end
	end

	b.InputEnded:Connect(release)
	track(UIS.InputEnded:Connect(release))
end

bindHold(leftButton, function(held) btnYaw = (held and airborne) and -1 or 0 end)
bindHold(rightButton, function(held) btnYaw = (held and airborne) and 1 or 0 end)

-- SCREEN DRAG = steer camera left/right + pitch up/down, unlimited
local lookTouch
local mouseLook = false

track(UIS.InputBegan:Connect(function(input, processed)
	if not aircraftOn or not airborne then return end -- no aircraft input below 7 studs

	if input.UserInputType == Enum.UserInputType.Touch and not processed then
		lookTouch = input
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		mouseLook = true
		UIS.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
	end

	if processed then return end

	-- Only Q/E are used so the plane's own keys (W/A/S/D) stay untouched
	if input.KeyCode == Enum.KeyCode.Q then keyRoll = 1
	elseif input.KeyCode == Enum.KeyCode.E then keyRoll = -1
	end
end))

track(UIS.InputChanged:Connect(function(input)
	if not aircraftOn or not airborne then return end

	local delta
	if input == lookTouch then
		delta = input.Delta
	elseif mouseLook and input.UserInputType == Enum.UserInputType.MouseMovement then
		delta = input.Delta
	end

	if delta then
		dragYaw += -delta.X * DRAG_SENSITIVITY     -- drag right = steer right
		dragPitch += -delta.Y * DRAG_SENSITIVITY   -- drag up = look up
	end
end))

track(UIS.InputEnded:Connect(function(input)
	if input == lookTouch then
		lookTouch = nil
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		mouseLook = false
		UIS.MouseBehavior = Enum.MouseBehavior.Default
	end

	if input.KeyCode == Enum.KeyCode.Q and keyRoll == 1 then keyRoll = 0
	elseif input.KeyCode == Enum.KeyCode.E and keyRoll == -1 then keyRoll = 0
	end
end))

-- MENU
lockButton.Activated:Connect(function()
	uiLocked = not uiLocked
	lockButton.Text = uiLocked and "LOCK UI: ON" or "LOCK UI: OFF"
end)

-- Tap the gear to show / hide the menu (dragging it around does not toggle it)
local pressPosition
local pressInput
local pressMoved = false

settingsButton.InputBegan:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1
		and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end

	pressPosition = input.Position
	pressInput = input
	pressMoved = false
end)

track(UIS.InputChanged:Connect(function(input)
	if not pressInput or not pressPosition then return end

	if input == pressInput
		or input.UserInputType == Enum.UserInputType.MouseMovement then

		if (input.Position - pressPosition).Magnitude > DRAG_THRESHOLD then
			pressMoved = true
		end
	end
end))

track(UIS.InputEnded:Connect(function(input)
	if not pressInput then return end

	if input == pressInput
		or (input.UserInputType == Enum.UserInputType.MouseButton1
			and pressInput.UserInputType == Enum.UserInputType.MouseButton1) then

		if not pressMoved then
			setMenuOpen(not menuOpen)
		end

		pressInput = nil
		pressPosition = nil
	end
end))

menu.Visible = false
panel.Visible = false

-- Update the BPS readout: the vehicle's speed while seated, otherwise your character's
track(RunService.Heartbeat:Connect(function()
	local part

	if humanoid and humanoid.SeatPart then
		part = humanoid.SeatPart.AssemblyRootPart or humanoid.SeatPart
	elseif character then
		part = character:FindFirstChild("HumanoidRootPart")
	end

	local bps = part and part.AssemblyLinearVelocity.Magnitude or 0
	speedLabel.Text = math.floor(bps + 0.5) .. " BPS"
end))

-- Enemies = players on a different team. If teams are not used, everyone else counts.
local function canDamage(other)
	if other == player then return false end
	if not player.Team or not other.Team then return true end
	return other.Team ~= player.Team
end

local function removeBlip(other)
	local blip = rwrBlips[other]
	if blip then
		blip:Destroy()
		rwrBlips[other] = nil
	end
end

-- Which way is this enemy pointing? Their plane's nose if seated, else their body.
local function aimDirection(char)
	local hum = char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	if seat then
		return seat.CFrame.LookVector
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	return hrp and hrp.CFrame.LookVector
end

local function updateRWR()
	rwr.Visible = aircraftOn and radarEnabled
	elevCircle.Visible = rwr.Visible

	local function clearBlips()
		for other in pairs(rwrBlips) do removeBlip(other) end
	end

	if not aircraftOn or not radarEnabled or not aircraftRoot or not aircraftRoot.Parent then
		elevDot.Visible = false
		clearBlips()
		return
	end

	local myPos = aircraftRoot.Position
	local heading = Vector3.new(camRot.LookVector.X, 0, camRot.LookVector.Z)
	if heading.Magnitude < 0.01 then
		heading = Vector3.new(0, 0, -1)
	end
	heading = heading.Unit
	local right = heading:Cross(Vector3.yAxis)

	-- compass letters slide around the ring as the plane turns
	local labelRadius = RWR_SIZE / 2 - 9
	for _, c in ipairs(compassLetters) do
		local cx = c.dir:Dot(right) * labelRadius
		local cy = c.dir:Dot(heading) * labelRadius
		c.label.Position = UDim2.new(0.5, cx, 0.5, -cy)
	end

	-- Radar only works while the plane is 7+ studs above the ground
	if not airborne then
		rwrStroke.Color = Color3.fromRGB(100, 100, 100)
		elevStroke.Color = Color3.fromRGB(100, 100, 100)
		elevDot.Visible = false
		clearBlips()
		return
	end


	local radius = RWR_SIZE / 2 - 18 -- keeps the dots inside the compass letters
	local slowFlash = (os.clock() % 1.0) < 0.6   -- normal contacts: steady blink
	local fastFlash = (os.clock() % 0.2) < 0.1   -- aimed at you: rapid blink
	local lockCos = math.cos(math.rad(RWR_LOCK_ANGLE))
	local anyLock = false
	local targetRel, targetPriority, targetDist, targetLocked -- enemy the height circle points at

	for _, other in ipairs(Players:GetPlayers()) do
		local char = other.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local rel = hrp and (hrp.Position - myPos)

		if canDamage(other) and hum and hum.Health > 0 and rel and rel.Magnitude <= RWR_RANGE then
			local blip = rwrBlips[other]
			if not blip then
				blip = Instance.new("Frame")
				blip.Name = other.Name
				blip.Size = UDim2.fromOffset(8, 8)
				blip.AnchorPoint = Vector2.new(0.5, 0.5)
				blip.BorderSizePixel = 0
				blip.Parent = rwr
				Instance.new("UICorner", blip).CornerRadius = UDim.new(1, 0)
				rwrBlips[other] = blip
			end

			local x = rel:Dot(right) / RWR_RANGE * radius
			local y = rel:Dot(heading) / RWR_RANGE * radius
			blip.Position = UDim2.new(0.5, x, 0.5, -y)

			-- red + flashing = this enemy is aiming at you
			local aim = aimDirection(char)
			local locked = aim and (aim:Dot(-rel.Unit) > lockCos)

			-- pick the height-circle target: aiming at you first, then closest
			local dist = rel.Magnitude
			local priority = locked and 1 or 0
			if not targetRel or priority > targetPriority
				or (priority == targetPriority and dist < targetDist) then
				targetRel, targetPriority, targetDist, targetLocked = rel, priority, dist, locked
			end

			if locked then
				anyLock = true
				blip.BackgroundColor3 = Color3.fromRGB(255, 40, 40)
				blip.Size = UDim2.fromOffset(10, 10)
				blip.Visible = fastFlash
			else
				blip.BackgroundColor3 = Color3.fromRGB(144, 238, 144)
				blip.Size = UDim2.fromOffset(8, 8)
				blip.Visible = slowFlash
			end
		else
			removeBlip(other)
		end
	end

	local ringColor = anyLock and Color3.fromRGB(255, 60, 60) or Color3.fromRGB(60, 220, 90)
	rwrStroke.Color = ringColor
	elevStroke.Color = ringColor

	-- height circle: dot up = enemy high above you, down = below you, middle = level
	if targetRel and targetDist > 0.01 then
		local elevation = math.asin(math.clamp(targetRel.Y / targetDist, -1, 1)) -- -90..+90 deg
		local travel = ELEV_SIZE / 2 - 6
		elevDot.Position = UDim2.new(0.5, 0, 0.5, -(elevation / (math.pi / 2)) * travel)
		elevDot.BackgroundColor3 = targetLocked and Color3.fromRGB(255, 40, 40) or Color3.fromRGB(144, 238, 144)
		if targetLocked then
			elevDot.Visible = fastFlash
		else
			elevDot.Visible = slowFlash
		end
	else
		elevDot.Visible = false
	end
end

radarButton.Activated:Connect(function()
	radarEnabled = not radarEnabled
	radarButton.Text = radarEnabled and "RADAR: ON" or "RADAR: OFF"
	radarButton.BackgroundColor3 = radarEnabled and Color3.fromRGB(40, 120, 60) or Color3.fromRGB(70, 70, 70)
	pcall(updateRWR)
end)

track(Players.PlayerRemoving:Connect(removeBlip))

task.spawn(function()
	while gui.Parent do
		pcall(updateRWR)
		task.wait(0.05)
	end
end)

-- TUTORIAL button
tutorialButton.Activated:Connect(function()
	tutorial.Visible = not tutorial.Visible
end)

tutorialClose.Activated:Connect(function()
	tutorial.Visible = false
end)

-- DELETE CLIENT: asks first, YES removes everything
local function deleteClient()
	-- 1) hide every part of the client first, so nothing can block the screen
	--    even if a later step fails
	gui.Enabled = false
	confirmOverlay.Visible = false

	-- 2) aircraft off + give the game back its normal camera and mouse
	pcall(stopAircraft)
	pcall(function()
		UIS.MouseBehavior = Enum.MouseBehavior.Default
		local cam = workspace.CurrentCamera
		cam.CameraType = Enum.CameraType.Custom
		if humanoid then
			cam.CameraSubject = humanoid
		end
	end)

	-- 3) remove every listener this client made
	for _, conn in ipairs(clientConnections) do
		pcall(function() conn:Disconnect() end)
	end
	table.clear(clientConnections)

	if seatConnection then
		pcall(function() seatConnection:Disconnect() end)
		seatConnection = nil
	end

	-- 4) delete all the UI (radar, dots, buttons, panels)
	pcall(function() gui:Destroy() end)
end

deleteButton.Activated:Connect(function()
	confirmOverlay.Visible = true
end)

noButton.Activated:Connect(function()
	confirmOverlay.Visible = false
end)

yesButton.Activated:Connect(deleteClient)

-- START
if player.Character then
	setupCharacter(player.Character)
	onSeatChanged()
end
