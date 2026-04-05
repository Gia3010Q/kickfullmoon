-- Blox Fruits - Auto Kick Full Moon V2
-- Upgraded: fix bugs, UI đẹp hơn, countdown kick, debug log, robust state machine
-- By: Gia On Top

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer

-- ═══════════════════════════════════════════════
-- CONFIG (chỉnh tại đây)
-- ═══════════════════════════════════════════════
local CONFIG = {
    -- Mốc giờ kick (server time)
    KICK_AFTER_HOUR = 6,
    KICK_AFTER_MINUTE = 0,

    -- Bao nhiêu tick liên tục xác nhận full moon / kết thúc full moon
    STABLE_TICKS_FOR_FULL = 2,
    STABLE_TICKS_FOR_END = 2,

    -- Cửa sổ thời gian full moon xuất hiện (wrap qua nửa đêm OK)
    FULL_MOON_WINDOW_START_HOUR = 17,
    FULL_MOON_WINDOW_START_MINUTE = 48,
    FULL_MOON_WINDOW_END_HOUR = 5,
    FULL_MOON_WINDOW_END_MINUTE = 0,

    -- false = chỉ kick khi full moon đã kết thúc VÀ qua mốc giờ
    -- true  = qua mốc giờ là kick ngay bất kể full moon còn hay không
    FORCE_KICK_AT_THRESHOLD = false,

    -- Interval check (giây)
    CHECK_INTERVAL = 1,

    -- Kick message
    KICK_MESSAGE = "Gia On Top dăm ba cái script",

    -- Hiển thị debug log trong UI (số dòng log tối đa)
    MAX_LOG_LINES = 6,

    -- Texture IDs full moon đã xác nhận
    FULL_MOON_TEXTURES = {
        ["9709149431"] = true,
    },
}

-- ═══════════════════════════════════════════════
-- STATE MACHINE
-- ═══════════════════════════════════════════════
local STATE = {
    SEARCHING_FULL = "🔍 Đang tìm Full Moon",
    FULL_ACTIVE    = "🌕 Full Moon đang diễn ra",
    WAITING_END    = "⏳ Chờ mốc giờ để kick",
    KICKED         = "✅ Đã kick",
}

local currentState = STATE.SEARCHING_FULL
local seenFullStableTicks = 0
local seenEndStableTicks = 0
local seenWindowEndTicks = 0
local fullMoonDetectedAt = nil  -- lưu thời điểm phát hiện full moon
local lastClockTime = nil        -- detect time jump

-- Debug log buffer
local logLines = {}

local function addLog(msg)
    local h, m = math.floor(Lighting.ClockTime), math.floor((Lighting.ClockTime - math.floor(Lighting.ClockTime)) * 60)
    local timestamp = string.format("[%02d:%02d]", h, m)
    table.insert(logLines, timestamp .. " " .. msg)
    if #logLines > CONFIG.MAX_LOG_LINES then
        table.remove(logLines, 1)
    end
end

-- ═══════════════════════════════════════════════
-- TIME HELPERS
-- ═══════════════════════════════════════════════
local function getServerTimeParts()
    local clock = Lighting.ClockTime
    local h = math.floor(clock)
    local m = math.floor((clock - h) * 60)
    return h, m
end

local function formatTime(h, m)
    return string.format("%02d:%02d", h, m)
end

local function timeToMinutes(h, m)
    return h * 60 + m
end

local function isAfterOrEqual(h, m, th, tm)
    return timeToMinutes(h, m) >= timeToMinutes(th, tm)
end

local function isBeforeOrEqual(h, m, th, tm)
    return timeToMinutes(h, m) <= timeToMinutes(th, tm)
end

local function isInFullMoonWindow(h, m)
    local startH = CONFIG.FULL_MOON_WINDOW_START_HOUR
    local startM = CONFIG.FULL_MOON_WINDOW_START_MINUTE
    local endH = CONFIG.FULL_MOON_WINDOW_END_HOUR
    local endM = CONFIG.FULL_MOON_WINDOW_END_MINUTE

    -- Window wraps qua nửa đêm (start > end)
    if timeToMinutes(startH, startM) > timeToMinutes(endH, endM) then
        return isAfterOrEqual(h, m, startH, startM) or isBeforeOrEqual(h, m, endH, endM)
    else
        return isAfterOrEqual(h, m, startH, startM) and isBeforeOrEqual(h, m, endH, endM)
    end
