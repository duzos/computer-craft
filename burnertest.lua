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
--   Control is CASCADE: altitude error -> a commanded climb rate (climb<=V_UP, descent<=V_DN since a
--   balloon only cools passively), then a vspeed loop whose slow integral TRACKS the balancing throttle
--   (hover) on its own. Throttle is held to a BAND around that hover (UP_MARGIN/DOWN_MARGIN) so it can
--   neither overfill+overshoot nor cut power+plummet on the response lag. LEAD predicts ahead by the
--   lag; SMOOTH_TAU slews the output.
--   Altitude/vspeed: Avionics altitude_sensor if present, else the radio-GPS (gps2, coarse Y).
--   The radio-GPS is polled CONTINUOUSLY in the background for live X/Z (and Y when no sensor).
--   With an advanced MONITOR attached it shows a colour dashboard (gauges, XYZ, vspeed, balloon)
--   with touch -10/-1/+1/+10 target buttons; the computer up/down or +/- keys also nudge it, q quits.
--   SELF-TUNING: it learns this ship's hover throttle (the integral) and response lag (from the clean fill
--   telemetry) live, persisting {hover,lag} to STATE_FILE - so each ship and changing condition self-
--   calibrates with no hardcoding. Every run also logs telemetry to LOG_FILE (CSV) for analysis.

local RS_SIDES   = { "left", "right" }  -- sides the computer feeds redstone into the burners
local RADIO_FREQ = 1000                 -- fleet radio freq, used for the GPS altitude/position source

local MAX_OUT    = 500   -- ceiling for max gas output (lower it if your burners cap below 500)
local MIN_OUT    = 5     -- burner's minimum settable target
local HOVER0     = 250   -- hover throttle seed (logs: steady lift ~= 3*throttle, ship weight ~750 -> ~250)
local V_UP       = 4.0   -- max commanded CLIMB rate (m/s)
local V_DN       = 2.0   -- max commanded DESCENT rate (m/s) - balloon descends passively (cooling-limited)
local K_ALT      = 0.3   -- altitude error -> commanded vspeed (per block); lower = gentler approach
local KP_V, KI_V = 4, 2   -- vspeed->throttle gains; SLOW given the ~7s response lag; integral tracks hover
local DOWN_MARGIN = 120  -- MIN throttle band below learned hover (also scales up with hover); stops cut+plummet
local UP_MARGIN  = 120   -- MIN throttle band above learned hover; wider = faster (but more overshoot risk)
local LEAD       = 7.0   -- s; fallback prediction lead; the live estimate (learned from fill) overrides it
local SMOOTH_TAU = 0.8   -- output slew time-constant in s (plant is already slow; keep added lag small)
local CONTROL_DT = 0.1   -- seconds between control ticks (lower = Y/readout updates faster)
local GPS_FIX_TIME = 1.0 -- GPS: seconds for the initial one-shot fix (sets the default target)
local GPS_PINGS    = 4   -- GPS: pings for that initial fix
local GPS_PING_EVERY = 0.15  -- background poller: constant ping interval in s (lower = more constant)
local GPS_AVG        = 1.2   -- background poller: tower staleness + vspeed baseline window (s)
local MON_SCALE  = 0.5   -- monitor text scale (0.5 suits a 2x3; raise for bigger monitors)
local Y_STEP     = 1     -- target-altitude nudge per key press
local LOG_FILE   = "burnerlog.csv"  -- altitude-hold telemetry log (CSV); retrieve + share for tuning
local LOG_DT     = 0.2   -- seconds between logged CSV rows
local STATE_FILE = "burner.state"   -- per-ship learned tuning {hover,lag}; auto-saved + reloaded (self-calibration)
local LAG_LEARN  = 0.02  -- EMA rate for the online response-lag (LEAD) estimate from fill telemetry

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

local function cv(x)   -- CSV cell: numbers to 3dp, nil to empty
  if type(x) == "number" then return string.format("%.3f", x) end
  if x == nil then return "" end
  return tostring(x)
end

-- coloured drawing helpers (storepad style), on any term/monitor device
local function at(dev, x, y, s, fg, bg)
  if fg then dev.setTextColor(fg) end
  if bg then dev.setBackgroundColor(bg) end
  dev.setCursorPos(x, y); dev.write(s)
  dev.setBackgroundColor(colors.black); dev.setTextColor(colors.white)
end

local function bar(dev, x, y, w, frac, fill)
  local f = math.floor(clamp(frac, 0, 1) * w + 0.5)
  dev.setCursorPos(x, y)
  dev.setBackgroundColor(fill); dev.write(string.rep(" ", f))
  dev.setBackgroundColor(colors.gray); dev.write(string.rep(" ", w - f))
  dev.setBackgroundColor(colors.black)
