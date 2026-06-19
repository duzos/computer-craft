-- wheatfarm: 16x16 wheat plot harvester. travels one block above the crops,
-- harvests mature wheat (replanting as it goes), bone-meals the immature ones when
-- it can, and ships raw wheat + surplus seeds into the store pool. seeds mostly
-- self-sustain; seeds + bone meal refill from the store. crafting wheat into bread
-- is a separate downstream "baker" stage (its own program) -- this turtle never crafts.
--
-- UPGRADES: a hoe (harvests crops) + a mini radio antenna (comms). two slots, no room
-- for a crafting table -- hence the harvest/bake split.
--
-- LAYOUT (dock = origin, turtle parked facing +Z = head 0):
--   16x16 farmland at y=0, crops at y=1; the turtle TRAVELS AT y=2 so inspect/dig/
--   placeDown all hit the crop cell and it never walks on farmland or water.
--   grid cells (x,z) span 0..15. the column straight above the dock (0,0,*) is a
--   clear shaft: the turtle rises to y=2 here, crosses the grid, descends here to dock.
--   FUEL_CHEST    left of the dock   (-1, 0, 0)  face -X (head 3), suck; store delivers fuel
--   SUPPLY_CHEST  behind the dock    ( 0,-1, 0)  face -Z (head 2), suck; store delivers seeds + bone meal
--   OUTPUT_CHEST  below the dock     ( 0, 0,-1)  dropDown; input-marked -> store pool (wheat + seeds)
--   water sources at grid (4,4)(4,11)(11,4)(11,11): +-4 hydrates all 256 cells; the
--   turtle skips those cells (and the (0,0) shaft), leaving ~252 plantable.
-- the three chests sit off the plot and out of the shaft, on the store's wired net.
-- GPS (needs comms.lua + gps2.lua + a radio antenna): first boot surveys HOME (world origin +
-- heading) from the y=2 travel plane; reports true world coords and snaps X/Z from GPS at safe
-- points + on restart so a reboot can't lose it. World Y rides dead reckoning (Y pending).
-- run: wheatfarm        (start / resume from saved state)
--      wheatfarm reset   (wipe saved state; only when docked)

local comms  = require("comms")
local gps2   = require("gps2")
local beacon = require("beacon")
local sendLoc = beacon.sender(os.getComputerLabel() or ("wheat#" .. os.getComputerID()), "wheat")

local STORE_PROTOCOL = "store"
local STORE_NAME     = "store"
local RADIO_FREQ     = 1000        -- must match the store's RADIO_FREQ

-- GPS world-coord upgrade (X/Z authoritative, Y PENDING). Calibration at the dock saves a world
-- origin (= HOME) + measured absolute heading; GPS X/Z snaps the position at safe points and on
-- restart so a reboot or shove can't lose the farm. World Y rides dead reckoning, pending until
-- Tower Delta (#5) is built + gpsrange confirms Y -> set TRUST_GPS_Y (which also needs resync to
-- snap Y; today X/Z only). No towers / failed survey -> legacy local mode, logged.
local TRUST_GPS_Y        = false
local RESYNC_INTERVAL    = 30     -- seconds between GPS snaps at safe points
local DISPLACE_THRESHOLD = 5      -- snap gap (blocks) above this also fires a "displaced" alert

-- dock chest names are prompted on first boot and saved to wheatfarm.cfg (run
-- 'wheatfarm reset' to re-enter); blank = standalone with no store link.
local FUEL_CHEST   = ""   -- left of the dock; store delivers fuel here
local SUPPLY_CHEST = ""   -- behind the dock; store delivers seeds/bone meal here
local OUTPUT_CHEST = ""   -- below the dock; auto-marked `input` so wheat/seeds vacuum into the pool

local WIDTH  = 16
local LENGTH = 16

local SEED_ID     = "minecraft:wheat_seeds"
local WHEAT_ID    = "minecraft:wheat"
local BONEMEAL_ID = "minecraft:bone_meal"

local WATER_CELLS = { {4,4}, {4,11}, {11,4}, {11,11} }

local FUEL_MIN  = 500
local FUEL_FULL = 2000             -- display cap for the Overview fuel bar
local GROW_WAIT = 60               -- seconds parked at the dock between passes
local BONEMEAL_POKES = 16          -- max bone meal applied to one cell before giving up

local SEED_KEEP     = 64           -- seeds held back on board for replanting
local HAUL_FREE_MIN = 2            -- haul-and-deposit once free slots drop to this
local STATE_FILE    = "wheatfarm.state"
local CFG_FILE      = "wheatfarm.cfg"   -- chest names, entered on first boot

local args = { ... }
local state
local last = "-"
local cellTick = 0
local lastResync, lastGpsOk = 0, nil

----------------------------------------------------------------- state
local function fresh()
  return { pos = { x = 0, z = 0, y = 0 }, head = 0, xdir = 1, phase = "idle", halted = false }
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

