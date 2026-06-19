-- treefarm: 2x2 giant spruce harvester. bonemeals the saplings from a ground-level
-- ring cell beside the pad (turtle stays off the trunk + canopy), with natural growth
-- as the fallback; fells the trunk, deposits logs to the store pool, then asks the
-- store to smelt SMELT_FRACTION of the haul into charcoal (the rest stays as logs).
-- saplings + bone meal refill from the store pool -> SUPPLY_CHEST; decayed-leaf
-- saplings wash off a water catch-floor under the canopy -> input-marked chest.
--
-- LAYOUT (dock = origin, facing the pad = +Z forward):
--   dock at (x0,z0,y0); 2-block gap at z1,z2; 2x2 dirt at z3,z4 (dirt y-1, sapling y0)
--   FUEL_CHEST   above the dock   (x0,z0,y+1)  -> suckUp + refuel
--   SUPPLY_CHEST behind the dock  (x0,z-1,y0)  -> store delivers saplings here
--   LOG_CHEST    below the dock   (x0,z0,y-1)  -> drop logs here (input-marked -> pool)
--   catch floor  solid at y-2 under the canopy, water at y-1 -> hopper -> input chest
-- the 2-block gap keeps the dock clear of the 5x5 growth column. chests on the store net.
-- GPS (needs comms.lua + gps2.lua + a radio antenna): first boot surveys HOME (world origin +
-- heading) at the dock; reports true world coords and snaps X/Z from GPS at safe points + on
-- restart so a reboot can't lose it. World Y rides dead reckoning (Y pending until Tower Delta).
-- run: treefarm         (start / resume from saved state)
--      treefarm reset    (wipe saved state; only when parked at the dock)

local comms  = require("comms")
local gps2   = require("gps2")
local beacon = require("beacon")
local sendLoc = beacon.sender(os.getComputerLabel() or ("tree#" .. os.getComputerID()), "tree")

local STORE_PROTOCOL = "store"
local STORE_NAME     = "store"
local RADIO_FREQ     = 1000

-- GPS world-coord upgrade (X/Z authoritative, Y PENDING). Calibration at the dock saves a world
-- origin (= HOME) + measured absolute heading; GPS X/Z snaps the position at safe points and on
-- restart so a reboot or shove can't lose the farm. World Y rides dead reckoning (exact here),
-- pending until Tower Delta (#5) is built + gpsrange confirms Y -> set TRUST_GPS_Y (which also
-- needs resync to snap Y; today X/Z only). No towers / failed survey -> legacy local mode.
local TRUST_GPS_Y        = false
local RESYNC_INTERVAL    = 30     -- seconds between GPS snaps at safe points
local DISPLACE_THRESHOLD = 5      -- snap gap (blocks) above this also fires a "displaced" alert

-- dock chest names are prompted on first boot and saved to treefarm.cfg (run
-- 'treefarm reset' to re-enter); blank = standalone with no store link.
local FUEL_CHEST   = ""    -- above the dock; store delivers fuel here
local SUPPLY_CHEST = ""    -- behind the dock; store delivers saplings/bone meal here
local LOG_CHEST    = ""    -- below the dock; auto-marked `input` on the store so logs vacuum to the pool

local SAPLING_ID  = "minecraft:spruce_sapling"
local BONEMEAL_ID = "minecraft:bone_meal"
local LOG_MATCH   = "log"
local LOG_ID      = "minecraft:spruce_log"   -- canonical id sent to the store's process api
local SMELT_FRACTION = 0.67                  -- fraction of each haul smelted to charcoal; rest kept as logs

local FUEL_MIN   = 200
local FUEL_FULL  = 1000      -- display cap for the Overview fuel bar
local GROW_WAIT      = 25        -- seconds parked at the dock between growth peeks
local GROW_TRIES     = 120       -- peeks before refueling and re-waiting (~50 min)
local BONEMEAL_POKES = 16        -- max bone meal applied per grow attempt before falling back
local STATE_FILE     = "treefarm.state"
local CFG_FILE       = "treefarm.cfg"   -- chest names, entered on first boot

local args = { ... }
local state
local lastResync, lastGpsOk = 0, nil

----------------------------------------------------------------- state
local function fresh()
  return { pos = { x = 0, z = 0, y = 0 }, head = 0, phase = "idle", halted = false }
end
local function save()
  local f = fs.open(STATE_FILE, "w"); f.write(textutils.serialize(state)); f.close()
