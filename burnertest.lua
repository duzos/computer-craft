-- burnertest.lua  --  Create: Avionics hot air burner (gas_provider) diagnostic + setter
-- run on a computer touching the burner(s), or wired to them via a modem.
-- handles MULTIPLE burners (e.g. left + right): set/altitude drive all of them.
--   i / info       one-shot snapshot incl. the peripheral's real method list
--   w / watch      live readout (press a key to stop)
--   a / altitude   altitude-hold loop (see below)
--   q              quit
-- shell one-shots:  burnertest watch | burnertest set 310 | burnertest altitude 120
--
-- ALTITUDE HOLD ("burnertest altitude [Y]"):
--   holds a world-Y by driving BOTH the redstone signal (0-15, on RS_SIDES) and the max gas
--   output (setTargetAmount); burner output = target*signal/15, split coarse(signal)/fine(target).
--   Control is PREDICTIVE: it steers on where it WILL be in LOOKAHEAD seconds (cy + vspeed*LOOKAHEAD),
--   so it eases off the throttle EARLY instead of chasing the laggy balloon - raise LOOKAHEAD to
--   match how long the balloons take to fill. A gated integral finds the steady hover output, and
--   OUT_SMOOTH slews the throttle so it never slams.
--   Altitude/vspeed come from an Avionics altitude_sensor if present, else the radio-GPS (gps2,
--   coarse on Y). X/Z for the readout come from the radio-GPS when available.
--   If an advanced MONITOR is attached it shows a live dashboard (XYZ, vspeed, output, balloon) with
--   touch -10/-1/+1/+10 buttons to set the target; the computer up/down or +/- keys also nudge it,
--   q quits. Gains are guesses - tune in game.

local RS_SIDES   = { "left", "right" }  -- sides the computer feeds redstone into the burners
local RADIO_FREQ = 1000                 -- fleet radio freq, used for the GPS altitude/position source

local MAX_OUT    = 500   -- ceiling for max gas output (lower it if your burners cap below 500)
local MIN_OUT    = 5     -- burner's minimum settable target
local KP, KI     = 5, 1.0  -- predictive proportional gain; gated integral (hover-find) gain
local LOOKAHEAD  = 5.0   -- s of prediction; RAISE to match balloon fill lag (the main "calm it down" knob)
local OUT_SMOOTH = 0.25  -- 0..1 output slew per tick (lower = gentler/finer, more lag)
local I_BAND     = 3     -- blocks: only build the hover integral within this of target...
local I_VMAX     = 0.5   -- m/s: ...and slower than this (anti-windup during climbs)
local CONTROL_DT = 0.2   -- seconds between control ticks
local GPS_FIX_TIME = 1.0 -- GPS: seconds per fix (lower = more frequent, noisier)
local GPS_PINGS    = 4   -- GPS: pings gathered per fix
local GPS_REFRESH  = 3.0 -- GPS: how often to refresh X/Z for the readout when a sensor drives Y
local MON_SCALE  = 0.5   -- monitor text scale (0.5 suits a short 1x3 monitor; raise for bigger ones)
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

-- split a desired output u into (redstone signal, max gas target): output = target*signal/15
local function decompose(u)
  u = clamp(u, 0, MAX_OUT)
  local step = MAX_OUT / 15
  local signal = clamp(math.ceil(u / step - 1e-9), 0, 15)
  local target = MIN_OUT
  if signal > 0 then target = clamp(math.floor(u * 15 / signal + 0.5), MIN_OUT, MAX_OUT) end
  return signal, target
end

local function applyOutput(u)
  local signal, target = decompose(u)
  for _, s in ipairs(RS_SIDES) do redstone.setAnalogOutput(s, signal) end
  for _, b in ipairs(burners) do pcall(b.p.setTargetAmount, target) end
  return signal, target
end