end

local function isAfterKickThreshold(h, m)
    return isAfterOrEqual(h, m, CONFIG.KICK_AFTER_HOUR, CONFIG.KICK_AFTER_MINUTE)
end

local function getMinutesUntilKick(h, m)
    local now = timeToMinutes(h, m)
    local kick = timeToMinutes(CONFIG.KICK_AFTER_HOUR, CONFIG.KICK_AFTER_MINUTE)
    if kick > now then
        return kick - now
    elseif kick < now then
        return (24 * 60 - now) + kick
    end
    return 0
end

-- ═══════════════════════════════════════════════
-- MOON DETECTION
-- ═══════════════════════════════════════════════
local function isFullByTexture()
    local sky = Lighting:FindFirstChildOfClass("Sky")
    if not sky then return false, "no_sky" end

    local textureId = sky.MoonTextureId or ""
    if textureId == "" then return false, "no_texture" end

    for id in pairs(CONFIG.FULL_MOON_TEXTURES) do
        if string.find(textureId, id, 1, true) then
            return true, id
        end
    end

    return false, textureId
end

local function getMoonPhaseDisplay()
    local nativePhase = Lighting:GetAttribute("MoonPhase")
    if type(nativePhase) ~= "number" then
        return "N/A"
    end
    local phase = math.clamp(math.floor(nativePhase), 0, 5)
    return string.format("%d/5", phase)
end

-- ═══════════════════════════════════════════════
-- UI
-- ═══════════════════════════════════════════════
local function makeDraggable(guiObject)
    local dragging = false
    local dragStart = nil
    local startPos = nil

    guiObject.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = guiObject.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
            and input.UserInputType ~= Enum.UserInputType.Touch then
            return
        end
        local delta = input.Position - dragStart
        guiObject.Position = UDim2.new(
            startPos.X.Scale,
            startPos.X.Offset + delta.X,
            startPos.Y.Scale,
            startPos.Y.Offset + delta.Y
        )
    end)
end