end
local function load()
  if not fs.exists(STATE_FILE) then return false end
  local f = fs.open(STATE_FILE, "r"); state = textutils.unserialize(f.readAll()); f.close()
  return state ~= nil
end
local function setPhase(p) state.phase = p; save() end

-- GPS world transform (head 0 = +Z; local +X is head 1, one CW turn). worldHead0 = the world
-- compass (gps2.HEADINGS: 0=+X 1=+Z 2=-X 3=-Z) that local head-0 forward points to. Only valid
-- once calibrated; callers guard on state.gps.
local H = gps2.HEADINGS
local function l2w(p)
  local o, w0 = state.origin, state.worldHead0
  local vZ, vX = H[w0], H[(w0 + 1) % 4]
  return { x = o.x + p.x * vX.x + p.z * vZ.x, y = o.y + p.y, z = o.z + p.x * vX.z + p.z * vZ.z }
end
local function w2l(W)
  local o, w0 = state.origin, state.worldHead0
  local vZ, vX = H[w0], H[(w0 + 1) % 4]
  local dx, dz = W.x - o.x, W.z - o.z
  return { x = math.floor(dx * vX.x + dz * vX.z + 0.5), z = math.floor(dx * vZ.x + dz * vZ.z + 0.5) }
end
local function absHead() return (state.worldHead0 + state.head) % 4 end

-- a queued "reboot" from the store is honored wherever we read a reply. replies are read
-- only between completed moves, and every move persists state, so a reboot resumes via
-- recover() from a consistent position (with freshly pulled code). guard save() if unset.
local function rebootIfAsked(body)
  if body == "reboot" then if state then save() end; os.reboot() end
end

----------------------------------------------------------------- comms
local function request(cmd)
  comms.send(STORE_NAME, cmd, STORE_PROTOCOL)
  local m = comms.receive(STORE_PROTOCOL, 1.5)
  rebootIfAsked(m and m.body)
  return m and m.body
end

local alertAt = {}
local function alert(kind)
  local now = os.clock()
  if alertAt[kind] and now - alertAt[kind] < 30 then return end
  alertAt[kind] = now
  if not comms.up() then return end
  comms.send(STORE_NAME, { type = "alert", id = os.getComputerID(), label = os.getComputerLabel(), msg = kind, phase = state.phase }, STORE_PROTOCOL)
end

local function checkin(phase)
  if phase then setPhase(phase) end
  if not comms.up() then return nil end
  local fl = turtle.getFuelLevel()
  local fuel = (fl == "unlimited") and FUEL_FULL or math.min(fl, FUEL_FULL)
  local pos, head, gpsFlag = state.pos, nil, nil
  if state.gps and state.origin then pos = l2w(state.pos); head = absHead(); gpsFlag = lastGpsOk end
  comms.send(STORE_NAME, {
    type = "telem", kind = "tree", id = os.getComputerID(), label = os.getComputerLabel(),
    phase = state.phase, fuel = fuel, fuelMax = FUEL_FULL,
    pct = 0, halted = state.halted, pos = { x = pos.x, y = pos.y, z = pos.z }, head = head, gps = gpsFlag,
    harvests = state.harvests or 0, logs = state.lastLogs or 0,
  }, STORE_PROTOCOL)
  -- presence beacon -> fleet maps: calibrated = free dead-reckoned world pos; uncalibrated =
  -- a direct GPS fix (cached ~10s) so a legacy turtle still appears without a dock reset
  if state.gps and state.origin then sendLoc(os.clock(), pos)
  else local fx = gps2.tryFix(10); if fx then sendLoc(os.clock(), fx) end end
  local r = comms.receive(STORE_PROTOCOL, 0.3)
  local body = r and r.body
  rebootIfAsked(body)
  if body == "rtb" then state.halted = true; save()
  elseif body == "continue" then state.halted = false; save() end
  return body
end

----------------------------------------------------------------- movement (dead reckoned, persisted)
local DIRS = { [0] = { x = 0, z = 1 }, [1] = { x = 1, z = 0 }, [2] = { x = 0, z = -1 }, [3] = { x = -1, z = 0 } }

local function turnR() turtle.turnRight(); state.head = (state.head + 1) % 4; save() end
local function face(h) while state.head ~= h do turnR() end end

local function isProtected(name)
  return name:find("chest", 1, true) ~= nil or name:find("barrel", 1, true) ~= nil or name:find("shulker_box", 1, true) ~= nil
end