end

local function fillRow(dev, y, w, bg)
  dev.setCursorPos(1, y); dev.setBackgroundColor(bg); dev.write(string.rep(" ", w))
  dev.setBackgroundColor(colors.black)
end

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
  local gps2, comms, gpsReady
  do
    local ok, lib = pcall(require, "gps2")
    if ok then
      gps2 = lib
      local okc, c = pcall(require, "comms")
      if okc then comms = c; pcall(comms.open, { freq = RADIO_FREQ }); gpsReady = true end
    end
  end
  if not sensor and not gpsReady then
    print("altitude hold needs an altitude_sensor or the radio-GPS (gps2) - neither available.")
    return
  end

  local mon = peripheral.find("monitor")
  if mon then pcall(mon.setTextScale, MON_SCALE) end

  -- per-ship learned tuning: reload {hover, lag}, fall back to the config defaults
  local integ, uPrev, lastTick = HOVER0, 0, nil
  local leadEst = LEAD
  if fs.exists(STATE_FILE) then
    local fh = fs.open(STATE_FILE, "r")
    if fh then
      local ok, d = pcall(textutils.unserialise, fh.readAll()); fh.close()
      if ok and type(d) == "table" then
        if type(d.hover) == "number" then integ = clamp(d.hover, MIN_OUT, MAX_OUT) end
        if type(d.lag) == "number" then leadEst = clamp(d.lag, 2, 15) end
      end
    end
  end
  local prevFill, prevFillT, lastSave = nil, nil, nil
  local function saveState()
    local fh = fs.open(STATE_FILE, "w")
    if fh then fh.write(textutils.serialise({ hover = integ, lag = leadEst })); fh.close() end
  end

  -- shared position, updated continuously by the background GPS poller
  local gx, gy, gz, gVspeed, gpsAt = nil, nil, nil, nil, nil
  -- streaming poller: pings at a fixed interval forever, re-solves on every tower response using each
  -- tower's LATEST distance (no averaging); vspeed over a short baseline since GPS Y is noisy.
  local function gpsLoop()
    local towers, yhist, lastPing = {}, {}, -1e9
    while true do
      local now = os.clock()
      if now - lastPing >= GPS_PING_EVERY then
        comms.send("all", { type = "gpsq" }, "gps")
        lastPing = now
      end
      local m = comms.receive("gps", GPS_PING_EVERY)
      now = os.clock()
      if m and m.dist and type(m.body) == "table" and m.body.type == "gpsr"
         and type(m.body.pos) == "table" then
        local t = towers[m.from]
        if not t then t = {}; towers[m.from] = t end
        t.pos = m.body.pos
        t.d, t.t = m.dist, now
      end
      local pts = {}
      for _, t in pairs(towers) do
        if t.t and (now - t.t) <= GPS_AVG then
          pts[#pts + 1] = { x = t.pos.x, y = t.pos.y, z = t.pos.z, d = t.d }
        end
      end
      if #pts >= 4 then
        local fix = gps2.trilaterate(pts)
        if fix then
          gx, gy, gz, gpsAt = fix.x, fix.y, fix.z, now
          yhist[#yhist + 1] = { t = now, y = fix.y }
          while #yhist > 1 and now - yhist[1].t > GPS_AVG do table.remove(yhist, 1) end
          if #yhist >= 2 and now > yhist[1].t then
            gVspeed = (fix.y - yhist[1].y) / (now - yhist[1].t)
          end
        end
      end
    end
  end

  local function readState()
    local x, y, z, vs, ysrc = gx, nil, gz, nil, nil
    if sensor then
      local ok1, hy = pcall(sensor.getHeight);        if ok1 then y = hy end
      local ok2, sv = pcall(sensor.getVerticalSpeed); if ok2 then vs = sv end
      ysrc = "sensor"
    elseif gy then
      local age = gpsAt and (os.clock() - gpsAt) or 0
      y, vs, ysrc = gy + (gVspeed or 0) * age, gVspeed or 0, "gps"   -- extrapolate between fixes
    end
    return { x = x, y = y, z = z, vspeed = vs, ysrc = ysrc }
  end

  local targetY = tonumber(argY)
  if not targetY then
    local st = readState()
    if not st.y and gpsReady then
      local fix = gps2.locate(GPS_FIX_TIME, GPS_PINGS)
      if fix then gx, gy, gz = fix.x, fix.y, fix.z; st = readState() end
    end
    targetY = st.y
  end
  if not targetY then print("could not read current altitude - aborting"); return end
  targetY = math.floor(targetY + 0.5)

  local logf = fs.open(LOG_FILE, "w")
  if logf then
    logf.writeLine("t,src,x,y,z,target,err,vspeed,wantv,u,sig,gas,bal,bsig,gasout,lift,fill,filltgt,dvol,cap,active")
  end
  local lastLog = nil
  local function logRow(st, u, sig, tgt, err, desiredV, bal, now)
    if not logf then return end
    if lastLog and (now - lastLog) < LOG_DT then return end
    lastLog = now
    logf.writeLine(table.concat({
      cv(now), st.ysrc or "", cv(st.x), cv(st.y), cv(st.z), cv(targetY), cv(err),
      cv(st.vspeed), cv(desiredV), cv(u), cv(sig), cv(tgt), cv(bal),
      cv(callm(rep.p, "getSignalStrength")), cv(callm(rep.p, "getGasOutput")),
      cv(callm(rep.p, "getBalloonLift")), cv(callm(rep.p, "getBalloonFilledVolume")),
      cv(callm(rep.p, "getBalloonTargetVolume")), cv(callm(rep.p, "getBalloonVolumeChange")),
      cv(callm(rep.p, "getBalloonCapacity")), cv(callm(rep.p, "isActive")),
    }, ","))
    logf.flush()
  end

  local buttons = {}
  local function render(st, u, sig, tgt, err, desiredV, hoverEst)
    local dev = mon or term
    local w, h = dev.getSize()
    dev.setBackgroundColor(colors.black); dev.setTextColor(colors.white); dev.clear()
    buttons = {}

    local status, scol
    if not st.y then status, scol = "NO FIX", colors.red
    elseif math.abs(err) <= 1 then status, scol = "HOLDING", colors.lime
    elseif err > 0 then status, scol = "CLIMB", colors.yellow
    else status, scol = "DESCEND", colors.orange end

    fillRow(dev, 1, w, colors.blue)
    at(dev, 1, 1, "HOT AIR BURNER", colors.white, colors.blue)
    at(dev, math.max(16, w - #status), 1, status, scol, colors.blue)

    local y = 3
    at(dev, 1, y, ("Y %s"):format(fmt(st.y)), colors.white)
    at(dev, 11, y, ("tgt %d"):format(targetY), colors.cyan)
    at(dev, 22, y, ("err %+.1f"):format(err), math.abs(err) <= 1 and colors.lime or colors.yellow)
    y = y + 1

    local vs = st.vspeed
    local vcol = colors.lightGray
    if vs and vs > 0.1 then vcol = colors.lime elseif vs and vs < -0.1 then vcol = colors.red end
    at(dev, 1, y, ("vs %s want %+.1f"):format(vs and string.format("%+.2f", vs) or "-", desiredV or 0), vcol)
    y = y + 1

    at(dev, 1, y, ("X %s  Z %s"):format(fmt(st.x), fmt(st.z)),
       gpsAt and colors.lightGray or colors.gray)
    y = y + 2

    local gw = math.max(6, w - 14)
    at(dev, 1, y, "thr", colors.cyan)
    bar(dev, 5, y, gw, u / MAX_OUT, u > 0 and colors.orange or colors.gray)
    at(dev, w - 4, y, ("%3d%%"):format(math.floor(u / MAX_OUT * 100 + 0.5)), colors.white)
    y = y + 1
    at(dev, 1, y, ("sig %d/15 gas %d  hov~%d lag~%.0f"):format(sig, tgt, math.floor((hoverEst or 0) + 0.5), leadEst), colors.lightGray)
    y = y + 1

    local cap, fillv = callm(rep.p, "getBalloonCapacity"), callm(rep.p, "getBalloonFilledVolume")
    if type(cap) == "number" and cap > 0 and type(fillv) == "number" then
      at(dev, 1, y, "bal", colors.cyan)
      bar(dev, 5, y, gw, fillv / cap, colors.lightBlue)
      at(dev, w - 4, y, ("%3d%%"):format(math.floor(fillv / cap * 100 + 0.5)), colors.white)
      y = y + 1
    end
    at(dev, 1, y, ("lift %s"):format(fmt(callm(rep.p, "getBalloonLift"))), colors.lightGray)

    local bx = 1
    local function btn(label, d, bg)
      at(dev, bx, h, label, colors.black, bg)
      if mon then buttons[#buttons + 1] = { x1 = bx, x2 = bx + #label - 1, y = h, d = d } end
      bx = bx + #label + 1
    end
    btn(" -10 ", -10, colors.red)
    btn(" -1 ", -1, colors.orange)
    btn(" +1 ", 1, colors.green)
    btn(" +10 ", 10, colors.lime)
    if not mon then at(dev, bx, h, "+/- q", colors.gray) end
  end

  print("altitude hold: source " .. (sensor and "altitude_sensor" or "gps") ..
        (gpsReady and " | GPS poller on" or "") .. (mon and " | monitor" or ""))

  local function mainLoop()
    local timer = os.startTimer(CONTROL_DT)
    while true do
      local ev = { os.pullEvent() }
      local e = ev[1]
      if e == "timer" and ev[2] == timer then
        local now = os.clock()
        local dt = (lastTick and (now - lastTick)) or CONTROL_DT
        if dt <= 0 then dt = CONTROL_DT end
        lastTick = now
        local st = readState()
        local u, sig, tgt, err, desiredV = uPrev, 0, MIN_OUT, 0, 0
        if st.y then
          local speed = st.vspeed or 0
          err = targetY - st.y
          local predY = st.y + speed * leadEst                    -- predict ahead by the learned lag
          desiredV = clamp(K_ALT * (targetY - predY), -V_DN, V_UP)
          local vErr = desiredV - speed
          local uUnsat = integ + KP_V * vErr
          if (uUnsat > 0 and uUnsat < MAX_OUT)
             or (uUnsat <= 0 and vErr > 0)
             or (uUnsat >= MAX_OUT and vErr < 0) then
            integ = clamp(integ + KI_V * vErr * dt, 0, MAX_OUT)    -- learns the balancing throttle (hover)
          end
          local lo = math.max(0, integ - math.max(DOWN_MARGIN, 0.45 * integ))  -- band scales with the
          local hi = math.min(MAX_OUT, integ + math.max(UP_MARGIN, 0.40 * integ))  -- learned hover (ship-relative)
          local uRaw = clamp(integ + KP_V * vErr, lo, hi)
          u = uPrev + clamp(dt / SMOOTH_TAU, 0, 1) * (uRaw - uPrev)
          uPrev = u
          sig, tgt = applyOutput(u)
          -- learn the response lag from the CLEAN fill telemetry (fill chasing filltgt is ~1st-order)
          local fillv, ftgv = callm(rep.p, "getBalloonFilledVolume"), callm(rep.p, "getBalloonTargetVolume")
          if type(fillv) == "number" and type(ftgv) == "number" then
            if prevFill and prevFillT and now > prevFillT then
              local dfill = (fillv - prevFill) / (now - prevFillT)
              local gap = ftgv - fillv
              if math.abs(dfill) > 2 and math.abs(gap) > 20 and (gap > 0) == (dfill > 0) then
                local tau = gap / dfill                            -- time-constant = gap / closing-rate
                if tau > 2 and tau < 15 then leadEst = leadEst + LAG_LEARN * (tau - leadEst) end
              end
            end
            prevFill, prevFillT = fillv, now
          end
          if not lastSave or (now - lastSave) > 20 then saveState(); lastSave = now end
        else
          sig, tgt = decompose(uPrev)
        end
        render(st, u, sig, tgt, err, desiredV, integ)
        logRow(st, u, sig, tgt, err, desiredV, integ, now)
        timer = os.startTimer(CONTROL_DT)
      elseif e == "key" then
        if ev[2] == keys.up then targetY = targetY + Y_STEP
        elseif ev[2] == keys.down then targetY = targetY - Y_STEP
        elseif ev[2] == keys.q then return end
      elseif e == "char" then
        if ev[2] == "+" or ev[2] == "=" then targetY = targetY + Y_STEP
        elseif ev[2] == "-" or ev[2] == "_" then targetY = targetY - Y_STEP
        elseif ev[2] == "q" then return end
      elseif e == "monitor_touch" then
        for _, b in ipairs(buttons) do
          if ev[4] == b.y and ev[3] >= b.x1 and ev[3] <= b.x2 then targetY = targetY + b.d; break end
        end
      end
    end
  end

  if gpsReady then parallel.waitForAny(mainLoop, gpsLoop) else mainLoop() end

  for _, s in ipairs(RS_SIDES) do redstone.setAnalogOutput(s, 0) end
  saveState()
  if mon then pcall(mon.setBackgroundColor, colors.black); pcall(mon.clear) end
  if logf then logf.close(); print("log written to /" .. LOG_FILE) end
  print(("altitude hold stopped - redstone cut. learned hover~%d lag~%.1fs saved to %s")
    :format(integ, leadEst, STATE_FILE))
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