local function createUI()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "BF_AutoKickMoon_V2"
    screenGui.ResetOnSpawn = false
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    -- Parent với fallback
    local parentSuccess = pcall(function()
        if gethui then
            local hui = gethui()
            if hui then
                screenGui.Parent = hui
                return
            end
        end
        screenGui.Parent = game:GetService("CoreGui")
    end)
    if not parentSuccess or not screenGui.Parent then
        screenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
    end

    -- ═══ Toggle Button ═══
    local toggleBtn = Instance.new("TextButton")
    toggleBtn.Name = "ToggleBtn"
    toggleBtn.Size = UDim2.new(0, 44, 0, 44)
    toggleBtn.Position = UDim2.new(1, -55, 0, 10)
    toggleBtn.BackgroundColor3 = Color3.fromRGB(25, 25, 35)
    toggleBtn.BackgroundTransparency = 0.1
    toggleBtn.BorderSizePixel = 0
    toggleBtn.Font = Enum.Font.GothamBold
    toggleBtn.TextSize = 22
    toggleBtn.TextColor3 = Color3.fromRGB(255, 220, 80)
    toggleBtn.Text = "🌙"
    toggleBtn.ZIndex = 100
    toggleBtn.Parent = screenGui

    local toggleStroke = Instance.new("UIStroke")
    toggleStroke.Color = Color3.fromRGB(255, 220, 80)
    toggleStroke.Thickness = 1.5
    toggleStroke.Transparency = 0.5
    toggleStroke.Parent = toggleBtn

    Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0, 10)
    makeDraggable(toggleBtn)

    -- ═══ Main Frame ═══
    local frame = Instance.new("Frame")
    frame.Name = "MainFrame"
    frame.Size = UDim2.new(0, 380, 0, 280)
    frame.Position = UDim2.new(0.5, -190, 0, 65)
    frame.BackgroundColor3 = Color3.fromRGB(15, 15, 25)
    frame.BackgroundTransparency = 0.08
    frame.BorderSizePixel = 0
    frame.Visible = true
    frame.Parent = screenGui

    local frameStroke = Instance.new("UIStroke")
    frameStroke.Color = Color3.fromRGB(80, 80, 140)
    frameStroke.Thickness = 1
    frameStroke.Transparency = 0.4
    frameStroke.Parent = frame

    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)
    makeDraggable(frame)

    -- Title bar
    local titleBar = Instance.new("Frame")
    titleBar.Size = UDim2.new(1, 0, 0, 32)
    titleBar.BackgroundColor3 = Color3.fromRGB(25, 25, 45)
    titleBar.BackgroundTransparency = 0.3
    titleBar.BorderSizePixel = 0
    titleBar.Parent = frame

    Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 10)

    local titleLabel = Instance.new("TextLabel")
    titleLabel.Size = UDim2.new(1, -16, 1, 0)
    titleLabel.Position = UDim2.new(0, 10, 0, 0)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Font = Enum.Font.GothamBold
    titleLabel.TextSize = 14
    titleLabel.TextColor3 = Color3.fromRGB(255, 220, 80)
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.Text = "🌙 Auto Kick Full Moon V2"
    titleLabel.Parent = titleBar

    -- Version badge
    local vBadge = Instance.new("TextLabel")
    vBadge.Size = UDim2.new(0, 30, 0, 16)
    vBadge.Position = UDim2.new(1, -42, 0.5, -8)
    vBadge.BackgroundColor3 = Color3.fromRGB(255, 220, 80)
    vBadge.BackgroundTransparency = 0.1
    vBadge.Font = Enum.Font.GothamBold
    vBadge.TextSize = 10
    vBadge.TextColor3 = Color3.fromRGB(15, 15, 25)
    vBadge.Text = "V2"
    vBadge.Parent = titleBar
    Instance.new("UICorner", vBadge).CornerRadius = UDim.new(0, 4)

    -- ═══ Status Section ═══
    local statusFrame = Instance.new("Frame")
    statusFrame.Size = UDim2.new(1, -16, 0, 110)
    statusFrame.Position = UDim2.new(0, 8, 0, 38)
    statusFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 35)
    statusFrame.BackgroundTransparency = 0.4
    statusFrame.BorderSizePixel = 0
    statusFrame.Parent = frame
    Instance.new("UICorner", statusFrame).CornerRadius = UDim.new(0, 6)

    local statusLabel = Instance.new("TextLabel")
    statusLabel.Name = "StatusLabel"
    statusLabel.Size = UDim2.new(1, -12, 1, -8)
    statusLabel.Position = UDim2.new(0, 6, 0, 4)
    statusLabel.BackgroundTransparency = 1
    statusLabel.Font = Enum.Font.Code
    statusLabel.TextSize = 14
    statusLabel.TextColor3 = Color3.fromRGB(170, 255, 170)
    statusLabel.TextXAlignment = Enum.TextXAlignment.Left
    statusLabel.TextYAlignment = Enum.TextYAlignment.Top
    statusLabel.RichText = true
    statusLabel.Text = "Đang khởi tạo..."
    statusLabel.TextWrapped = true
    statusLabel.Parent = statusFrame

    -- ═══ Log Section ═══
    local logHeader = Instance.new("TextLabel")
    logHeader.Size = UDim2.new(1, -16, 0, 18)
    logHeader.Position = UDim2.new(0, 8, 0, 154)
    logHeader.BackgroundTransparency = 1
    logHeader.Font = Enum.Font.GothamBold
    logHeader.TextSize = 11
    logHeader.TextColor3 = Color3.fromRGB(150, 150, 200)
    logHeader.TextXAlignment = Enum.TextXAlignment.Left
    logHeader.Text = "📋 LOG"
    logHeader.Parent = frame

    local logFrame = Instance.new("Frame")
    logFrame.Size = UDim2.new(1, -16, 0, 95)
    logFrame.Position = UDim2.new(0, 8, 0, 174)
    logFrame.BackgroundColor3 = Color3.fromRGB(10, 10, 20)
    logFrame.BackgroundTransparency = 0.3
    logFrame.BorderSizePixel = 0
    logFrame.Parent = frame
    Instance.new("UICorner", logFrame).CornerRadius = UDim.new(0, 6)

    local logLabel = Instance.new("TextLabel")
    logLabel.Name = "LogLabel"
    logLabel.Size = UDim2.new(1, -10, 1, -6)
    logLabel.Position = UDim2.new(0, 5, 0, 3)
    logLabel.BackgroundTransparency = 1
    logLabel.Font = Enum.Font.Code
    logLabel.TextSize = 11
    logLabel.TextColor3 = Color3.fromRGB(130, 130, 160)
    logLabel.TextXAlignment = Enum.TextXAlignment.Left
    logLabel.TextYAlignment = Enum.TextYAlignment.Top
    logLabel.TextWrapped = true
    logLabel.Text = ""
    logLabel.Parent = logFrame

    -- Toggle
    toggleBtn.MouseButton1Click:Connect(function()
        frame.Visible = not frame.Visible
        -- Hiệu ứng nhấp nháy nút
        local origColor = toggleBtn.BackgroundColor3
        toggleBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 90)
        task.delay(0.15, function()
            toggleBtn.BackgroundColor3 = origColor
        end)
    end)

    return {
        statusLabel = statusLabel,
        logLabel = logLabel,
        frameStroke = frameStroke,
        toggleStroke = toggleStroke,
    }