local function altitude(argY)
  local sensor = peripheral.find("altitude_sensor")
  local gps2, gpsReady
  do
    local ok, lib = pcall(require, "gps2")
    if ok then
      gps2 = lib
      local okc, comms = pcall(require, "comms")
      if okc then pcall(comms.open, { freq = RADIO_FREQ }) end
      gpsReady = true
    end
  end
  if not sensor and not gpsReady then
    print("altitude hold needs an altitude_sensor or the radio-GPS (gps2) - neither available.")
    return
  end

  local mon = peripheral.find("monitor")
  if mon then pcall(mon.setTextScale, MON_SCALE) end

  local gx, gy, gz, lastGpsAt = nil, nil, nil, -1e9
  local prevGY, prevGT = nil, nil

  -- one nav sample: {x,y,z,vspeed,ysrc}. sensor drives Y/vspeed when present (fast); GPS gives
  -- X/Z (refreshed every GPS_REFRESH) and is the Y source when there is no sensor.
  local function sample(now)
    local x, y, z, vs, ysrc
    if sensor then
      local ok1, hy = pcall(sensor.getHeight);        if ok1 then y = hy end
      local ok2, sv = pcall(sensor.getVerticalSpeed); if ok2 then vs = sv end
      ysrc = "sensor"
      if gpsReady and (now - lastGpsAt) >= GPS_REFRESH then
        local fix = gps2.locate(GPS_FIX_TIME, GPS_PINGS)
        if fix then gx, gy, gz, lastGpsAt = fix.x, fix.y, fix.z, now end
      end
      x, z = gx, gz
    elseif gpsReady then
      local fix = gps2.locate(GPS_FIX_TIME, GPS_PINGS)
      if fix then
        x, y, z = fix.x, fix.y, fix.z
        ysrc = "gps"
        if prevGY ~= nil and now > prevGT then vs = (y - prevGY) / (now - prevGT) else vs = 0 end
        prevGY, prevGT = y, now
      end
    end
    return { x = x, y = y, z = z, vspeed = vs, ysrc = ysrc }
  end

  local targetY = tonumber(argY) or sample(os.clock()).y
  if not targetY then print("could not read current altitude - aborting"); return end
  targetY = math.floor(targetY + 0.5)

  -- compact wide layout (suits a short 1x3 monitor): 5 short rows, buttons on the last
  local buttons = {}
  local function render(st, u, sig, tgt, err, holding)
    buttons = {}
    local dev = mon or term
    if mon then mon.setBackgroundColor(colors.black); mon.setTextColor(colors.white); mon.clear()
    else term.clear(); term.setCursorPos(1, 1) end
    local line = 1
    local function put(s) dev.setCursorPos(1, line); dev.write(s); line = line + 1 end
    put(("ALT [%s] X %s Y %s Z %s"):format(st.ysrc or "no fix", fmt(st.x), fmt(st.y), fmt(st.z)))
    put(("tgt %d  vs %s  err %+.1f%s"):format(targetY,
      st.vspeed and string.format("%+.2f", st.vspeed) or "-", err, holding and " HOLD" or ""))
    put(("out %s sig %d/15 gas %d"):format(fmt(u), sig, tgt))
    put(("lift %s fill %s/%s"):format(fmt(callm(rep.p, "getBalloonLift")),
      fmt(callm(rep.p, "getBalloonFilledVolume")), fmt(callm(rep.p, "getBalloonTargetVolume"))))
    local bx = 1
    local function btn(label, d)
      dev.setCursorPos(bx, line); dev.write(label)
      if mon then buttons[#buttons + 1] = { x1 = bx, x2 = bx + #label - 1, y = line, d = d } end
      bx = bx + #label + 1
    end
    btn("[-10]", -10); btn("[-1]", -1); btn("[+1]", 1); btn("[+10]", 10)
    if not mon then dev.write(" +/- keys") end
    line = line + 1
    put("q quits")
  end

  print("altitude source: " .. (sensor and "altitude_sensor" or "gps(estimate)") ..
        (mon and " | monitor dashboard on" or ""))
  local integ, uPrev, lastTick = 0, 0, nil
  local timer = os.startTimer(CONTROL_DT)
  while true do
    local ev = { os.pullEvent() }
    local e = ev[1]
    if e == "timer" and ev[2] == timer then
      local now = os.clock()
      local dt = (lastTick and (now - lastTick)) or CONTROL_DT
      if dt <= 0 then dt = CONTROL_DT end
      lastTick = now
      local st = sample(now)
      local u, sig, tgt, err, holding = uPrev, 0, MIN_OUT, 0, true
      if st.y then
        holding = false
        local speed = st.vspeed or 0
        err = targetY - st.y
        local predErr = targetY - (st.y + speed * LOOKAHEAD)
        if math.abs(err) <= I_BAND and math.abs(speed) <= I_VMAX then
          integ = clamp(integ + err * KI * dt, 0, MAX_OUT)
        end
        local uRaw = clamp(integ + KP * predErr, 0, MAX_OUT)
        u = uPrev + OUT_SMOOTH * (uRaw - uPrev)
        uPrev = u
        sig, tgt = applyOutput(u)
      else
        sig, tgt = decompose(uPrev)
      end
      render(st, u, sig, tgt, err, holding)
      timer = os.startTimer(CONTROL_DT)
    elseif e == "key" then
      if ev[2] == keys.up then targetY = targetY + Y_STEP
      elseif ev[2] == keys.down then targetY = targetY - Y_STEP
      elseif ev[2] == keys.q then break end
    elseif e == "char" then
      if ev[2] == "+" or ev[2] == "=" then targetY = targetY + Y_STEP
      elseif ev[2] == "-" or ev[2] == "_" then targetY = targetY - Y_STEP
      elseif ev[2] == "q" then break end
    elseif e == "monitor_touch" then
      local tx, ty = ev[3], ev[4]
      for _, b in ipairs(buttons) do
        if ty == b.y and tx >= b.x1 and tx <= b.x2 then targetY = targetY + b.d; break end
      end
    end
  end
  for _, s in ipairs(RS_SIDES) do redstone.setAnalogOutput(s, 0) end
  if mon then pcall(mon.clear) end
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
