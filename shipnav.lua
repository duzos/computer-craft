-- shipnav.lua  --  Create: Avionics airship autopilot: fly to a target X / Y / Z.
-- run on a computer on the ship (touching the burners, wired to the relays, with a radio antenna).
--
-- ALTITUDE (Y): the hot air burner(s) (gas_provider), same self-tuning cascade as burnertest.lua -
--   it reads the learned {hover,lag} from burner.state so it inherits that tuning. Burner redstone is
--   driven on the computer's own BURNER_SIDES.
-- HORIZONTAL (X/Z): three redstone RELAYS (peripherals), prompted on first boot -> shipnav.cfg:
--   left / right  -- the wheel; analog 0-15 turns the ship that way
--   throttle      -- forward drive, INVERTED: 0 = full ahead, 15 = full stop
--   Thrust/braking are SELF-TUNING: it learns this ship's speed-per-thrust and the deceleration at
--   full-stop throttle (relay 15) live, braking early enough to arrive without overshoot; persisted to
--   shipnav.state (no hardcoded constants).
-- SENSING: position from the radio-GPS (gps2). Altitude/vspeed from an Avionics altitude_sensor if
--   present, else GPS Y. Heading: navigation_table (absolute) if present; else a gimbal_sensor's yaw
--   rate integrated and re-anchored to GPS course (valid even while slow/turning); else raw GPS course.
--   Yaw rate damps the steering - from the gimbal if present, else derived from the heading's own change.
--   None of the Create peripherals are required: it runs fully on GPS alone, they just sharpen it.
-- UI (advanced monitor, else terminal): top-down map - TAP to set the X/Z target - with the ship
--   (heading arrow), target, towers and a trail; target X/Y/Z + heading + distance readout; buttons to
--   nudge Y and STOP. Keys: arrows / +/- nudge target Y, s = stop horizontal, q = quit.
-- IN-GAME SHAKEDOWN tunables (can't be known a priori): STEER_SIGN (flip if it turns the wrong way),
--   HEADING_OFFSET (align a nav_table heading to the GPS x/z frame), and the gains below.
--   "shipnav reset" re-prompts the relays.

local comms  = require("comms")
local gps2   = require("gps2")
local map    = require("map")
local beacon = require("beacon")

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
local GYRO_SIGN    = 1      -- gimbal yaw-rate polarity (flip if the fused heading spins the wrong way)
local HDG_CORRECT  = 0.05   -- how strongly GPS course re-anchors the gimbal-integrated heading (0..1)
local TURN_GAIN    = 0.10   -- wheel signal per deg of heading error (proven gentle value)
local TURN_DAMP    = 0.30   -- steering yaw-rate damping (signal per deg/s); reduces turn overshoot
local TURN_DEADBAND = 8     -- deg; inside this, stop steering
local NAV_STATE    = "shipnav.state"  -- learned horizontal dynamics {thrustK, brakeA}, per ship
local ARRIVE_DIST  = 3      -- blocks; goal tolerance (a stop radius, not a dynamics constant)
local GPS_LOST_TIMEOUT = 3  -- s without a GPS fix -> failsafe: stop horizontal, hand control to the pilot
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
local gimbal  = peripheral.find("gimbal_sensor")

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
-- release the horizontal relays (ALL to 0) so the pilot's manual controls take over; the computer only
-- drives them while actively navigating (where throttle 15 = brake). 0 = silent line, not a stop command.
local function releaseHorizontal()
  setRelay(relays.left, 0); setRelay(relays.right, 0); setRelay(relays.throttle, 0)
end

-- ---------- GPS poller (position + course-over-ground) ----------
local gx, gy, gz, gVspeed, gpsAt, gCourse, gVx, gVz = nil, nil, nil, nil, nil, nil, nil, nil
local gpsTowers = nil   -- last-seen towers, for the map
local fusedHdg, fusedHdgT = nil, nil   -- gimbal yaw-rate integrated heading, re-anchored to GPS course
local prevHdg, prevHdgT, yawDeriv = nil, nil, nil   -- for deriving yaw rate when there is no gimbal
local function gpsLoop()
  local towers, yhist, lastPing = {}, {}, -1e9
  local cX, cZ, cT = nil, nil, nil
  while true do
    local now = os.clock()
    if now - lastPing >= GPS_PING_EVERY then comms.send("all", { type = "gpsq" }, "gps"); lastPing = now end
    local m = comms.receive("gps", GPS_PING_EVERY)
    now = os.clock()
    if m and type(m.body) == "table" then
      if m.dist and m.body.type == "gpsr" and type(m.body.pos) == "table" then
        local t = towers[m.from]; if not t then t = {}; towers[m.from] = t end
        t.pos, t.d, t.t = m.body.pos, m.dist, now
      elseif m.body.type == "loc" then
        locTracker.offer(m.from, m.body, m.dist, now)   -- another device's presence beacon
      end
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
  local now = os.clock()
  local heading, hsrc, yawRate = nil, nil, nil
  if gimbal then
    local rates = callm(gimbal, "getAngularRates")
    if type(rates) == "table" and type(rates.wy) == "number" then yawRate = GYRO_SIGN * rates.wy end
  end
  if navtab then
    local nh = callm(navtab, "getHeading"); if type(nh) == "number" then heading, hsrc = wrap180(nh + HEADING_OFFSET), "nav" end
  end
  if heading == nil and yawRate then
    -- integrate the gimbal yaw rate; re-anchor to GPS course when moving fast enough to trust it
    if fusedHdg == nil then fusedHdg = gCourse end
    if fusedHdg ~= nil then
      if fusedHdgT and now > fusedHdgT then fusedHdg = wrap180(fusedHdg + yawRate * (now - fusedHdgT)) end
      local vh = math.sqrt((gVx or 0) * (gVx or 0) + (gVz or 0) * (gVz or 0))
      if gCourse and vh > 1.0 then fusedHdg = wrap180(fusedHdg + HDG_CORRECT * wrap180(gCourse - fusedHdg)) end
      heading, hsrc = fusedHdg, "gyro"
    end
    fusedHdgT = now
  end
  if heading == nil and gCourse then heading, hsrc = wrap180(gCourse), "course" end
  return { x = x, y = y, z = z, vspeed = vs, ysrc = ysrc, heading = heading, hsrc = hsrc, yawRate = yawRate }
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

-- horizontal dynamics, LEARNED per ship (seeds are first-boot fallbacks only, then overwritten + persisted)
local nav = { thrustK = 0.5, brakeA = 1.0 }   -- thrustK = steady speed per thrust; brakeA = decel at full-stop throttle (blocks/s^2)
local prevVh, prevVhT = nil, nil
local function loadNav()
  if fs.exists(NAV_STATE) then
    local fh = fs.open(NAV_STATE, "r")
    if fh then
      local ok, d = pcall(textutils.unserialise, fh.readAll()); fh.close()
      if ok and type(d) == "table" then
        if type(d.thrustK) == "number" then nav.thrustK = clamp(d.thrustK, 0.01, 5) end
        if type(d.brakeA) == "number" then nav.brakeA = clamp(d.brakeA, 0.02, 50) end
      end
    end
  end
end
local function saveNav()
  local fh = fs.open(NAV_STATE, "w"); if fh then fh.write(textutils.serialise(nav)); fh.close() end
end
-- learn from GPS speed: coast phases (thrust~0, slowing) give the drag time-const; steady cruise gives speed/thrust
local function learnHoriz(thrust, now)
  local vh = math.sqrt((gVx or 0) * (gVx or 0) + (gVz or 0) * (gVz or 0))
  if prevVh and prevVhT and now > prevVhT then
    local a = (vh - prevVh) / (now - prevVhT)
    if thrust < 1 and vh > 0.6 and a < -0.02 then      -- full-stop throttle (relay 15): learn its deceleration
      local decel = -a
      if decel > 0.02 and decel < 50 then nav.brakeA = nav.brakeA + 0.05 * (decel - nav.brakeA) end
    elseif thrust > 3 and vh > 0.6 and math.abs(a) < 0.08 then
      local k = vh / thrust
      if k > 0.01 and k < 5 then nav.thrustK = nav.thrustK + 0.05 * (k - nav.thrustK) end
    end
  end
  prevVh, prevVhT = vh, now
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
    releaseHorizontal()                                 -- not navigating: hand the horizontal relays to the pilot
    return 0, 0, nil, nil
  end
  local dx, dz = target.x - st.x, target.z - st.z
  local dist = math.sqrt(dx * dx + dz * dz)
  if dist <= ARRIVE_DIST then
    target.x, target.z = nil, nil                       -- arrived: drop the goto (no hunting) + release to pilot
    releaseHorizontal()
    return 0, 0, dist, 0
  end
  local bearing = math.deg(math.atan2(dz, dx))
  local hErr = st.heading and wrap180(bearing - st.heading) or 0
  -- gimbal is OPTIONAL and strictly additive: it only ADDS yaw-rate damping; the P gain is unchanged
  local turn = clamp(TURN_GAIN * hErr - TURN_DAMP * (st.yawRate or 0), -15, 15) * STEER_SIGN
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
  -- LEARNED dynamics: top speed = 15*thrustK; at full-stop throttle it decelerates at brakeA, so the
  -- fastest speed it can still brake to a stop within dist is sqrt(2*brakeA*dist). No hardcoded constants.
  local vMax = 15 * nav.thrustK
  local vSafe = math.sqrt(2 * math.max(nav.brakeA, 0.02) * math.max(dist - ARRIVE_DIST, 0))
  local vWant = math.min(vMax, vSafe)
  local align = st.heading and math.max(0, math.cos(math.rad(hErr))) or 0
  -- push toward vWant; at/above it thrust -> 0, i.e. throttle relay 15 (full stop / brake)
  local thrust = clamp((vWant - vClose) / math.max(nav.thrustK, 0.01), 0, 15) * align
  if math.abs(hErr) > 60 then thrust = 0 end
  setRelay(relays.throttle, 15 - thrust)        -- inverted: 15 = stop
  return turn, thrust, dist, hErr, vClose
end

-- ---------- map + dashboard ----------
local mapProj = nil   -- last map.draw projection, for tap->world (set target / recentre)
local buttons = {}
local trail = {}
local vp = map.viewport({ auto = true })   -- map viewport: auto-fit until you zoom/follow
local locTracker = beacon.tracker()        -- other devices heard via loc beacons (e.g. the pad)
local sendLoc = beacon.sender("ship#" .. os.getComputerID(), "ship")   -- make the ship visible on maps
-- F: lock the view on the ship; toggling it off returns to fit-everything
local function followToggle()
  if vp.follow then vp.follow = false; map.fit(vp) else map.setFollow(vp, true) end
end
local function arrowFor(h)
  if not h then return "@" end
  local oct = math.floor(((h + 360) % 360) / 45 + 0.5) % 8
  return ({ [0] = ">", [1] = "\\", [2] = "v", [3] = "/", [4] = "<", [5] = "\\", [6] = "^", [7] = "/" })[oct]
end

local function render(mon, st, target, u, dist, hErr, thrust, lost)
  local dev = mon or term
  local w, h = dev.getSize()
  dev.setBackgroundColor(colors.black); dev.setTextColor(colors.white); dev.clear()
  buttons = {}

  local status, scol = "IDLE", colors.lightGray
  if lost then status, scol = "GPS LOST", colors.red
  elseif target.x then
    if dist and dist <= ARRIVE_DIST then status, scol = "ARRIVED", colors.lime
    else status, scol = "GOTO", colors.yellow end
  end
  fillRow(dev, 1, w, colors.blue)
  at(dev, 1, 1, "SHIP NAV", colors.white, colors.blue)
  at(dev, math.max(12, w - #status), 1, status, scol, colors.blue)

  local hd = st.heading and ("%d"):format((math.floor(st.heading + 360.5)) % 360) or "-"
  if lost then
    at(dev, 1, 2, "GPS LOST - PILOT HAS CONTROL", colors.red)
    at(dev, 1, 3, sensor and "altitude HELD (sensor)" or "NO ALT SENSOR - float @hover",
       sensor and colors.lime or colors.orange)
  else
    at(dev, 1, 2, ("tgt %s,%s,%s"):format(fmt(target.x), fmt(target.y), fmt(target.z)), colors.cyan)
    at(dev, 1, 3, ("pos %s,%s,%s"):format(fmt(st.x), fmt(st.y), fmt(st.z)), colors.lightGray)
  end
  at(dev, 1, 4, ("hdg %s%s  dist %s  thr %d"):format(hd, st.hsrc and (" " .. st.hsrc) or "",
     dist and ("%.0f"):format(dist) or "-", math.floor((thrust or 0) + 0.5)), colors.lightGray)

  -- map box, rendered by the shared map.lua module: build the marker list (towers,
  -- other devices' loc beacons, the target, and the ship itself) plus the trail dots,
  -- then hand them to map.draw with the current viewport. Tap-to-set-target inverts the
  -- returned projection in the monitor_touch handler.
  local by1, by2 = 6, h - 1
  if by2 - by1 >= 3 then
    local markers = {}
    if gpsTowers then
      for id, t in pairs(gpsTowers) do
        if t.pos then markers[#markers + 1] = map.marker(t.pos.x, t.pos.z, "#" .. id, "tower", { char = "+", colour = colors.blue }) end
      end
    end
    local now = os.clock()
    for _, r in ipairs(locTracker.list(now)) do
      if r.id ~= os.getComputerID() then markers[#markers + 1] = map.marker(r.pos.x, r.pos.z, r.label, r.kind) end
    end
    if target.x then markers[#markers + 1] = map.marker(target.x, target.z, "tgt", "target", { char = "X" }) end
    if st.x then markers[#markers + 1] = map.marker(st.x, st.z, "ship", "ship", { char = arrowFor(st.heading), colour = colors.lime, follow = true }) end
    mapProj = map.draw(dev, markers, vp, {
      box = { x1 = 1, y1 = by1, x2 = w, y2 = by2 }, border = true, dots = trail,
    })
  else
    mapProj = nil
  end

  -- bottom buttons: Y nudge + STOP, zoom, follow  (tap map = set X/Z)
  local bx = 1
  local function btn(label, fn, bg)
    at(dev, bx, h, label, colors.black, bg)
    if mon then buttons[#buttons + 1] = { x1 = bx, x2 = bx + #label - 1, y = h, fn = fn } end
    bx = bx + #label + 1
  end
  btn("Y-", function() target.y = (target.y or 0) - 5 end, colors.orange)
  btn("Y+", function() target.y = (target.y or 0) + 5 end, colors.green)
  btn("STOP", function() target.x, target.z = nil, nil end, colors.red)
  btn("-", function() map.zoom(vp, 1 / 1.5) end, colors.gray)
  btn("+", function() map.zoom(vp, 1.5) end, colors.gray)
  btn("F", followToggle, vp.follow and colors.lime or colors.gray)
  at(dev, bx, h, mon and "tap=goto" or "s=stop i/o=zm f q", colors.gray)
end

-- ---------- main ----------
print("shipnav: " .. #burners .. " burner(s)" ..
      (sensor and " +altimeter" or "") .. (navtab and " +navtable" or "") .. (gimbal and " +gimbal" or "") .. " | GPS")
if (...) == "reset" then fs.delete(CFG_FILE); print("relay config cleared") end
loadState()
loadNav()
relays = loadRelays()
comms.open({ freq = RADIO_FREQ })
local mon = peripheral.find("monitor")
if mon then pcall(mon.setTextScale, MON_SCALE) end

-- default target Y = current altitude (one synchronous fix if needed)
local st0 = readState()
if not st0.y then local fix = gps2.locate(2, 6); if fix then gx, gy, gz = fix.x, fix.y, fix.z; st0 = readState() end end
local target = { x = nil, y = st0.y and math.floor(st0.y + 0.5) or 64, z = nil }

local logf = fs.open(LOG_FILE, "w")
if logf then logf.writeLine("t,ysrc,hsrc,x,y,z,tx,ty,tz,heading,yaw,herr,dist,turn,thrust,vclose,thrustK,brakeA,u,hover,lag,vspeed,lift,fill,filltgt") end
local lastLog = nil
local function logRow(st, u, turn, thrust, vClose, dist, hErr, now)
  if not logf then return end
  if lastLog and (now - lastLog) < LOG_DT then return end
  lastLog = now
  local b1 = burners[1]
  logf.writeLine(table.concat({
    cv(now), st.ysrc or "", st.hsrc or "", cv(st.x), cv(st.y), cv(st.z),
    cv(target.x), cv(target.y), cv(target.z), cv(st.heading), cv(st.yawRate), cv(hErr), cv(dist),
    cv(turn), cv(thrust), cv(vClose), cv(nav.thrustK), cv(nav.brakeA), cv(u), cv(alt.integ), cv(alt.leadEst), cv(st.vspeed),
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
      local gpsLost = (not st.x) or (not gpsAt) or (now - gpsAt) > GPS_LOST_TIMEOUT
      local u, turn, thrust, dist, hErr, vClose = alt.uPrev, 0, 0, nil, nil, nil
      if gpsLost then
        -- FAILSAFE: GPS gone -> release horizontal to the pilot (ALL relays 0, incl throttle); keep altitude if possible
        releaseHorizontal()
        target.x, target.z = nil, nil             -- drop the goto so it can't lurch when GPS returns
        if sensor and st.y then u = altStep(target.y, st, dt, now)   -- altitude hold continues (sensor Y)
        else applyBurner(alt.integ); u = alt.integ end               -- no Y source -> float at learned hover
      else
        u = altStep(target.y, st, dt, now)
        turn, thrust, dist, hErr, vClose = horizStep(target, st)
        learnHoriz(thrust, now)
      end
      if st.x and (not lastTrail or now - lastTrail > 1) then
        trail[#trail + 1] = { x = st.x, z = st.z }; while #trail > 60 do table.remove(trail, 1) end; lastTrail = now
      end
      if st.x then sendLoc(now, { x = st.x, y = st.y, z = st.z }) end   -- presence beacon so the ship shows on other maps
      render(mon, st, target, u, dist, hErr, thrust, gpsLost)
      logRow(st, u, turn, thrust, vClose, dist, hErr, now)
      if not lastSave or now - lastSave > 20 then saveState(); saveNav(); lastSave = now end
      timer = os.startTimer(CONTROL_DT)
    elseif e == "key" then
      if ev[2] == keys.up then target.y = target.y + 1
      elseif ev[2] == keys.down then target.y = target.y - 1
      elseif ev[2] == keys.q then break end
    elseif e == "char" then
      if ev[2] == "+" or ev[2] == "=" then target.y = target.y + 1
      elseif ev[2] == "-" then target.y = target.y - 1
      elseif ev[2] == "i" then map.zoom(vp, 1.5)        -- zoom in (map only; +/- nudge target Y)
      elseif ev[2] == "o" then map.zoom(vp, 1 / 1.5)    -- zoom out
      elseif ev[2] == "f" then followToggle()
      elseif ev[2] == "g" then vp.follow = false; map.fit(vp)
      elseif ev[2] == "s" then target.x, target.z = nil, nil
      elseif ev[2] == "q" then break end
    elseif e == "monitor_touch" then
      local tx, ty = ev[3], ev[4]
      local hit = false
      for _, b in ipairs(buttons) do
        if ty == b.y and tx >= b.x1 and tx <= b.x2 then b.fn(); hit = true; break end
      end
      if not hit and mapProj and map.inBox(mapProj, tx, ty) then
        target.x, target.z = map.screenToWorld(mapProj, tx, ty)   -- tap the map to set the X/Z goto
      end
    end
  end
end

parallel.waitForAny(controlLoop, gpsLoop)

releaseHorizontal()
for _, s in ipairs(BURNER_SIDES) do redstone.setAnalogOutput(s, 0) end
saveState(); saveNav()
if logf then logf.close() end
if mon then pcall(mon.setBackgroundColor, colors.black); pcall(mon.clear) end
print("shipnav stopped - relays + burner redstone cut. log -> /" .. LOG_FILE)