end

local ui = createUI()

addLog("Script V2 khởi động")
addLog("Kick mốc: " .. formatTime(CONFIG.KICK_AFTER_HOUR, CONFIG.KICK_AFTER_MINUTE))
addLog("Window: " .. formatTime(CONFIG.FULL_MOON_WINDOW_START_HOUR, CONFIG.FULL_MOON_WINDOW_START_MINUTE)
    .. " → " .. formatTime(CONFIG.FULL_MOON_WINDOW_END_HOUR, CONFIG.FULL_MOON_WINDOW_END_MINUTE))

-- ═══════════════════════════════════════════════
-- STATE COLOR MAP
-- ═══════════════════════════════════════════════
local stateColors = {
    [STATE.SEARCHING_FULL] = {
        text = Color3.fromRGB(170, 220, 255),
        stroke = Color3.fromRGB(80, 80, 140),
    },
    [STATE.FULL_ACTIVE] = {
        text = Color3.fromRGB(255, 255, 100),
        stroke = Color3.fromRGB(200, 200, 50),
    },
    [STATE.WAITING_END] = {
        text = Color3.fromRGB(255, 180, 100),
        stroke = Color3.fromRGB(200, 130, 50),
    },
    [STATE.KICKED] = {
        text = Color3.fromRGB(255, 100, 100),
        stroke = Color3.fromRGB(200, 50, 50),
    },
}

-- ═══════════════════════════════════════════════
-- MAIN LOOP
-- ═══════════════════════════════════════════════
local prevState = nil

