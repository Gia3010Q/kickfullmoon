-- Blox Fruits - Auto Kick Full Moon
-- Hiển thị trực tiếp Time + MoonPhase từ server
-- Kick khi qua mốc giờ cấu hình theo logic full moon

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

-- CONFIG
local KICK_AFTER_HOUR = 6
local KICK_AFTER_MINUTE = 0
local CHECK_INTERVAL = 1

local STABLE_TICKS_FOR_FULL = 2
local STABLE_TICKS_FOR_END = 2

local FULL_MOON_WINDOW_START_HOUR = 17
local FULL_MOON_WINDOW_START_MINUTE = 48
local FULL_MOON_WINDOW_END_HOUR = 5
local FULL_MOON_WINDOW_END_MINUTE = 0

-- false: chỉ kick khi full đã kết thúc và qua mốc giờ
-- true: qua mốc giờ là kick ngay
local FORCE_KICK_AT_THRESHOLD = false

local UI_TITLE = "Blox Fruits - Auto Kick Full Moon"
local KICK_MESSAGE = "Gia On Top dăm ba cái script"

-- ID full moon bạn đã probe
local FULL_MOON_TEXTURES = {
    ["9709149431"] = true,
}

local STATE = {
    SEARCHING_FULL = "SEARCHING_FULL",
    FULL_ACTIVE = "FULL_ACTIVE",
    WAITING_END = "WAITING_END",
    KICKED = "KICKED",
}

local currentState = STATE.SEARCHING_FULL
local seenFullStableTicks = 0
local seenEndStableTicks = 0

local function getServerTimeParts()
    local clock = Lighting.ClockTime
    local h = math.floor(clock)
    local m = math.floor((clock - h) * 60)
    return h, m
end

local function formatTime(h, m)
    return string.format("%02d:%02d", h, m)
end

local function isAfterOrEqual(h, m, th, tm)
    return (h > th) or (h == th and m >= tm)
end

local function isBeforeOrEqual(h, m, th, tm)
    return (h < th) or (h == th and m <= tm)
end

local function isInFullMoonWindow(h, m)
    return isAfterOrEqual(h, m, FULL_MOON_WINDOW_START_HOUR, FULL_MOON_WINDOW_START_MINUTE)
        or isBeforeOrEqual(h, m, FULL_MOON_WINDOW_END_HOUR, FULL_MOON_WINDOW_END_MINUTE)
end

local function isAfterKickThreshold(h, m)
    return isAfterOrEqual(h, m, KICK_AFTER_HOUR, KICK_AFTER_MINUTE)
end

local function isFullByTexture()
    local sky = Lighting:FindFirstChildOfClass("Sky")
    local textureId = (sky and sky.MoonTextureId) or ""

    for id in pairs(FULL_MOON_TEXTURES) do
        if string.find(textureId, id, 1, true) then
            return true
        end
    end

    return false
end

local function nativePhaseToDisplay(nativePhase)
    if type(nativePhase) ~= "number" then
        return "?/5"
    end

    local phase = math.floor(nativePhase)
    if phase < 0 then phase = 0 end
    if phase > 5 then phase = 5 end

    return string.format("%d/5", phase)
end

local function getMoonInfo()
    local nativePhase = Lighting:GetAttribute("MoonPhase")
    return {
        display = nativePhaseToDisplay(nativePhase),
        isFull = isFullByTexture(),
    }
end

local function createStatusUI()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "BF_AutoKickMoon_UI"
    screenGui.ResetOnSpawn = false

    pcall(function()
        if gethui then
            screenGui.Parent = gethui()
        else
            screenGui.Parent = game:GetService("CoreGui")
        end
    end)

    if not screenGui.Parent then
        screenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
    end

    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(0, 350, 0, 170)
    frame.Position = UDim2.new(0.5, -175, 0, 60)
    frame.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
    frame.BackgroundTransparency = 0.15
    frame.BorderSizePixel = 0
    frame.Parent = screenGui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = frame

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -12, 0, 26)
    title.Position = UDim2.new(0, 6, 0, 4)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 16
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = UI_TITLE
    title.Parent = frame

    local info = Instance.new("TextLabel")
    info.Size = UDim2.new(1, -12, 1, -38)
    info.Position = UDim2.new(0, 6, 0, 34)
    info.BackgroundTransparency = 1
    info.Font = Enum.Font.Code
    info.TextSize = 18
    info.TextColor3 = Color3.fromRGB(170, 255, 170)
    info.TextXAlignment = Enum.TextXAlignment.Left
    info.TextYAlignment = Enum.TextYAlignment.Top
    info.Text = "Time: --:--\nMoon: ?/5"
    info.Parent = frame

    local dragging = false
    local dragStart = nil
    local startPos = nil

    frame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = frame.Position
        end
    end)

    frame.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end

        local delta = input.Position - dragStart
        frame.Position = UDim2.new(
            startPos.X.Scale,
            startPos.X.Offset + delta.X,
            startPos.Y.Scale,
            startPos.Y.Offset + delta.Y
        )
    end)

    return info
end

local statusLabel = createStatusUI()

while task.wait(CHECK_INTERVAL) do
    local h, m = getServerTimeParts()
    local timeText = formatTime(h, m)
    local inWindow = isInFullMoonWindow(h, m)
    local canKick = isAfterKickThreshold(h, m)

    local moon = getMoonInfo()

    if currentState == STATE.SEARCHING_FULL then
        if inWindow and moon.isFull then
            seenFullStableTicks = seenFullStableTicks + 1
            if seenFullStableTicks >= STABLE_TICKS_FOR_FULL then
                currentState = STATE.FULL_ACTIVE
                seenEndStableTicks = 0
            end
        else
            seenFullStableTicks = 0
        end

    elseif currentState == STATE.FULL_ACTIVE then
        if moon.isFull then
            seenEndStableTicks = 0
        else
            seenEndStableTicks = seenEndStableTicks + 1
            if seenEndStableTicks >= STABLE_TICKS_FOR_END then
                currentState = STATE.WAITING_END
            end
        end

    elseif currentState == STATE.WAITING_END then
        if canKick then
            currentState = STATE.KICKED
            LocalPlayer:Kick(KICK_MESSAGE)
            break
        end
    end

    if FORCE_KICK_AT_THRESHOLD and canKick and currentState ~= STATE.KICKED then
        currentState = STATE.KICKED
        LocalPlayer:Kick(KICK_MESSAGE)
        break
    end

    statusLabel.Text = string.format("Time: %s\nMoon: %s", timeText, moon.display)
end
