-- burnertest.lua  --  Create: Avionics hot air burner (gas_provider) diagnostic + setter
-- run on a computer placed against the burner, or wired to it via a modem.
-- interactive (default): type a number (e.g. 310) to set the max hot air output; it reads back.
--   i / info       one-shot snapshot incl. the peripheral's real method list
--   w / watch      live readout (press a key to stop)
--   a / altitude   altitude-hold loop (see below)
--   q              quit
-- one-shot from the shell too:  burnertest watch | burnertest set 310 | burnertest altitude 120
--
-- ALTITUDE HOLD ("burnertest altitude [Y]"):
--   closed loop that holds a world-Y by driving BOTH the redstone signal (0-15) and the max gas
--   output (setTargetAmount). actual burner output = target * signal/15, so a PID picks a desired
--   output and splits it: signal = coarse band, target = fine trim within it.
--   needs an Avionics `altitude_sensor` on the network, and the computer must feed redstone into
--   the burner on RS_SIDE. up/down (or +/-) nudge the target Y; q cuts redstone and exits.
--   the KP/KI/KD gains are guesses - tune them in game.

local RS_SIDE = "back"   -- side the computer feeds redstone into the burner: top/bottom/left/right/front/back

local MAX_OUT    = 500   -- ceiling for max gas output (lower it if your burner caps below 500)
local MIN_OUT    = 5     -- burner's minimum settable target
local KP, KI, KD = 40, 5, 60
local CONTROL_DT = 0.5   -- seconds between control ticks
local Y_STEP     = 1     -- target-altitude nudge per key press

local function findBurner()
  local p = peripheral.find("gas_provider")
  if p then return p, peripheral.getName(p) end
  for _, n in ipairs(peripheral.getNames()) do
    local t = (peripheral.getType(n) or ""):lower()
    if t:find("gas") or t:find("burner") then return peripheral.wrap(n), n end
  end
end

local burner, name = findBurner()
if not burner then
  print("No gas_provider (hot air burner) found. Peripherals seen:")
  for _, n in ipairs(peripheral.getNames()) do
    print("  " .. n .. "  (" .. (peripheral.getType(n) or "?") .. ")")
  end
  return
end

local methodSet = {}
for _, m in ipairs(peripheral.getMethods(name)) do methodSet[m] = true end
local function has(m) return methodSet[m] == true end

local function get(m, ...)
  if not has(m) then return nil, "no method" end
  local ok, r = pcall(burner[m], ...)
  if ok then return r end
  return nil, tostring(r)
end

local function fmt(x)
  if type(x) == "number" then
    if x == math.floor(x) then return tostring(x) end
    return string.format("%.2f", x)
  end
  if x == nil then return "-" end
  return tostring(x)
end

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end

local function snapshot()
  print("burner: " .. name .. "  (" .. (peripheral.getType(name) or "?") .. ")")
  print(("active %s | signal %s/15 | gas %s")
    :format(fmt(get("isActive")), fmt(get("getSignalStrength")), fmt(get("getGasType"))))
  print(("max output %s -> current output %s | efficiency %s")
    :format(fmt(get("getTargetAmount")), fmt(get("getGasOutput")), fmt(get("getBoilerEfficiency"))))
  if get("hasBalloon") == true then
    print(("balloon: %s / %s filled (cap %s) | lift %s | dV %s")
      :format(fmt(get("getBalloonFilledVolume")), fmt(get("getBalloonTargetVolume")),
              fmt(get("getBalloonCapacity")), fmt(get("getBalloonLift")),
              fmt(get("getBalloonVolumeChange"))))
  else
    print("balloon: none attached")
  end
end

local function info()
  print("methods: " .. table.concat(peripheral.getMethods(name), ", "))
  snapshot()
end

local function watch()
  while true do
    term.clear(); term.setCursorPos(1, 1)
    print("burner watch  (press a key to stop)")
    snapshot()
    local timer = os.startTimer(1)
    while true do
      local ev = { os.pullEvent() }
      if ev[1] == "timer" and ev[2] == timer then break end
      if ev[1] == "key" or ev[1] == "char" then return end
    end
  end
end

local function setTarget(n)
  if not has("setTargetAmount") then print("  no setTargetAmount on this peripheral"); return end
  local ok, err = pcall(burner.setTargetAmount, n)
  if not ok then print("  ERR " .. tostring(err)); return end
  print(("  max output set %d -> now %s"):format(n, fmt(get("getTargetAmount"))))