-- % of the plot walked this pass (serpentine always sweeps z 0->15)
local function passPct()
  local visited = state.pos.z * WIDTH
  if state.xdir == 1 then visited = visited + state.pos.x + 1 else visited = visited + (WIDTH - state.pos.x) end
  local p = math.floor(100 * visited / (WIDTH * LENGTH))
  if p > 100 then p = 100 elseif p < 0 then p = 0 end
  return p
end

local function checkin(phase)
  if phase then setPhase(phase) end
  if not comms.up() then return nil end
  local fl = turtle.getFuelLevel()
  local pos, head, gpsFlag = state.pos, nil, nil
  if state.gps and state.origin then pos = l2w(state.pos); head = absHead(); gpsFlag = lastGpsOk end
  comms.send(STORE_NAME, {
    type = "telem", id = os.getComputerID(), label = os.getComputerLabel(),
    phase = state.phase, pct = passPct(), fuel = (fl == "unlimited") and FUEL_FULL or fl, fuelMax = FUEL_FULL,
    pos = { x = pos.x, y = pos.y, z = pos.z }, head = head, gps = gpsFlag, halted = state.halted, last = last,
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

local function atDock()
  return state.pos.x == 0 and state.pos.z == 0 and state.pos.y == 0
end

-- rise out of the shaft to the travel plane (call only from the dock)
local function launch()
  while state.pos.y < 2 do if not up() then break end end
end

-- cross back to the shaft at travel height, then drop down to the dock
local function dock()
  if atDock() then face(0); return end
  while state.pos.y < 2 do if not up() then break end end
  goTo(0, 0, 2)
  while state.pos.y > 0 do if not down() then break end end
  face(0)
end

----------------------------------------------------------------- GPS calibration + re-sync
local DIRNAME = { [0] = "+X", [1] = "+Z", [2] = "-X", [3] = "-Z" }

local calFwded = false                    -- true while the survey has us one block off the shaft
local function calFwd()                   -- dig-capable one-block forward (over the crops at y2)
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
  launch()                                -- rise to y=2 (clear of the crops) for the survey
  face(0)                                 -- head 0 (+Z) for the survey
  print("gps: calibrating heading...")
  calFwded = false
  local origin, h = gps2.calibrate(calFwd, calBack)
  if calFwded then                        -- moved out but never got back: re-home over the shaft
    alert("gps offdock")
    for _ = 1, 10 do if calBack() then break end; sleep(0.5) end
  end
  if not origin then
    print("gps: calibration failed (" .. tostring(h) .. "); legacy local mode")
    state.gps = false; dock(); save(); return
  end
  -- survey ran at local (0,0,2): origin (local 0,0,0) shares X/Z, sits 2 lower (Y pending anyway)
  state.origin = { x = math.floor(origin.x + 0.5), y = math.floor(origin.y + 0.5) - 2,
                   z = math.floor(origin.z + 0.5) }
  state.worldHead0 = h
  state.gps = true
  save()
  dock()                                  -- back down to the dock
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
local function freeSlots()
  local n = 0
  for s = 1, 16 do if turtle.getItemCount(s) == 0 then n = n + 1 end end
  return n
end
local function needHaul() return freeSlots() <= HAUL_FREE_MIN end

local function refuel()
  if turtle.getFuelLevel() == "unlimited" or turtle.getFuelLevel() > FUEL_MIN then return end
  request(("fuel %s 64"):format(FUEL_CHEST))
  sleep(0.6)
  face(3)
  for _ = 1, 8 do if not turtle.suck() then break end end
  face(0)
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and (d.name == "minecraft:coal" or d.name == "minecraft:charcoal") then turtle.select(s); turtle.refuel() end
  end
  turtle.select(1)
  if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() <= FUEL_MIN then alert("out of fuel") end
end

local function drawSupply()
  request(("give %s %s 64"):format(SUPPLY_CHEST, SEED_ID))
  request(("give %s %s 64"):format(SUPPLY_CHEST, BONEMEAL_ID))
  sleep(0.4)
  face(2)
  for _ = 1, 16 do if not turtle.suck() then break end end
  face(0)
end

-- drop every stack of `id` into the output chest, keeping at most `keep` on board
local function dropSurplus(id, keep)
  local kept = 0
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and d.name == id then
      turtle.select(s)
      if kept < keep then
        local take = math.min(d.count, keep - kept)
        kept = kept + take
        if d.count > take then turtle.dropDown(d.count - take) end
      else
        turtle.dropDown()
      end
    end
  end
  turtle.select(1)
end

-- at the dock: ship wheat + surplus seeds to the pool, keep the replant reserve
local function deposit()
  setPhase("hauling")
  dropSurplus(WHEAT_ID, 0)
  dropSurplus(SEED_ID, SEED_KEEP)
  last = "deposited"
  checkin("hauling")
end

----------------------------------------------------------------- harvest
local function isWaterCell(x, z)
  for _, c in ipairs(WATER_CELLS) do if c[1] == x and c[2] == z then return true end end
  return false
end

local function plantDown()
  if not selectItem(SEED_ID) then return false end
  return turtle.placeDown()
end

-- poke bone meal at the crop below until it matures (random 2-5 stages each), capped;
-- harvests + replants if it reaches age 7 in hand
local function bonemealDown()
  if invCount(BONEMEAL_ID) == 0 then return end
  for _ = 1, BONEMEAL_POKES do
    local ok, d = turtle.inspectDown()
    if not (ok and d and d.name == WHEAT_ID) then return end
    if d.state and d.state.age == 7 then
      turtle.digDown(); plantDown()
      last = ("bonemeal harvest %d,%d"):format(state.pos.x, state.pos.z)
      return
    end
    if not selectItem(BONEMEAL_ID) then return end
    turtle.placeDown()
    sleep(0.05)
  end
end

local function tendCell()
  if state.pos.x == 0 and state.pos.z == 0 then return end          -- dock shaft
  if isWaterCell(state.pos.x, state.pos.z) then return end
  local ok, d = turtle.inspectDown()
  if ok and d and d.name == "minecraft:water" then return end
  if ok and d and d.name == WHEAT_ID then
    if d.state and d.state.age == 7 then
      turtle.digDown()
      plantDown()
      last = ("harvested %d,%d"):format(state.pos.x, state.pos.z)
    else
      bonemealDown()
    end
  else
    if plantDown() then bonemealDown() end                          -- empty farmland: replant + poke
  end
end

local function maybeCheckin()
  cellTick = cellTick + 1
  if cellTick % 8 ~= 0 then return false end
  checkin("harvesting")
  return state.halted
end

local function farX() return (state.xdir == 1) and (WIDTH - 1) or 0 end

-- advance to the next z row (zdir is always +1) and flip the x sweep direction
local function nextRow()
  if state.pos.z == LENGTH - 1 then return false end
  face(0)
  if not fwd() then return false end
  state.xdir = -state.xdir
  save()
  return true
end

-- serpentine the grid from the current cell; "done" | "haul" | "halt"
local function runPass()
  tendCell()
  while true do
    if maybeCheckin() then return "halt" end
    if needHaul() then return "haul" end
    if state.pos.x ~= farX() then
      face(state.xdir == 1 and 1 or 3)
      if fwd() then tendCell()
      elseif nextRow() then tendCell()
      else return "done" end
    else
      if not nextRow() then return "done" end
      tendCell()
    end
  end
end

----------------------------------------------------------------- main
local function growWait()
  setPhase("growing")
  local waited = 0
  while waited < GROW_WAIT do
    checkin("growing")
    if state.halted then return end
    sleep(3)
    waited = waited + 3
  end
end

-- rtb parks the farm at the dock and holds until continue; HALT shows on the Overview
local function holdIfHalted()
  if not state.halted then return end
  if not atDock() then dock() end
  while state.halted do
    checkin("halted")
    sleep(3)
  end
  checkin("idle")
end

-- resume from any saved position: climb to the travel plane, re-dock, ship what's carried
local function recover()
  resync(true)                          -- re-localize X/Z from GPS first (recover a lost turtle)
  if not atDock() then
    while state.pos.y < 2 do if not up() then break end end
    dock()
  end
  if invCount(WHEAT_ID) > 0 then deposit() end
  setPhase("idle")
end

local function cycle()
  holdIfHalted()
  refuel()
  resync(false)                         -- keep X/Z honest at the dock
  if invCount(SEED_ID) < SEED_KEEP or invCount(BONEMEAL_ID) < BONEMEAL_POKES then drawSupply() end

  launch()
  goTo(0, 0, 2); state.xdir = 1; save()
  setPhase("harvesting")
  while true do
    local r = runPass()
    if r == "done" then break end
    if r == "halt" then dock(); return end
    local rx, rz, rxd = state.pos.x, state.pos.z, state.xdir   -- haul: ship, then resume the pass
    dock()
    deposit()
    refuel()
    if invCount(SEED_ID) < SEED_KEEP then drawSupply() end
    if state.halted then return end
    launch()
    goTo(rx, rz, 2); state.xdir = rxd; save()
    setPhase("harvesting")
  end

  dock()
  deposit()
  growWait()
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
      OUTPUT_CHEST = t.output or ""
      return
    end
  end
  print("first boot - name the dock chests (run 'invs' on the store for wired names).")
  print("blank = run standalone with no store link.")
  FUEL_CHEST   = askChest("fuel chest (left of dock, marked fuel)")
  SUPPLY_CHEST = askChest("supply chest (behind dock, seeds/bone meal)")
  OUTPUT_CHEST = askChest("output chest (below dock, auto-marked input)")
  local f = fs.open(CFG_FILE, "w")
  f.write(textutils.serialize({ fuel = FUEL_CHEST, supply = SUPPLY_CHEST, output = OUTPUT_CHEST }))
  f.close()
  print("saved to " .. CFG_FILE .. "  (run 'wheatfarm reset' to re-enter)")
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
  if state.xdir == nil then state.xdir = 1 end
  if OUTPUT_CHEST ~= "" and comms.up() then request("mark " .. OUTPUT_CHEST .. " input") end
  print(("wheatfarm online (freq %d, phase %s)"):format(RADIO_FREQ, state.phase))
  recover()
  refuel()
  if not state.gps then calibrateGps() end   -- at the dock after recover; one-time on first boot
  while true do cycle() end
end

main()