local function fwd()
  local n = 0
  while turtle.detect() do
    local ok, d = turtle.inspect(); if ok and d.name and isProtected(d.name) then return false end
    if not turtle.dig() then turtle.attack() end
    n = n + 1; if n > 40 then return false end
  end
  if turtle.forward() then
    state.pos.x = state.pos.x + DIRS[state.head].x
    state.pos.z = state.pos.z + DIRS[state.head].z
    save(); return true
  end
  return false
end

local function up()
  while turtle.detectUp() do
    local ok, d = turtle.inspectUp(); if ok and d.name and isProtected(d.name) then return false end
    if not turtle.digUp() then turtle.attackUp() end
  end
  if turtle.up() then state.pos.y = state.pos.y + 1; save(); return true end
  return false
end

local function down()
  while turtle.detectDown() do
    local ok, d = turtle.inspectDown(); if ok and d.name and isProtected(d.name) then return false end
    if not turtle.digDown() then turtle.attackDown() end
  end
  if turtle.down() then state.pos.y = state.pos.y - 1; save(); return true end
  return false
end

local function goTo(tx, tz, ty)
  if state.pos.x < tx then face(1) elseif state.pos.x > tx then face(3) end
  while state.pos.x ~= tx do if not fwd() then break end end
  if state.pos.z < tz then face(0) elseif state.pos.z > tz then face(2) end
  while state.pos.z ~= tz do if not fwd() then break end end
  while state.pos.y < ty do if not up() then break end end
  while state.pos.y > ty do if not down() then break end end
end

local function home() goTo(0, 0, 0); face(0) end

-- come back to the dock from the pad: descend in the gap first so the y+1 lane
-- never collides with the fuel chest sitting directly above the dock.
local function retreat()
  if state.pos.y > 0 then
    goTo(0, 1, state.pos.y)
    while state.pos.y > 0 do if not down() then break end end
  end
  home()
end

----------------------------------------------------------------- GPS calibration + re-sync
local DIRNAME = { [0] = "+X", [1] = "+Z", [2] = "-X", [3] = "-Z" }

local calFwded = false                    -- true while the survey has us one block off the dock
local function calFwd()                   -- dig-capable one-block forward (into the gap at y0)
  local n = 0
  while turtle.detect() do
    if not turtle.dig() then turtle.attack() end
    n = n + 1; if n > 40 then return false end
  end
  if turtle.forward() then calFwded = true; return true end
  return false
end
local function calBack()
  for _ = 1, 5 do if turtle.back() then calFwded = false; return true end; sleep(0.3) end
  return false
end

local function calibrateGps()
  if not comms.up() then print("gps: no antenna, legacy local mode"); return end
  face(0)                                 -- head 0 (+Z, toward the gap) for the survey
  print("gps: calibrating heading...")
  calFwded = false
  local origin, h = gps2.calibrate(calFwd, calBack)
  if calFwded then                        -- moved out but never got back: we're off the dock
    alert("gps offdock")
    for _ = 1, 10 do if calBack() then break end; sleep(0.5) end
  end
  if not origin then
    print("gps: calibration failed (" .. tostring(h) .. "); legacy local mode")
    state.gps = false; save(); return
  end
  state.origin = { x = math.floor(origin.x + 0.5), y = math.floor(origin.y + 0.5),
                   z = math.floor(origin.z + 0.5) }
  state.worldHead0 = h
  state.gps = true
  save()
  print(("gps: home %d,%d,%d facing %s%s"):format(state.origin.x, state.origin.y, state.origin.z,
    DIRNAME[h], TRUST_GPS_Y and "" or " (Y pending)"))
end

-- GPS owns X/Z: snap the local position to a fix at safe points (normally a no-op; corrects a
-- reboot/shove). Dead reckoning bridges between fixes; Y is pending (X/Z only). force ignores the
-- cadence gate (restart + at the dock, the most reliable fix).
local function resync(force)
  if not (state.gps and state.origin) or not comms.up() then return end
  if not force and os.clock() - lastResync < RESYNC_INTERVAL then return end
  lastResync = os.clock()
  local fix = gps2.tryFix(0)
  if not fix then lastGpsOk = false; return end
  lastGpsOk = true
  local l = w2l(fix)
  local gap = math.max(math.abs(l.x - state.pos.x), math.abs(l.z - state.pos.z))
  if gap == 0 then return end
  print(("gps: snap X/Z %d,%d -> %d,%d"):format(state.pos.x, state.pos.z, l.x, l.z))
  if gap > DISPLACE_THRESHOLD then alert("displaced") end
  state.pos.x, state.pos.z = l.x, l.z
  save()
end

