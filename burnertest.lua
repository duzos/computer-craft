-- burnertest.lua  --  Create: Avionics hot air burner (gas_provider) diagnostic + setter
-- run on a computer touching the burner(s), or wired to them via a modem.
-- handles MULTIPLE burners (e.g. one left + one right): set/altitude drive all of them.
-- interactive (default): type a number (e.g. 310) to set the max hot air output; it reads back.
--   i / info       one-shot snapshot incl. the peripheral's real method list
--   w / watch      live readout (press a key to stop)
--   a / altitude   altitude-hold loop (see below)
--   q              quit
-- one-shot from the shell too:  burnertest watch | burnertest set 310 | burnertest altitude 120
--
-- ALTITUDE HOLD ("burnertest altitude [Y]"):
--   closed loop holding a world-Y by driving BOTH the redstone signal (0-15, on RS_SIDES) and
--   the max gas output (setTargetAmount). burner output = target * signal/15, so a PID picks a
--   desired output and splits it: signal = coarse band, target = fine trim within it.
--   altitude comes from an Avionics `altitude_sensor` if present; otherwise it falls back to the
--   radio-GPS (gps2) estimate - which is COARSE on Y (towers near-coplanar, ~6m off) and needs
--   the radio antenna. up/down (or +/-) nudge the target Y; q cuts redstone and exits.
--   the KP/KI/KD gains are guesses - tune them in game.

local RS_SIDES   = { "left", "right" }  -- sides the computer feeds redstone into the burners
local RADIO_FREQ = 1000                 -- fleet radio freq, only used for the GPS altitude fallback

local MAX_OUT    = 500   -- ceiling for max gas output (lower it if your burners cap below 500)
local MIN_OUT    = 5     -- burner's minimum settable target
local KP, KI, KD = 12, 1.5, 25  -- altitude PID gains (gentler = less aggressive; tune in game)
local OUT_SMOOTH = 0.3   -- 0..1 output slew per tick (lower = finer/gentler, more lag)
local CONTROL_DT = 0.2   -- seconds between control ticks (lower = pings/corrects more often)
local GPS_FIX_TIME = 1.0 -- GPS fallback: seconds per fix (lower = more frequent pings, noisier)
local GPS_PINGS    = 4   -- GPS fallback: pings gathered per fix
local Y_STEP     = 1     -- target-altitude nudge per key press