while task.wait(CONFIG.CHECK_INTERVAL) do
    local h, m = getServerTimeParts()
    local timeText = formatTime(h, m)
    local inWindow = isInFullMoonWindow(h, m)
    local canKick = isAfterKickThreshold(h, m)

    local isFull, textureInfo = isFullByTexture()
    local moonDisplay = getMoonPhaseDisplay()

    -- Detect time jump (server skip time)
    local currentClock = Lighting.ClockTime
    if lastClockTime then
        local diff = math.abs(currentClock - lastClockTime)
        -- Nếu time nhảy hơn 0.5 giờ bất thường (trừ wrap 24→0)
        if diff > 0.5 and diff < 23.5 then
            addLog("⚠️ Time jump: " .. string.format("%.2f→%.2f", lastClockTime, currentClock))
        end
    end
    lastClockTime = currentClock

    -- ═══ STATE MACHINE ═══
    if currentState == STATE.SEARCHING_FULL then
        if inWindow and isFull then
            seenFullStableTicks = seenFullStableTicks + 1
            if seenFullStableTicks >= CONFIG.STABLE_TICKS_FOR_FULL then
                currentState = STATE.FULL_ACTIVE
                seenEndStableTicks = 0
                seenWindowEndTicks = 0  -- FIX: reset cả biến này
                fullMoonDetectedAt = timeText
                addLog("🌕 Full Moon xác nhận! (" .. textureInfo .. ")")
            end
        else
            seenFullStableTicks = 0
        end

    elseif currentState == STATE.FULL_ACTIVE then
        -- Cách 1: Texture không còn full
        if not isFull then
            seenEndStableTicks = seenEndStableTicks + 1
            if seenEndStableTicks == 1 then
                addLog("🌑 Texture đổi: " .. tostring(textureInfo))
            end
        else
            seenEndStableTicks = 0
        end

        -- Cách 2 (backup): Ra khỏi cửa sổ thời gian
        if not inWindow then
            seenWindowEndTicks = seenWindowEndTicks + 1
            if seenWindowEndTicks == 1 then
                addLog("⏰ Ra khỏi window time")
            end
        else
            seenWindowEndTicks = 0
        end

        -- Chuyển state
        if seenEndStableTicks >= CONFIG.STABLE_TICKS_FOR_END then
            currentState = STATE.WAITING_END
            addLog("✅ Full Moon kết thúc (texture)")
        elseif seenWindowEndTicks >= CONFIG.STABLE_TICKS_FOR_END then
            currentState = STATE.WAITING_END
            addLog("✅ Full Moon kết thúc (window)")
        end

    elseif currentState == STATE.WAITING_END then
        if canKick then
            currentState = STATE.KICKED
            addLog("🚪 KICK!")
            -- Update UI 1 lần cuối trước khi kick
            ui.statusLabel.Text = '<font color="#ff6666">ĐÃ KICK - ' .. timeText .. '</font>'
            task.wait(0.5)
            LocalPlayer:Kick(CONFIG.KICK_MESSAGE)
            break
        end
    end

    -- Force kick
    if CONFIG.FORCE_KICK_AT_THRESHOLD and canKick and currentState ~= STATE.KICKED then
        currentState = STATE.KICKED
        addLog("🚪 FORCE KICK!")
        ui.statusLabel.Text = '<font color="#ff6666">FORCE KICK - ' .. timeText .. '</font>'
        task.wait(0.5)
        LocalPlayer:Kick(CONFIG.KICK_MESSAGE)
        break
    end

    -- Log state change
    if currentState ~= prevState then
        if prevState ~= nil then
            addLog("State → " .. currentState)
        end
        prevState = currentState

        -- Đổi màu viền theo state
        local colors = stateColors[currentState]
        if colors then
            pcall(function()
                TweenService:Create(ui.frameStroke, TweenInfo.new(0.3), {Color = colors.stroke}):Play()
                TweenService:Create(ui.toggleStroke, TweenInfo.new(0.3), {Color = colors.stroke}):Play()
            end)
        end
    end

    -- ═══ UPDATE UI ═══
    local minutesToKick = getMinutesUntilKick(h, m)
    local kickCountdown = ""
    if currentState == STATE.WAITING_END then
        local kh = math.floor(minutesToKick / 60)
        local km = minutesToKick % 60
        kickCountdown = string.format("\nKick trong: <font color=\"#ff9966\">%dh %02dphút</font>", kh, km)
    end

    local windowStatus = inWindow and '<font color="#66ff66">TRONG</font>' or '<font color="#ff6666">NGOÀI</font>'
    local fullStatus = isFull and '<font color="#ffff66">FULL ✓</font>' or '<font color="#888888">Không</font>'

    local statusText = string.format(
        '<font color="#aaaaff">⏰ Server Time:</font> <font color="#ffffff">%s</font>\n'
        .. '<font color="#aaaaff">🌙 Moon Phase:</font> <font color="#ffffff">%s</font>  |  Full: %s\n'
        .. '<font color="#aaaaff">📍 Window:</font> %s\n'
        .. '<font color="#aaaaff">📌 State:</font> <font color="#ffffff">%s</font>'
        .. '%s',
        timeText,
        moonDisplay,
        fullStatus,
        windowStatus,
        currentState,
        kickCountdown
    )

    if fullMoonDetectedAt then
        statusText = statusText .. string.format(
            '\n<font color="#aaaaff">🕐 Full Moon lúc:</font> <font color="#ffff66">%s</font>',
            fullMoonDetectedAt
        )
    end

    ui.statusLabel.Text = statusText

    -- Update log
    ui.logLabel.Text = table.concat(logLines, "\n")
end