----------------------------------------------------------------- inventory
local function invCount(id)
  local n = 0
  for s = 1, 16 do local d = turtle.getItemDetail(s); if d and d.name == id then n = n + d.count end end
  return n
end
local function selectItem(id)
  for s = 1, 16 do local d = turtle.getItemDetail(s); if d and d.name == id then turtle.select(s); return true end end
  return false
end

local function refuel()
  if turtle.getFuelLevel() == "unlimited" or turtle.getFuelLevel() > FUEL_MIN then return end
  request(("fuel %s 64"):format(FUEL_CHEST))
  sleep(0.6)
  for _ = 1, 8 do if not turtle.suckUp() then break end end
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and (d.name == "minecraft:coal" or d.name == "minecraft:charcoal") then turtle.select(s); turtle.refuel() end
  end
  turtle.select(1)
  if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() <= FUEL_MIN then alert("out of fuel") end
end

local function drawSupply()
  request(("give %s %s 64"):format(SUPPLY_CHEST, SAPLING_ID))
  request(("give %s %s 64"):format(SUPPLY_CHEST, BONEMEAL_ID))
  sleep(0.4)
  face(2)
  for _ = 1, 16 do if not turtle.suck() then break end end
  face(0)
  print(("on hand: %d saplings, %d bonemeal"):format(invCount(SAPLING_ID), invCount(BONEMEAL_ID)))
end

----------------------------------------------------------------- pad ops
local PAD = { { 0, 3 }, { 1, 3 }, { 0, 4 }, { 1, 4 } }

-- plant all four from y+1, traversing above the saplings, then fully retreat off the pad
local function plant()
  goTo(0, 1, 0)                       -- into the gap
  up()                                -- rise to y+1 in the gap, clear of the footprint
  for _, c in ipairs(PAD) do
    goTo(c[1], c[2], 1)
    if selectItem(SAPLING_ID) then turtle.placeDown() end
  end
  retreat()
end

-- peek the NW trunk cell from the gap edge, then retreat: "log" | "sapling" | "empty"
local function peek()
  goTo(0, 2, 0); face(0)
  local ok, d = turtle.inspect()
  retreat()
  if ok and d and d.name then
    if d.name:find(LOG_MATCH, 1, true) then return "log" end
    if d.name:find("sapling", 1, true) then return "sapling" end
  end
  return "empty"
end

local function waitGrow()
  for _ = 1, GROW_TRIES do
    if peek() == "log" then return true end
    checkin("growing")
    if state.halted then return false end       -- rtb during the wait: bail to cycle, which parks
    sleep(GROW_WAIT)
  end
  return false
end

-- hit the NW sapling with bone meal from the ring cell; bonemealing one sapling of a
-- valid 2x2 grows the whole tree. the turtle sits at (0,2) ground level, off the trunk
-- and below the canopy, so it is not one of the cells the tree needs clear.
local function bonemealPad()
  if invCount(BONEMEAL_ID) == 0 then return false end
  goTo(0, 2, 0); face(0)
  local grown = false
  for _ = 1, BONEMEAL_POKES do
    local ok, d = turtle.inspect()
    if ok and d and d.name and d.name:find(LOG_MATCH, 1, true) then grown = true; break end
    if not selectItem(BONEMEAL_ID) then break end
    turtle.place()
    sleep(0.1)
  end
  if not grown then
    local ok, d = turtle.inspect()
    grown = (ok and d and d.name and d.name:find(LOG_MATCH, 1, true)) and true or false
  end
  turtle.select(1)
  retreat()
  return grown
end

-- trace the 2x2 at the current level, digging each column; returns true if a log was hit
local function clearRing()
  local got = false
  for _ = 1, 4 do
    local ok, d = turtle.inspect()
    if ok and d.name and d.name:find(LOG_MATCH, 1, true) then got = true end
    fwd()
    turnR()
  end
  return got
end

local function fellTree()
  goTo(0, 3, 0)                       -- enter the NW trunk column at the base
  local climbed = 0
  while true do
    local got = clearRing()
    local upLog = false
    local ok, d = turtle.inspectUp()
    if ok and d.name and d.name:find(LOG_MATCH, 1, true) then upLog = true end
    if not got and not upLog then break end
    if not up() then break end
    climbed = climbed + 1
    if climbed > 40 then break end
  end
  retreat()
end