end

-- split a desired output u into (redstone signal, max gas target): output = target*signal/15
local function applyOutput(u)
  u = clamp(u, 0, MAX_OUT)
  local step = MAX_OUT / 15
  local signal = clamp(math.ceil(u / step - 1e-9), 0, 15)
  local target = MIN_OUT
  if signal <= 0 then
    redstone.setAnalogOutput(RS_SIDE, 0)
  else
    target = clamp(math.floor(u * 15 / signal + 0.5), MIN_OUT, MAX_OUT)
    redstone.setAnalogOutput(RS_SIDE, signal)
  end
  if has("setTargetAmount") then pcall(burner.setTargetAmount, target) end
  return signal, target
end

local function altitude(argY)
  local sensor = peripheral.find("altitude_sensor")
  if not sensor then
    print("No altitude_sensor found - altitude hold needs one on the network. Peripherals seen:")
    for _, n in ipairs(peripheral.getNames()) do
      print("  " .. n .. "  (" .. (peripheral.getType(n) or "?") .. ")")
    end
    return
  end
  local function readY()  local ok, v = pcall(sensor.getHeight);        return ok and v or nil end
  local function readVS() local ok, v = pcall(sensor.getVerticalSpeed); return ok and v or 0 end

  local targetY = tonumber(argY) or readY()
  if not targetY then print("altitude_sensor.getHeight() returned nothing - aborting"); return end
  targetY = math.floor(targetY + 0.5)

  print(("altitude hold engaging - target Y %d  (redstone on '%s')"):format(targetY, RS_SIDE))
  local integ = 0
  local timer = os.startTimer(CONTROL_DT)
  while true do
    local ev, p = os.pullEvent()
    if ev == "timer" and p == timer then
      local cy = readY() or targetY
      local err = targetY - cy
      local speed = readVS()
      integ = clamp(integ + err * KI * CONTROL_DT, 0, MAX_OUT)
      local u = clamp(KP * err - KD * speed + integ, 0, MAX_OUT)
      local sig, tgt = applyOutput(u)
      term.clear(); term.setCursorPos(1, 1)
      print("altitude hold  (up/down or +/- nudge target Y, q to quit)")
      print(("target Y %d | now %s | err %+.1f | vspeed %+.2f")
        :format(targetY, fmt(cy), err, speed))
      print(("output %.0f -> signal %d/15, max gas %d  (burner reads %s)")
        :format(u, sig, tgt, fmt(get("getSignalStrength"))))
      print(("balloon lift %s | fill %s / %s")
        :format(fmt(get("getBalloonLift")), fmt(get("getBalloonFilledVolume")),
                fmt(get("getBalloonTargetVolume"))))
      timer = os.startTimer(CONTROL_DT)
    elseif ev == "key" then
      if p == keys.up then targetY = targetY + Y_STEP
      elseif p == keys.down then targetY = targetY - Y_STEP
      elseif p == keys.q then break end
    elseif ev == "char" then
      if p == "+" or p == "=" then targetY = targetY + Y_STEP
      elseif p == "-" or p == "_" then targetY = targetY - Y_STEP
      elseif p == "q" then break end
    end
  end
  redstone.setAnalogOutput(RS_SIDE, 0)
  print("altitude hold stopped - redstone cut to 0 (burner idle).")
end

local function loop()
  print('burner control  -- number = set max output (~5-500), "i" info, "w" watch, "a" altitude, "q" quit')
  snapshot()
  while true do
    write("> ")
    local line = (read() or ""):gsub("^%s*(.-)%s*$", "%1"):lower()
    if line == "q" or line == "quit" then break
    elseif line == "i" or line == "info" then info()
    elseif line == "w" or line == "watch" then watch()
    elseif line == "a" or line == "altitude" then altitude()
    elseif line ~= "" then
      local n = tonumber(line)
      if n and n >= 0 and n == math.floor(n) then setTarget(n)
      else print('  type a whole number, or "i" / "w" / "a" / "q"') end
    end
  end
end

local cmd, arg = ...
if cmd == "watch" then watch()
elseif cmd == "info" then info()
elseif cmd == "altitude" then altitude(arg)
elseif cmd == "set" then
  local n = tonumber(arg)
  if n then setTarget(n) else print("usage: burnertest set <number>") end
else loop() end