local function findBurners()
  local list, seen = {}, {}
  for _, p in ipairs({ peripheral.find("gas_provider") }) do
    local nm = peripheral.getName(p)
    if not seen[nm] then seen[nm] = true; list[#list + 1] = { p = p, name = nm } end
  end
  if #list == 0 then
    for _, n in ipairs(peripheral.getNames()) do
      local t = (peripheral.getType(n) or ""):lower()
      if (t:find("gas") or t:find("burner")) and not seen[n] then
        seen[n] = true; list[#list + 1] = { p = peripheral.wrap(n), name = n }
      end
    end
  end
  return list
end

local burners = findBurners()
if #burners == 0 then
  print("No gas_provider (hot air burner) found. Peripherals seen:")
  for _, n in ipairs(peripheral.getNames()) do
    print("  " .. n .. "  (" .. (peripheral.getType(n) or "?") .. ")")
  end
  return
end
local rep = burners[1]

local function callm(p, m, ...)
  local ok, r = pcall(p[m], ...)
  if ok then return r end
  return nil
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
  print(("%d burner(s) | redstone on %s"):format(#burners, table.concat(RS_SIDES, "+")))
  for _, b in ipairs(burners) do
    print(("  %s | active %s | sig %s/15 | max %s -> out %s")
      :format(b.name, fmt(callm(b.p, "isActive")), fmt(callm(b.p, "getSignalStrength")),
              fmt(callm(b.p, "getTargetAmount")), fmt(callm(b.p, "getGasOutput"))))
  end
  if callm(rep.p, "hasBalloon") == true then
    print(("balloon: %s / %s filled (cap %s) | lift %s | dV %s")
      :format(fmt(callm(rep.p, "getBalloonFilledVolume")), fmt(callm(rep.p, "getBalloonTargetVolume")),
              fmt(callm(rep.p, "getBalloonCapacity")), fmt(callm(rep.p, "getBalloonLift")),
              fmt(callm(rep.p, "getBalloonVolumeChange"))))
  else
    print("balloon: none attached")
  end
end

local function info()
  print("type: " .. (peripheral.getType(rep.name) or "?"))
  print("methods: " .. table.concat(peripheral.getMethods(rep.name), ", "))
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
  local okAny = false
  for _, b in ipairs(burners) do
    local ok = pcall(b.p.setTargetAmount, n); okAny = okAny or ok
  end
  if not okAny then print("  setTargetAmount failed (no such method?)"); return end
  print(("  max output set %d on %d burner(s) -> now %s")
    :format(n, #burners, fmt(callm(rep.p, "getTargetAmount"))))
end

-- split a desired output u into (redstone signal, max gas target): output = target*signal/15.
-- signal is the coarse band, target the fine trim; applied to every burner / redstone side.
local function applyOutput(u)
  u = clamp(u, 0, MAX_OUT)
  local step = MAX_OUT / 15
  local signal = clamp(math.ceil(u / step - 1e-9), 0, 15)
  local target = MIN_OUT
  if signal > 0 then target = clamp(math.floor(u * 15 / signal + 0.5), MIN_OUT, MAX_OUT) end
  for _, s in ipairs(RS_SIDES) do redstone.setAnalogOutput(s, signal) end
  for _, b in ipairs(burners) do pcall(b.p.setTargetAmount, target) end
  return signal, target
end

-- altitude provider: prefer the Avionics altitude_sensor; else fall back to the radio-GPS.
local function makeAltSource()
  local sensor = peripheral.find("altitude_sensor")
  if sensor then
    return {
      kind = "altitude_sensor",
      y  = function() local ok, v = pcall(sensor.getHeight); return ok and v or nil end,
      vs = function() local ok, v = pcall(sensor.getVerticalSpeed); return ok and v or nil end,
    }
  end
  local ok, gps2 = pcall(require, "gps2")
  if not ok then return nil, "no altitude_sensor and gps2 lib unavailable" end
  local okc, comms = pcall(require, "comms")
  if okc then pcall(comms.open, { freq = RADIO_FREQ }) end
  return {
    kind = "gps(estimate)",
    y  = function() local fix = gps2.locate(GPS_FIX_TIME, GPS_PINGS); return fix and fix.y or nil end,
    vs = function() return nil end,   -- GPS gives no vspeed; derived from successive Y in the loop
  }
end

local function altitude(argY)
  local src, serr = makeAltSource()
  if not src then
    print("altitude hold needs an altitude_sensor or the radio-GPS: " .. tostring(serr))
    return
  end
  print("altitude source: " .. src.kind)
  if src.kind ~= "altitude_sensor" then
    print("WARNING: GPS Y is a coarse estimate (towers near-coplanar, ~6m off).")
  end

  local targetY = tonumber(argY) or src.y()
  if not targetY then print("could not read current altitude - aborting"); return end
  targetY = math.floor(targetY + 0.5)

  print(("altitude hold engaging - target Y %d  (redstone on %s)")
    :format(targetY, table.concat(RS_SIDES, "+")))
  local integ = 0
  local uPrev = 0
  local prevY, prevT = nil, nil
  local timer = os.startTimer(CONTROL_DT)
  while true do
    local ev, p = os.pullEvent()
    if ev == "timer" and p == timer then
      local now = os.clock()
      local cy = src.y()
      term.clear(); term.setCursorPos(1, 1)
      print("altitude hold  (" .. src.kind .. ", up/down or +/- nudge target Y, q to quit)")
      if cy then
        local dt = (prevT and (now - prevT)) or CONTROL_DT
        if dt <= 0 then dt = CONTROL_DT end
        local speed = src.vs()
        if not speed then speed = (prevY ~= nil) and ((cy - prevY) / dt) or 0 end
        local err = targetY - cy
        integ = clamp(integ + err * KI * dt, 0, MAX_OUT)
        local uRaw = clamp(KP * err - KD * speed + integ, 0, MAX_OUT)
        local u = uPrev + OUT_SMOOTH * (uRaw - uPrev)
        uPrev = u
        local sig, tgt = applyOutput(u)
        print(("target Y %d | now %s | err %+.1f | vspeed %+.2f")
          :format(targetY, fmt(cy), err, speed))
        print(("output %.0f -> signal %d/15, max gas %d  (burner reads %s)")
          :format(u, sig, tgt, fmt(callm(rep.p, "getSignalStrength"))))
        print(("balloon lift %s | fill %s / %s")
          :format(fmt(callm(rep.p, "getBalloonLift")), fmt(callm(rep.p, "getBalloonFilledVolume")),
                  fmt(callm(rep.p, "getBalloonTargetVolume"))))
        prevY, prevT = cy, now
      else
        print("no altitude reading this tick - holding actuators")
      end
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
  for _, s in ipairs(RS_SIDES) do redstone.setAnalogOutput(s, 0) end
  print("altitude hold stopped - redstone cut to 0 (burners idle).")
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