-- drop the whole haul into the pool, then ask the store to smelt a fraction of it
-- into charcoal (the rest stays as logs). the store vacuums the log chest before
-- pulling, so the just-dropped logs are in the pool when it smelts them.
local function depositLogs()
  local logs = 0
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and d.name:find(LOG_MATCH, 1, true) then logs = logs + d.count; turtle.select(s); turtle.dropDown() end
  end
  turtle.select(1)
  if logs > 0 then
    state.harvests = (state.harvests or 0) + 1   -- store stamps the time when this increments
    state.lastLogs = logs
    save()
    local n = math.floor(logs * SMELT_FRACTION)
    if n > 0 then request(("process smelt %s %d"):format(LOG_ID, n)) end
  end
end

-- bone meal first (instant when the column is clear), natural growth as the fallback
local function growAndFell()
  if invCount(BONEMEAL_ID) < BONEMEAL_POKES then drawSupply() end
  checkin("growing")
  local grown = bonemealPad()
  if not grown then grown = waitGrow() end
  if not grown then return false end
  checkin("felling"); fellTree()
  checkin("hauling"); depositLogs()
  return true
end

----------------------------------------------------------------- main
-- resume from any saved position: descend out of a trunk, re-home, finish a partial fell
local function recover()
  resync(true)                          -- re-localize X/Z from GPS first (recover a lost turtle)
  if state.pos.x ~= 0 or state.pos.z ~= 0 or state.pos.y ~= 0 then
    while state.pos.y > 0 do if not down() then break end end
    home()
  end
  if state.phase == "felling" then fellTree(); depositLogs()
  elseif state.phase == "hauling" then depositLogs() end
  setPhase("idle")
end

-- rtb parks the farm at the dock and holds until continue; HALT shows on the Overview/pad
local function holdIfHalted()
  if not state.halted then return end
  retreat()
  while state.halted do
    checkin("halted")
    sleep(3)
  end
  checkin("idle")
end

local function cycle()
  holdIfHalted()
  refuel()
  resync(false)                         -- keep X/Z honest at the dock
  local st = peek()
  if st == "log" then                 -- a grown (or leftover) trunk is standing: fell it
    checkin("felling"); fellTree()
    checkin("hauling"); depositLogs()
    return
  end
  if st == "sapling" then             -- planted, not grown yet: bone meal it / wait
    growAndFell()
    return
  end
  checkin("idle")                     -- empty pad: plant a fresh 2x2
  if invCount(SAPLING_ID) < 4 or invCount(BONEMEAL_ID) < BONEMEAL_POKES then drawSupply() end
  if invCount(SAPLING_ID) < 4 then
    alert("no saplings"); checkin("nosaplings"); print("no saplings available; waiting"); sleep(30); return
  end
  checkin("planting"); plant()
  if not growAndFell() and not state.halted then print("tree did not grow this cycle") end
end

local function askChest(label)
  write(label .. ": ")
  local s = read() or ""
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function loadOrAskCfg()
  if fs.exists(CFG_FILE) then
    local f = fs.open(CFG_FILE, "r"); local t = textutils.unserialize(f.readAll()); f.close()
    if type(t) == "table" then
      FUEL_CHEST   = t.fuel or ""
      SUPPLY_CHEST = t.supply or ""
      LOG_CHEST    = t.log or ""
      return
    end
  end
  print("first boot - name the dock chests (run 'invs' on the store for wired names).")
  print("blank = run standalone with no store link.")
  FUEL_CHEST   = askChest("fuel chest (above dock, marked fuel)")
  SUPPLY_CHEST = askChest("supply chest (behind dock, saplings/bone meal)")
  LOG_CHEST    = askChest("log chest (below dock, auto-marked input)")
  local f = fs.open(CFG_FILE, "w")
  f.write(textutils.serialize({ fuel = FUEL_CHEST, supply = SUPPLY_CHEST, log = LOG_CHEST }))
  f.close()
  print("saved to " .. CFG_FILE .. "  (run 'treefarm reset' to re-enter)")
end

local function main()
  if args[1] == "reset" then
    if fs.exists(STATE_FILE) then fs.delete(STATE_FILE) end
    if fs.exists(CFG_FILE) then fs.delete(CFG_FILE) end
  end
  loadOrAskCfg()
  comms.open({ freq = RADIO_FREQ, proto = STORE_PROTOCOL })
  if not load() then state = fresh(); save() end
  if state.halted == nil then state.halted = false end
  if LOG_CHEST ~= "" and comms.up() then request("mark " .. LOG_CHEST .. " input") end
  print("treefarm online (freq " .. RADIO_FREQ .. ", phase " .. state.phase .. ")")
  recover()
  refuel()
  if not state.gps then calibrateGps() end   -- at the dock after recover; one-time on first boot
  while true do cycle() end
end

main()
