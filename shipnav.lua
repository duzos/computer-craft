-- shipnav.lua  --  Create: Avionics airship autopilot: fly to a target X / Y / Z.
-- run on a computer on the ship (touching the burners, wired to the relays, with a radio antenna).
--
-- ALTITUDE (Y): the hot air burner(s) (gas_provider), same self-tuning cascade as burnertest.lua -
--   it reads the learned {hover,lag} from burner.state so it inherits that tuning. Burner redstone is
--   driven on the computer's own BURNER_SIDES.
-- HORIZONTAL (X/Z): three redstone RELAYS (peripherals), prompted on first boot -> shipnav.cfg:
--   left / right  -- the wheel; analog 0-15 turns the ship that way
--   throttle      -- forward drive, INVERTED: 0 = full ahead, 15 = full stop
-- SENSING: position from the radio-GPS (gps2). Altitude/vspeed from an Avionics altitude_sensor if
--   present, else GPS Y. Heading from an Avionics navigation_table if present, else GPS course-over-
--   ground (only valid while moving). GPS is the full fallback; Create peripherals are used when found.
-- UI (advanced monitor, else terminal): top-down map - TAP to set the X/Z target - with the ship
--   (heading arrow), target, towers and a trail; target X/Y/Z + heading + distance readout; buttons to
--   nudge Y and STOP. Keys: arrows / +/- nudge target Y, s = stop horizontal, q = quit.
-- IN-GAME SHAKEDOWN tunables (can't be known a priori): STEER_SIGN (flip if it turns the wrong way),
--   HEADING_OFFSET (align a nav_table heading to the GPS x/z frame), and the gains below.
--   "shipnav reset" re-prompts the relays.

local comms = require("comms")
local gps2  = require("gps2")

local RADIO_FREQ   = 1000
local CFG_FILE     = "shipnav.cfg"
local STATE_FILE   = "burner.state"      -- learned {hover,lag}, shared with burnertest.lua
local LOG_FILE     = "shipnav.csv"       -- per-run telemetry log (CSV) for review; retrieve + share
local LOG_DT       = 0.2                 -- seconds between logged rows

-- altitude (Y) cascade -- mirrors burnertest.lua
local MAX_OUT, MIN_OUT = 500, 5
local HOVER0       = 250
local V_UP, V_DN   = 4.0, 2.0
local K_ALT        = 0.3
local KP_V, KI_V   = 4, 2
local DOWN_MARGIN, UP_MARGIN = 120, 120
local LEAD0        = 7.0
local SMOOTH_TAU   = 0.8
local LAG_LEARN    = 0.02
local BURNER_SIDES = { "left", "right" } -- computer faces feeding the burners' redstone

-- horizontal control
local STEER_SIGN   = 1      -- flip to -1 if the wheel turns the wrong way
local HEADING_OFFSET = 0    -- deg added to a nav_table heading to match the GPS x/z frame
local TURN_GAIN    = 0.10   -- wheel signal per deg of heading error
local TURN_DEADBAND = 8     -- deg; inside this, stop steering
local APPROACH_TAU = 4.0    -- horizontal: plan to close the remaining distance over ~this many s (higher = slows earlier)
local V_FWD_MAX    = 8.0    -- max commanded closing speed (blocks/s)
local THRUST_GAIN_V = 3.0   -- forward signal per (block/s) of closing-speed shortfall
local ARRIVE_DIST  = 3      -- blocks; within this of the X/Z target = stop
local CONTROL_DT   = 0.2
local GPS_PING_EVERY = 0.15
local GPS_AVG      = 1.2
local COURSE_MIN_MOVE = 0.6 -- blocks moved between fixes before trusting GPS course
local MON_SCALE    = 0.5

-- ---------- helpers ----------
local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end
local function callm(p, m, ...) if not p then return nil end local ok, r = pcall(p[m], ...); if ok then return r end end
local function cv(x)   -- CSV cell: numbers to 3dp, nil to empty
  if type(x) == "number" then return string.format("%.3f", x) end
  return x == nil and "" or tostring(x)
end
local function wrap180(a) a = (a + 180) % 360 - 180; if a <= -180 then a = a + 360 end; return a end
local function fmt(x)
  if type(x) == "number" then return x == math.floor(x) and tostring(x) or string.format("%.1f", x) end
  return x == nil and "-" or tostring(x)
end
local function at(dev, x, y, s, fg, bg)
  if fg then dev.setTextColor(fg) end
  if bg then dev.setBackgroundColor(bg) end
  dev.setCursorPos(x, y); dev.write(s)
  dev.setBackgroundColor(colors.black); dev.setTextColor(colors.white)
end
local function fillRow(dev, y, w, bg)
  dev.setCursorPos(1, y); dev.setBackgroundColor(bg); dev.write(string.rep(" ", w)); dev.setBackgroundColor(colors.black)
end

-- ---------- peripherals ----------
local burners = { peripheral.find("gas_provider") }
local sensor  = peripheral.find("altitude_sensor")
local navtab  = peripheral.find("navigation_table")

local function applyBurner(u)        -- u -> redstone signal + setTargetAmount on every burner
  u = clamp(u, 0, MAX_OUT)
  local step = MAX_OUT / 15
  local sig = clamp(math.ceil(u / step - 1e-9), 0, 15)
  local tgt = MIN_OUT
  if sig > 0 then tgt = clamp(math.floor(u * 15 / sig + 0.5), MIN_OUT, MAX_OUT) end
  for _, s in ipairs(BURNER_SIDES) do redstone.setAnalogOutput(s, sig) end
  for _, b in ipairs(burners) do pcall(b.setTargetAmount, tgt) end
  return sig, tgt
end

-- ---------- relays (wheel + throttle) ----------
local relays
local function promptRelays()
  print("Name each relay by its NETWORK name exactly as listed (e.g. redstone_relay_1, no mod prefix),")
  print("and the RELAY's own output face (the side wired/touching the wheel or throttle). Peripherals seen:")
  for _, n in ipairs(peripheral.getNames()) do print("  " .. n .. "  (" .. (peripheral.getType(n) or "?") .. ")") end
  local function ask(label)
    write(label .. " relay name (e.g. redstone_relay_1): "); local name = (read() or ""):gsub("%s+", "")
    write(label .. " relay output side (front/back/left/right/top/bottom): "); local side = (read() or ""):gsub("%s+", "")
    return { name = name ~= "" and name or nil, side = side ~= "" and side or "back" }
  end
  return { left = ask("LEFT (turn)"), right = ask("RIGHT (turn)"), throttle = ask("THROTTLE (fwd)") }
end
local function loadRelays()
  if fs.exists(CFG_FILE) then
    local fh = fs.open(CFG_FILE, "r")
    if fh then local ok, d = pcall(textutils.unserialise, fh.readAll()); fh.close(); if ok and type(d) == "table" then return d end end
  end
  local r = promptRelays()
  local fh = fs.open(CFG_FILE, "w"); if fh then fh.write(textutils.serialise(r)); fh.close() end
  return r
end
local function setRelay(r, value)
  if r and r.name then pcall(peripheral.call, r.name, "setAnalogOutput", r.side, math.floor(clamp(value, 0, 15) + 0.5)) end
end
local function stopHorizontal()
  setRelay(relays.left, 0); setRelay(relays.right, 0); setRelay(relays.throttle, 15)  -- 15 = full stop
end

-- ---------- GPS poller (position + course-over-ground) ----------
local gx, gy, gz, gVspeed, gpsAt, gCourse, gVx, gVz = nil, nil, nil, nil, nil, nil, nil, nil
local gpsTowers = nil   -- last-seen towers, for the map
local function gpsLoop()
  local towers, yhist, lastPing = {}, {}, -1e9
  local cX, cZ, cT = nil, nil, nil
  while true do
    local now = os.clock()
    if now - lastPing >= GPS_PING_EVERY then comms.send("all", { type = "gpsq" }, "gps"); lastPing = now end
    local m = comms.receive("gps", GPS_PING_EVERY)
    now = os.clock()
    if m and m.dist and type(m.body) == "table" and m.body.type == "gpsr" and type(m.body.pos) == "table" then
      local t = towers[m.from]; if not t then t = {}; towers[m.from] = t end
      t.pos, t.d, t.t = m.body.pos, m.dist, now
    end
    local pts = {}
    for _, t in pairs(towers) do
      if t.t and (now - t.t) <= GPS_AVG then pts[#pts + 1] = { x = t.pos.x, y = t.pos.y, z = t.pos.z, d = t.d } end
    end
    gpsTowers = towers
    if #pts >= 4 then
      local fix = gps2.trilaterate(pts)
      if fix then
        gx, gy, gz, gpsAt = fix.x, fix.y, fix.z, now
        yhist[#yhist + 1] = { t = now, x = fix.x, y = fix.y, z = fix.z }
        while #yhist > 1 and now - yhist[1].t > GPS_AVG do table.remove(yhist, 1) end
        if #yhist >= 2 and now > yhist[1].t then
          local h0, dtv = yhist[1], now - yhist[1].t
          gVspeed = (fix.y - h0.y) / dtv
          gVx, gVz = (fix.x - h0.x) / dtv, (fix.z - h0.z) / dtv
        end
        if cX then
          local dx, dz = fix.x - cX, fix.z - cZ
          if math.sqrt(dx * dx + dz * dz) >= COURSE_MIN_MOVE then
            gCourse = math.deg(math.atan2(dz, dx))   -- 0=+X, 90=+Z; matches bearing below
            cX, cZ, cT = fix.x, fix.z, now
          end
        else
          cX, cZ, cT = fix.x, fix.z, now
        end
      end
    end
  end
end

local function readState()
  local x, y, z, vs, ysrc = gx, nil, gz, nil, nil
  if sensor then
    local oh = callm(sensor, "getHeight"); if type(oh) == "number" then y = oh end
    local ov = callm(sensor, "getVerticalSpeed"); if type(ov) == "number" then vs = ov end
    ysrc = "alt"
  elseif gy then
    local age = gpsAt and (os.clock() - gpsAt) or 0
    y, vs, ysrc = gy + (gVspeed or 0) * age, gVspeed or 0, "gps"
  end
  local heading, hsrc = nil, nil
  if navtab then
    local nh = callm(navtab, "getHeading"); if type(nh) == "number" then heading, hsrc = wrap180(nh + HEADING_OFFSET), "nav" end
  end
  if heading == nil and gCourse then heading, hsrc = wrap180(gCourse), "course" end
  return { x = x, y = y, z = z, vspeed = vs, ysrc = ysrc, heading = heading, hsrc = hsrc }
end

-- ---------- altitude cascade (mirrors burnertest) ----------
local alt = { integ = HOVER0, uPrev = 0, leadEst = LEAD0, prevFill = nil, prevFillT = nil }
local function loadState()
  if fs.exists(STATE_FILE) then
    local fh = fs.open(STATE_FILE, "r")
    if fh then
      local ok, d = pcall(textutils.unserialise, fh.readAll()); fh.close()
      if ok and type(d) == "table" then
        if type(d.hover) == "number" then alt.integ = clamp(d.hover, MIN_OUT, MAX_OUT) end
        if type(d.lag) == "number" then alt.leadEst = clamp(d.lag, 2, 15) end
      end
    end
  end
end
local function saveState()
  local fh = fs.open(STATE_FILE, "w"); if fh then fh.write(textutils.serialise({ hover = alt.integ, lag = alt.leadEst })); fh.close() end
end
local function altStep(targetY, st, dt, now)
  if not st.y or #burners == 0 then local s, t = applyBurner(alt.uPrev); return alt.uPrev, s, t, 0, 0 end
  local speed = st.vspeed or 0
  local err = targetY - st.y
  local desiredV = clamp(K_ALT * (targetY - (st.y + speed * alt.leadEst)), -V_DN, V_UP)
  local vErr = desiredV - speed
  local uUnsat = alt.integ + KP_V * vErr
  if (uUnsat > 0 and uUnsat < MAX_OUT) or (uUnsat <= 0 and vErr > 0) or (uUnsat >= MAX_OUT and vErr < 0) then
    alt.integ = clamp(alt.integ + KI_V * vErr * dt, 0, MAX_OUT)
  end
  local lo = math.max(0, alt.integ - math.max(DOWN_MARGIN, 0.45 * alt.integ))
  local hi = math.min(MAX_OUT, alt.integ + math.max(UP_MARGIN, 0.40 * alt.integ))
  local u = alt.uPrev + clamp(dt / SMOOTH_TAU, 0, 1) * (clamp(alt.integ + KP_V * vErr, lo, hi) - alt.uPrev)
  alt.uPrev = u
  local sig, tgt = applyBurner(u)
  local fillv, ftgv = callm(burners[1], "getBalloonFilledVolume"), callm(burners[1], "getBalloonTargetVolume")
  if type(fillv) == "number" and type(ftgv) == "number" then
    if alt.prevFill and alt.prevFillT and now > alt.prevFillT then
      local dfill = (fillv - alt.prevFill) / (now - alt.prevFillT)
      local gap = ftgv - fillv
      if math.abs(dfill) > 2 and math.abs(gap) > 20 and (gap > 0) == (dfill > 0) then
        local tau = gap / dfill
        if tau > 2 and tau < 15 then alt.leadEst = alt.leadEst + LAG_LEARN * (tau - alt.leadEst) end
      end
    end
    alt.prevFill, alt.prevFillT = fillv, now
  end
  return u, sig, tgt, err, desiredV
end

-- ---------- horizontal control ----------
-- returns turnSignal (signed, + = STEER_SIGN's "right"), thrust(0-15 fwd), distHoriz, headingErr
local function horizStep(target, st)
  if not target.x or not target.z or not st.x or not st.z then
    setRelay(relays.left, 0); setRelay(relays.right, 0); setRelay(relays.throttle, 15)
    return 0, 0, nil, nil
  end
  local dx, dz = target.x - st.x, target.z - st.z
  local dist = math.sqrt(dx * dx + dz * dz)
  if dist <= ARRIVE_DIST then
    setRelay(relays.left, 0); setRelay(relays.right, 0); setRelay(relays.throttle, 15)
    return 0, 0, dist, 0
  end
  local bearing = math.deg(math.atan2(dz, dx))
  local hErr = st.heading and wrap180(bearing - st.heading) or 0
  local turn = clamp(TURN_GAIN * hErr, -15, 15) * STEER_SIGN
  if not st.heading or math.abs(hErr) < TURN_DEADBAND then turn = 0 end
  if turn > 0 then setRelay(relays.right, turn); setRelay(relays.left, 0)
  elseif turn < 0 then setRelay(relays.left, -turn); setRelay(relays.right, 0)
  else setRelay(relays.left, 0); setRelay(relays.right, 0) end
  -- forward only when roughly aligned; ease near arrival; scale by alignment
  -- closing speed toward the target (blocks/s) from GPS velocity
  local ux, uz = dx / dist, dz / dist
  local vClose = (gVx or 0) * ux + (gVz or 0) * uz
  -- decelerate as it approaches: cap the WANTED closing speed by distance so it coasts to a stop,
  -- and only push when below it (throttle is forward-only, so braking = stop pushing + let drag bleed it)
  local vWant = clamp(dist / APPROACH_TAU, 0, V_FWD_MAX)
  local align = st.heading and math.max(0, math.cos(math.rad(hErr))) or 0
  local thrust = clamp(THRUST_GAIN_V * (vWant - vClose), 0, 15) * align
  if math.abs(hErr) > 60 then thrust = 0 end
  setRelay(relays.throttle, 15 - thrust)        -- inverted: 15 = stop
  return turn, thrust, dist, hErr, vClose
end

-- ---------- map + dashboard ----------
local mapProj = nil   -- {ix1,iy1,ix2,iy2,minX,minZ,offX,offY,scale} for click inversion
local buttons = {}
local trail = {}
local function arrowFor(h)
  if not h then return "@" end
  local oct = math.floor(((h + 360) % 360) / 45 + 0.5) % 8
  return ({ [0] = ">", [1] = "\\", [2] = "v", [3] = "/", [4] = "<", [5] = "\\", [6] = "^", [7] = "/" })[oct]
end

local function render(mon, st, target, u, dist, hErr, thrust)
  local dev = mon or term
  local w, h = dev.getSize()
  dev.setBackgroundColor(colors.black); dev.setTextColor(colors.white); dev.clear()
  buttons = {}

  local status, scol = "IDLE", colors.lightGray
  if target.x then
    if dist and dist <= ARRIVE_DIST then status, scol = "ARRIVED", colors.lime
    else status, scol = "GOTO", colors.yellow end
  end
  fillRow(dev, 1, w, colors.blue)
  at(dev, 1, 1, "SHIP NAV", colors.white, colors.blue)
  at(dev, math.max(12, w - #status), 1, status, scol, colors.blue)

  at(dev, 1, 2, ("tgt %s,%s,%s"):format(fmt(target.x), fmt(target.y), fmt(target.z)), colors.cyan)
  local hd = st.heading and ("%d"):format((math.floor(st.heading + 360.5)) % 360) or "-"
  at(dev, 1, 3, ("pos %s,%s,%s"):format(fmt(st.x), fmt(st.y), fmt(st.z)), colors.lightGray)
  at(dev, 1, 4, ("hdg %s%s  dist %s  thr %d"):format(hd, st.hsrc and (" " .. st.hsrc) or "",
     dist and ("%.0f"):format(dist) or "-", math.floor((thrust or 0) + 0.5)), colors.lightGray)

  -- map box
  local by1, by2 = 6, h - 1
  if by2 - by1 >= 3 then
    local minX, maxX, minZ, maxZ
    local function inc(x, z)
      if not x then return end
      if not minX then minX, maxX, minZ, maxZ = x, x, z, z
      else minX, maxX, minZ, maxZ = math.min(minX, x), math.max(maxX, x), math.min(minZ, z), math.max(maxZ, z) end
    end
    inc(st.x, st.z)
    if target.x then inc(target.x, target.z) end
    if gpsTowers then for _, t in pairs(gpsTowers) do if t.pos then inc(t.pos.x, t.pos.z) end end end
    for _, p in ipairs(trail) do inc(p.x, p.z) end
    if not minX then minX, maxX, minZ, maxZ = 0, 1, 0, 1 end
    local spanX, spanZ = math.max(maxX - minX, 8), math.max(maxZ - minZ, 8)
    local ix1, iy1, ix2, iy2 = 2, by1 + 1, w - 1, by2 - 1
    for x = 1, w do at(dev, x, by1, "-", colors.gray); at(dev, x, by2, "-", colors.gray) end
    local mapW, mapH = ix2 - ix1 + 1, iy2 - iy1 + 1
    local scale = math.min((mapW - 1) / spanX, (mapH - 1) / spanZ); if scale <= 0 then scale = 0.01 end
    local offX = ix1 + math.floor((mapW - spanX * scale) / 2)
    local offY = iy1 + math.floor((mapH - spanZ * scale) / 2)
    local function toCol(x) return offX + math.floor((x - minX) * scale + 0.5) end
    local function toRow(z) return offY + math.floor((z - minZ) * scale + 0.5) end
    mapProj = { ix1 = ix1, iy1 = iy1, ix2 = ix2, iy2 = iy2, minX = minX, minZ = minZ, offX = offX, offY = offY, scale = scale }
    for _, p in ipairs(trail) do local c, r = toCol(p.x), toRow(p.z); if c >= ix1 and c <= ix2 and r >= iy1 and r <= iy2 then at(dev, c, r, ".", colors.gray) end end
    if gpsTowers then for id, t in pairs(gpsTowers) do if t.pos then local c, r = toCol(t.pos.x), toRow(t.pos.z); if c >= ix1 and c <= ix2 and r >= iy1 and r <= iy2 then at(dev, c, r, "+", colors.blue) end end end end
    if target.x then local c, r = toCol(target.x), toRow(target.z); if c >= ix1 and c <= ix2 and r >= iy1 and r <= iy2 then at(dev, c, r, "X", colors.red) end end
    if st.x then local c, r = toCol(st.x), toRow(st.z); if c >= ix1 and c <= ix2 and r >= iy1 and r <= iy2 then at(dev, c, r, arrowFor(st.heading), colors.lime) end end
  else
    mapProj = nil
  end

  -- bottom buttons: Y nudge + STOP  (tap map = set X/Z)
  local bx = 1
  local function btn(label, fn, bg)
    at(dev, bx, h, label, colors.black, bg)
    if mon then buttons[#buttons + 1] = { x1 = bx, x2 = bx + #label - 1, y = h, fn = fn } end
    bx = bx + #label + 1
  end
  btn("Y-", function() target.y = (target.y or 0) - 5 end, colors.orange)
  btn("Y+", function() target.y = (target.y or 0) + 5 end, colors.green)
  btn("STOP", function() target.x, target.z = nil, nil end, colors.red)
  at(dev, bx, h, mon and "tap map=goto" or "s=stop q=quit", colors.gray)
end

-- ---------- main ----------
print("shipnav: " .. #burners .. " burner(s)" ..
      (sensor and " +altimeter" or "") .. (navtab and " +navtable" or "") .. " | GPS")
if (...) == "reset" then fs.delete(CFG_FILE); print("relay config cleared") end
loadState()
relays = loadRelays()
comms.open({ freq = RADIO_FREQ })
local mon = peripheral.find("monitor")
if mon then pcall(mon.setTextScale, MON_SCALE) end

-- default target Y = current altitude (one synchronous fix if needed)
local st0 = readState()
if not st0.y then local fix = gps2.locate(2, 6); if fix then gx, gy, gz = fix.x, fix.y, fix.z; st0 = readState() end end
local target = { x = nil, y = st0.y and math.floor(st0.y + 0.5) or 64, z = nil }

local logf = fs.open(LOG_FILE, "w")
if logf then logf.writeLine("t,ysrc,hsrc,x,y,z,tx,ty,tz,heading,herr,dist,turn,thrust,vclose,u,hover,lag,vspeed,lift,fill,filltgt") end
local lastLog = nil
local function logRow(st, u, turn, thrust, vClose, dist, hErr, now)
  if not logf then return end
  if lastLog and (now - lastLog) < LOG_DT then return end
  lastLog = now
  local b1 = burners[1]
  logf.writeLine(table.concat({
    cv(now), st.ysrc or "", st.hsrc or "", cv(st.x), cv(st.y), cv(st.z),
    cv(target.x), cv(target.y), cv(target.z), cv(st.heading), cv(hErr), cv(dist),
    cv(turn), cv(thrust), cv(vClose), cv(u), cv(alt.integ), cv(alt.leadEst), cv(st.vspeed),
    cv(callm(b1, "getBalloonLift")), cv(callm(b1, "getBalloonFilledVolume")), cv(callm(b1, "getBalloonTargetVolume")),
  }, ","))
  logf.flush()
end

local lastTick, lastSave, lastTrail = nil, nil, nil
local function controlLoop()
  local timer = os.startTimer(CONTROL_DT)
  while true do
    local ev = { os.pullEvent() }
    local e = ev[1]
    if e == "timer" and ev[2] == timer then
      local now = os.clock()
      local dt = (lastTick and (now - lastTick)) or CONTROL_DT; if dt <= 0 then dt = CONTROL_DT end
      lastTick = now
      local st = readState()
      local u = altStep(target.y, st, dt, now)
      local turn, thrust, dist, hErr, vClose = horizStep(target, st)
      if st.x and (not lastTrail or now - lastTrail > 1) then
        trail[#trail + 1] = { x = st.x, z = st.z }; while #trail > 60 do table.remove(trail, 1) end; lastTrail = now
      end
      render(mon, st, target, u, dist, hErr, thrust)
      logRow(st, u, turn, thrust, vClose, dist, hErr, now)
      if not lastSave or now - lastSave > 20 then saveState(); lastSave = now end
      timer = os.startTimer(CONTROL_DT)
    elseif e == "key" then
      if ev[2] == keys.up then target.y = target.y + 1
      elseif ev[2] == keys.down then target.y = target.y - 1
      elseif ev[2] == keys.q then break end
    elseif e == "char" then
      if ev[2] == "+" or ev[2] == "=" then target.y = target.y + 1
      elseif ev[2] == "-" then target.y = target.y - 1
      elseif ev[2] == "s" then target.x, target.z = nil, nil
      elseif ev[2] == "q" then break end
    elseif e == "monitor_touch" then
      local tx, ty = ev[3], ev[4]
      local hit = false
      for _, b in ipairs(buttons) do
        if ty == b.y and tx >= b.x1 and tx <= b.x2 then b.fn(); hit = true; break end
      end
      if not hit and mapProj and tx >= mapProj.ix1 and tx <= mapProj.ix2 and ty >= mapProj.iy1 and ty <= mapProj.iy2 then
        target.x = mapProj.minX + (tx - mapProj.offX) / mapProj.scale
        target.z = mapProj.minZ + (ty - mapProj.offY) / mapProj.scale
      end
    end
  end
end

parallel.waitForAny(controlLoop, gpsLoop)

stopHorizontal()
for _, s in ipairs(BURNER_SIDES) do redstone.setAnalogOutput(s, 0) end
saveState()
if logf then logf.close() end
if mon then pcall(mon.setBackgroundColor, colors.black); pcall(mon.clear) end
print("shipnav stopped - relays + burner redstone cut. log -> /" .. LOG_FILE)
