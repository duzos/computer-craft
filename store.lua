-- unified storage controller: sort / get / find / list, Create fan processing, dashboard
-- one computer on a wired-modem network with: storage barrels, one I/O barrel,
-- Create fan processing barrels (smelt/cook/wash + output), a chat box, and an advanced monitor.
-- commands work on the terminal and in chat (prefixed). e.g.  get raw_iron 64

local comms = require("comms")
local args = { ... }

----------------------------------------------------------------- config
-- device/placement-specific barrels are prompted on first boot and saved to store.cfg
-- (run 'store reset' to re-enter); fleet-wide constants and tuning live below.
-- chat commands: prefix with $ in chat (the chat box hides it and fires a hidden event)
local CFG_FILE = "store.cfg"
local IO_BARREL                                    -- I/O barrel (required)
-- inventory manager (optional): a buffer barrel must physically TOUCH the manager and
-- also be wired to the network. the controller fills/empties it; the manager hands it to you.
local MANAGER_BARREL                               -- buffer barrel touching the manager
local MANAGER_DIR                                  -- face of the manager that barrel sits on
-- Create fan processing barrels: the store pushes items into one of three input
-- barrels, the fans process them (smelt = lava/blasting incl. logs->charcoal,
-- cook = fire/smoking, wash = water/splashing) and the results land in OUT_BARREL,
-- which is vacuumed back into the pool like an input chest.
local COOK_BARREL, SMELT_BARREL, WASH_BARREL, OUT_BARREL

local PROC_TYPES  = { "smelt", "cook", "wash" }   -- display/iteration order
local PROC_BARREL = {}            -- type -> barrel name; filled from config by applyProcTables
local SPECIAL_ROLE = {}           -- barrel name -> fixed role label (shown in invs/marks)
local PROC_SET = {}               -- barrel name -> type, for discovery exclusion

-- (re)build the config-derived tables once the barrel names are known
local function applyProcTables()
  PROC_BARREL  = { smelt = SMELT_BARREL, cook = COOK_BARREL, wash = WASH_BARREL }
  SPECIAL_ROLE = {}
  if SMELT_BARREL ~= "" then SPECIAL_ROLE[SMELT_BARREL] = "smelt" end
  if COOK_BARREL  ~= "" then SPECIAL_ROLE[COOK_BARREL]  = "cook"  end
  if WASH_BARREL  ~= "" then SPECIAL_ROLE[WASH_BARREL]  = "wash"  end
  if OUT_BARREL   ~= "" then SPECIAL_ROLE[OUT_BARREL]   = "out"   end
  PROC_SET = {}
  for t, n in pairs(PROC_BARREL) do if n ~= "" then PROC_SET[n] = t end end
end

-- per-type idle auto-processing sets (config = initial seed; persisted to AUTO_FILE).
-- spruce logs are deliberately NOT auto-smelted: treefarm owns the keep/charcoal ratio.
local AUTO = {
  smelt = {
    ["minecraft:raw_iron"]   = true,
    ["minecraft:raw_copper"] = true,
    ["minecraft:raw_gold"]   = true,
    ["create:raw_zinc"]      = true,
  },
  cook = {},
  wash = {},
}
local AUTO_FILE  = "store.auto"
local SMELT_FILE = "store.smelt"   -- legacy single-set file; migrated into AUTO.smelt on first load
local PROC_CAP   = 64              -- max of one item pushed to a barrel per idle tick

local FUELS = {
  ["minecraft:coal"]     = true,
  ["minecraft:charcoal"] = true,
}

local STORE_PROTOCOL = "store"   -- fleet protocol; turtles/pad address messages to "store"
local GPS_PROTO      = "gps"     -- stations (gps towers + boiler) reboot on a broadcast on this proto
local STORE_HOSTNAME = "store"   -- name this computer answers to over comms
local RADIO_FREQ     = 1000      -- ClassicPeripherals radio frequency; turtles must match
local TOWER_RANGE    = 0         -- 0 = auto from the tower's getHeight; set a number to override
local SAFE_FRAC      = 0.85      -- data stays clean within this fraction of range

----------------------------------------------------------------- state
local storage  = {}
local inputs   = {}
local outputs  = {}
local fuels    = {}
local roles    = {}          -- name -> "input"|"output"|"fuel"  (unmarked = pool; IO_BARREL = both)
local ROLES_FILE = "store.roles"
local monitor, chatBox, manager
local monitors = {}          -- all monitors, biggest first
local monAssign = {}         -- monitor network-name -> "quarry"|"store"|"blank" (unset = auto by size)
local MONS_FILE = "store.mons"
local touchRegions = {}      -- monitor name -> { kind, rows/items, buttons = {{x1,x2,y,act,val}}, draw }
local monSel = {}            -- monitor name -> selected turtle id (turtles page)
local monStore = {}          -- monitor name -> { sel, scroll, amt, dest, sortMode, list, rows, maxScroll }
local STORE_AMOUNTS = { 1, 8, 16, 32, 64 }
local STORE_SORTS = {
  { key = "qty", cmp = function(a, b) return a.n > b.n end },
  { key = "low", cmp = function(a, b) return a.n < b.n end },
  { key = "a-z", cmp = function(a, b) return (a.id:match("[^:]+$") or a.id) < (b.id:match("[^:]+$") or b.id) end },
}
local function storeState(name)
  local s = monStore[name]
  if not s then s = { selId = nil, scroll = 0, amt = 64, dest = "duzo", sortMode = 1, procPick = false }; monStore[name] = s end
  return s
end
local turtles  = {}          -- id -> telemetry + lastHeard/eta/lastProgress
local pendingCmd = {}        -- id -> "rtb"|"continue"|"reboot"
local cmdQueue = {}
local mode = "SORT"          -- SORT (auto-eat barrel) | WAIT (holding a pickup)
local lastSnap = nil
local lastAction = "-"
local history = {}
local startClock = os.clock()
local index = { items = {}, usedSlots = 0, totalSlots = 0, totalItems = 0, types = 0 }
local indexDirty = false     -- set when the pool changed; ensureIndex() rebuilds lazily
local uiRev = 0              -- bumped on visible index changes; gates static-page (store) redraws
local function uiDirty() uiRev = uiRev + 1 end
local procPending = { smelt = 0, cook = 0, wash = 0 }   -- fan-barrel backlog, cached per render tick
local procFresh = false                                 -- procPending already refreshed this render pass?

local function logAction(s)
  lastAction = s
  history[#history + 1] = s
  while #history > 8 do table.remove(history, 1) end
end

local function saveRoles()
  local f = fs.open(ROLES_FILE, "w"); f.write(textutils.serialize(roles)); f.close()
end

local function loadRoles()
  if fs.exists(ROLES_FILE) then
    local f = fs.open(ROLES_FILE, "r"); roles = textutils.unserialize(f.readAll()) or {}; f.close()
  end
end

local function saveMons()
  local f = fs.open(MONS_FILE, "w"); f.write(textutils.serialize(monAssign)); f.close()
end

local function loadMons()
  if fs.exists(MONS_FILE) then
    local f = fs.open(MONS_FILE, "r"); monAssign = textutils.unserialize(f.readAll()) or {}; f.close()
  end
end

local function saveAuto()
  local f = fs.open(AUTO_FILE, "w"); f.write(textutils.serialize(AUTO)); f.close()
end

local function loadAuto()
  if fs.exists(AUTO_FILE) then
    local f = fs.open(AUTO_FILE, "r"); local t = textutils.unserialize(f.readAll()); f.close()
    if type(t) == "table" then
      for _, typ in ipairs(PROC_TYPES) do
        if type(t[typ]) == "table" then AUTO[typ] = t[typ] end
      end
    end
    return
  end
  -- migrate the legacy single auto-smelt set into AUTO.smelt
  if fs.exists(SMELT_FILE) then
    local f = fs.open(SMELT_FILE, "r"); local t = textutils.unserialize(f.readAll()); f.close()
    if type(t) == "table" then AUTO.smelt = t; saveAuto() end
  end
end

----------------------------------------------------------------- discovery
local SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }
local skipped = {}

local function discover()
  storage, skipped, inputs, outputs, fuels = {}, {}, {}, {}, {}
  for _, name in ipairs(peripheral.getNames()) do
    if SIDES[name] then
      if peripheral.hasType(name, "inventory") then skipped[#skipped + 1] = name end
    elseif peripheral.hasType(name, "inventory")
        and name ~= IO_BARREL and name ~= MANAGER_BARREL and not PROC_SET[name] then
      local r = roles[name]
      if name == OUT_BARREL or r == "input" then inputs[#inputs + 1] = name  -- OUT_BARREL vacuums to pool
      elseif r == "output" then outputs[#outputs + 1] = name
      elseif r == "fuel" then fuels[#fuels + 1] = name      -- delivery-only, never vacuumed/pooled
      else storage[#storage + 1] = name end
    end
  end
  monitor = peripheral.find("monitor")
  monitors = { peripheral.find("monitor") }
  for _, m in ipairs(monitors) do pcall(m.setTextScale, 0.5) end
  table.sort(monitors, function(a, b)
    local aw, ah = a.getSize(); local bw, bh = b.getSize()
    return aw * ah > bw * bh
  end)
  chatBox = peripheral.find("chat_box") or peripheral.find("chatBox")
  manager = peripheral.find("inventoryManager") or peripheral.find("inventory_manager")
  indexDirty = true                                 -- storage set may have changed
end

----------------------------------------------------------------- index
local INDEX_YIELD = 8   -- inventories scanned between comms-yields during a full rebuild

-- yield without sleeping a whole tick: lets commsLoop drain queued telem/commands
-- mid-scan, then resumes us as soon as the queue is clear (no 50ms timer penalty).
local function pumpYield()
  os.queueEvent("idx_yield")
  os.pullEvent("idx_yield")
end

local function buildIndex()
  local items, used, total, count = {}, 0, 0, 0
  for i, inv in ipairs(storage) do
    total = total + (peripheral.call(inv, "size") or 0)
    for slot, it in pairs(peripheral.call(inv, "list") or {}) do
      used = used + 1
      count = count + it.count
      local e = items[it.name]
      if not e then e = { count = 0, locations = {} }; items[it.name] = e end
      e.count = e.count + it.count
      e.locations[#e.locations + 1] = { inv = inv, slot = slot, count = it.count }
    end
    if i % INDEX_YIELD == 0 then pumpYield() end
  end
  local types = 0
  for _ in pairs(items) do types = types + 1 end
  index.items, index.usedSlots, index.totalSlots, index.totalItems, index.types =
    items, used, total, count, types
  indexDirty = false
  uiDirty()
end

-- only called from the worker coroutine / handlers it runs; never from commsLoop,
-- so the yields inside buildIndex can't re-enter the index.
local function ensureIndex()
  if indexDirty then buildIndex() end
end

----------------------------------------------------------------- transfers
local function storeFrom(src, slot, count)
  local remaining = count
  for _, inv in ipairs(storage) do
    if remaining <= 0 then break end
    remaining = remaining - peripheral.call(src, "pushItems", inv, slot, remaining)
  end
  local moved = count - remaining
  if moved > 0 then indexDirty = true end   -- pushed into the pool: a rebuild reconciles
  return moved
end

-- pull up to `want` of item `id` (its index entry `e`) into target `tgt`, updating the
-- index in place from the exact pushItems counts so no rebuild is needed on the pull path.
-- invariant this relies on: pool slots are mutated ONLY by this controller (pushItems via
-- storeFrom dirties; pulls update here). the manager buffer and fan barrels are excluded
-- from `storage` in discover(), so between rebuilds a referenced slot can only gain more of
-- the same item, never a different one -- the per-loc counts stay exact.
local function pullEntry(id, e, tgt, want)
  local moved, emptied = 0, false
  for _, loc in ipairs(e.locations) do
    if moved >= want then break end
    if loc.count > 0 then
      local m = peripheral.call(loc.inv, "pushItems", tgt, loc.slot, want - moved)
      if m > 0 then
        moved = moved + m
        loc.count = loc.count - m
        e.count = e.count - m
        index.totalItems = index.totalItems - m
        if loc.count <= 0 then index.usedSlots = index.usedSlots - 1; emptied = true end
      end
    end
  end
  if emptied then
    local kept = {}
    for _, loc in ipairs(e.locations) do if loc.count > 0 then kept[#kept + 1] = loc end end
    e.locations = kept
    if #kept == 0 then index.items[id] = nil; index.types = index.types - 1 end
  end
  if moved > 0 then uiDirty() end
  return moved
end

local function sortBarrel()
  local moved = 0
  for slot, it in pairs(peripheral.call(IO_BARREL, "list") or {}) do
    moved = moved + storeFrom(IO_BARREL, slot, it.count)   -- storeFrom flags the index dirty
  end
  return moved
end

local function retrieve(id, count)
  local e = index.items[id]
  if not e then return 0, false end
  local targets = {}
  for _, o in ipairs(outputs) do targets[#targets + 1] = o end
  targets[#targets + 1] = IO_BARREL
  local remaining, usedIO, emptied = count, false, false
  for _, loc in ipairs(e.locations) do
    if remaining <= 0 then break end
    for _, tgt in ipairs(targets) do
      if remaining <= 0 or loc.count <= 0 then break end
      local moved = peripheral.call(loc.inv, "pushItems", tgt, loc.slot, remaining)
      if moved > 0 then
        remaining = remaining - moved
        loc.count = loc.count - moved
        e.count = e.count - moved
        index.totalItems = index.totalItems - moved
        if tgt == IO_BARREL then usedIO = true end
        if loc.count <= 0 then index.usedSlots = index.usedSlots - 1; emptied = true end
      end
    end
  end
  if emptied then
    local kept = {}
    for _, loc in ipairs(e.locations) do if loc.count > 0 then kept[#kept + 1] = loc end end
    e.locations = kept
    if #kept == 0 then index.items[id] = nil; index.types = index.types - 1 end
  end
  if remaining < count then uiDirty() end
  return count - remaining, usedIO
end

local function vacuumInputs()
  for _, inv in ipairs(inputs) do
    for slot, it in pairs(peripheral.call(inv, "list") or {}) do
      storeFrom(inv, slot, it.count)
    end
  end
end

local PROTECT = {}                                  -- player slots never swept
for s = 0, 8 do PROTECT[s] = true end               -- hotbar
PROTECT[36] = true                                  -- offhand
for s = 100, 103 do PROTECT[s] = true end           -- armor

local function flushBuffer()
  for slot, it in pairs(peripheral.call(MANAGER_BARREL, "list") or {}) do
    storeFrom(MANAGER_BARREL, slot, it.count)
  end
end

local function deliverToPlayer(id, count)           -- pool -> buffer -> player inventory
  if not manager then return 0, "no inventory manager" end
  local e = index.items[id]
  if not e then return 0 end
  local toBuffer = 0
  for _, loc in ipairs(e.locations) do
    if toBuffer >= count then break end
    toBuffer = toBuffer + peripheral.call(loc.inv, "pushItems", MANAGER_BARREL, loc.slot, count - toBuffer)
  end
  if toBuffer > 0 then indexDirty = true end        -- pool drained via the buffer; rebuild reconciles
  local delivered = 0
  if toBuffer > 0 then
    local ok, m = pcall(manager.addItemToPlayer, MANAGER_DIR, { name = id, count = toBuffer })
    if ok then delivered = m or 0 end
  end
  flushBuffer()                                     -- return any overflow (player full) to the pool
  return delivered
end

local function resolvePlayer(q)                     -- match a query against what the player holds
  if not manager then return q end
  local ok, items = pcall(manager.getItems)         -- throws when the player is offline
  if not ok or type(items) ~= "table" then return q end
  for _, it in pairs(items) do if it.name == q then return it.name end end
  for _, it in pairs(items) do if it.name:find(q, 1, true) then return it.name end end
  return q
end

local function depositFromPlayer(id, count)         -- specific item: player -> pool
  if not manager then return 0, "no inventory manager" end
  local ok, m = pcall(manager.removeItemFromPlayer, MANAGER_DIR, { name = id, count = count })
  flushBuffer()                                     -- storeFrom flags the index dirty
  return (ok and (m or 0)) or 0
end

local function sweepPlayer()                        -- everything except hotbar/armor -> pool
  if not manager then return 0, "no inventory manager" end
  local ok, items = pcall(manager.getItems)         -- throws when the player is offline
  if not ok or type(items) ~= "table" then return 0 end
  local moved = 0
  for k, it in pairs(items) do
    local s = it.slot or k
    if type(s) == "number" and not PROTECT[s] then
      local ok, m = pcall(manager.removeItemFromPlayer, MANAGER_DIR, { fromSlot = s, count = it.count or 64 })
      if ok then moved = moved + (m or 0) end
      flushBuffer()                                 -- flush each pass so the buffer can't overflow
    end
  end
  return moved
end

local function deliverFuel(chest, amount)
  local remaining = amount
  for id in pairs(FUELS) do
    if remaining <= 0 then break end
    local e = index.items[id]
    if e then remaining = remaining - pullEntry(id, e, chest, remaining) end
  end
  return amount - remaining
end

local function deliverItem(chest, id, amount)
  local e = index.items[id]
  if not e then return 0 end
  return pullEntry(id, e, chest, amount)
end

local function shortId(id) return id:match("[^:]+$") or id end

-- idle auto-processing: keep each barrel topped up from its auto set, capped per
-- tick so one pass can't dump the whole pool. uses the index from the worker loop.
local function processStep()
  for _, typ in ipairs(PROC_TYPES) do
    local barrel = PROC_BARREL[typ]
    if barrel and peripheral.isPresent(barrel) then
      for id in pairs(AUTO[typ]) do
        local e = index.items[id]
        if e then pullEntry(id, e, barrel, PROC_CAP) end
      end
    end
  end
end

----------------------------------------------------------------- queries
local function resolve(q)
  if not q then return nil, "usage: get <id|name> [count]" end
  if index.items[q] then return q end
  local hits, exact = {}, {}
  for id in pairs(index.items) do
    if id:find(q, 1, true) then
      hits[#hits + 1] = id
      if id == q or shortId(id) == q then exact[#exact + 1] = id end
    end
  end
  if #exact == 1 then return exact[1] end       -- an exact id/name beats being a substring of longer ids
  if #hits == 1 then return hits[1] end
  if #hits == 0 then return nil, "no match for '" .. q .. "'" end
  table.sort(hits)
  local n = math.min(#hits, 6)
  return nil, "ambiguous: " .. table.concat(hits, ", ", 1, n)
end

local function search(q)
  local hits = {}
  for id, e in pairs(index.items) do
    if not q or id:find(q, 1, true) then hits[#hits + 1] = e.count .. " x " .. id end
  end
  table.sort(hits)
  if #hits == 0 then return "no matches" end
  local n = math.min(#hits, 8)
  return table.concat(hits, " | ", 1, n) .. (#hits > n and (" (+" .. (#hits - n) .. ")") or "")
end

local function resolvePeripheral(q)
  if not q then return nil end
  if peripheral.isPresent(q) and peripheral.hasType(q, "inventory") then return q end
  local hits = {}
  for _, n in ipairs(peripheral.getNames()) do
    if not SIDES[n] and peripheral.hasType(n, "inventory") and n:find(q, 1, true) then
      hits[#hits + 1] = n
    end
  end
  if #hits == 1 then return hits[1] end
  return nil
end

----------------------------------------------------------------- commands
-- count of items sitting in a process barrel (0 if absent)
local function barrelPending(barrel)
  if not (barrel and peripheral.isPresent(barrel)) then return 0 end
  local n = 0
  for _, it in pairs(peripheral.call(barrel, "list") or {}) do n = n + it.count end
  return n
end

local function gatherStats()
  local frac = index.totalSlots > 0 and index.usedSlots / index.totalSlots or 0
  local fuel = 0
  for id in pairs(FUELS) do if index.items[id] then fuel = fuel + index.items[id].count end end
  local proc = {}
  for _, typ in ipairs(PROC_TYPES) do
    local autoN = 0
    for _ in pairs(AUTO[typ]) do autoN = autoN + 1 end
    proc[typ] = { pending = barrelPending(PROC_BARREL[typ]), auto = autoN }
  end
  local arr = {}
  for id, e in pairs(index.items) do arr[#arr + 1] = { id = id:match("[^:]+$") or id, n = e.count } end
  table.sort(arr, function(a, b) return a.n > b.n end)
  local top = {}
  for i = 1, math.min(6, #arr) do top[i] = arr[i] end
  local log = {}
  for i = math.max(1, #history - 2), #history do log[#log + 1] = history[i] end
  return {
    mode      = mode,
    uptime    = math.floor(os.clock() - startClock),
    usedSlots = index.usedSlots, totalSlots = index.totalSlots,
    totalItems = index.totalItems, types = index.types,
    fracPct   = math.floor(frac * 100),
    fuel      = fuel, outOfFuel = (fuel == 0),
    proc      = proc,
    top = top, log = log,
  }
end

local STALE_SECS  = 180
local STALL_GRACE = 300       -- no %-progress for this long (while mining) => "STALL"; must exceed one layer's mine time

local function onTelem(id, t, dist)
  local prev, now = turtles[id], os.clock()
  local eta = prev and prev.eta or nil
  -- time-based stall: stamp when % last advanced, robust to how often the turtle pings
  local lastProgress = prev and prev.lastProgress or now
  if prev and prev.pct and t.pct and t.pct > prev.pct then
    local dt = now - prev.lastHeard
    if dt > 0 then local rate = (t.pct - prev.pct) / dt; if rate > 0 then eta = (100 - t.pct) / rate end end
    lastProgress = now
  end
  -- treefarm: stamp the time its harvest counter last advanced (store clock, like lastHeard)
  local lastMine = prev and prev.lastMine or nil
  if t.kind == "tree" and (t.harvests or 0) > (prev and prev.harvests or 0) then lastMine = now end
  turtles[id] = {
    id = id, kind = t.kind, label = t.label, phase = t.phase, dir = t.dir, pct = t.pct,
    fuel = t.fuel, fuelMax = t.fuelMax, pos = t.pos, last = t.last, halted = t.halted,
    harvests = t.harvests, logs = t.logs, lastMine = lastMine,
    dist = dist or (prev and prev.dist) or nil,
    lastHeard = now, eta = eta, lastProgress = lastProgress,
    alerted = prev and prev.alerted or nil, doneAlerted = prev and prev.doneAlerted or nil,
  }
end

-- a mining turtle is "stuck" if its % hasn't advanced for STALL_GRACE while it should be working
-- (treefarm sits at pct 0; halted/done turtles aren't working) so those never read stuck
local function isStuck(tr, now)
  if not (tr.pct and tr.pct > 0) then return false end
  if tr.halted or tr.phase == "done" then return false end
  return (now - (tr.lastProgress or now)) > STALL_GRACE
end

local function turtleName(tr) return tr.label or ("turtle " .. tr.id) end

local safeDist = nil   -- set at startup from tower height; nil = unknown

local function rangeState(d)
  if not d then return "?" end
  if not safeDist then return "ok" end
  if d > safeDist then return "far" end
  if d > safeDist * 0.7 then return "warn" end
  return "ok"
end

local function rangeColour(state)
  if state == "far" then return colors.red end
  if state == "warn" then return colors.orange end
  if state == "ok" then return colors.lightGray end
  return colors.gray
end

local function resolveTurtles(q)
  local ids = {}
  for id, tr in pairs(turtles) do
    if q == "all" or tostring(id) == q or (tr.label and tr.label:lower():find(q, 1, true)) then
      ids[#ids + 1] = id
    end
  end
  return ids
end

local function chatTag() return os.getComputerLabel() or "Store" end

local function alertPlayer(msg)
  logAction(msg)
  if chatBox then
    local owner = manager and select(2, pcall(manager.getOwner)) or nil
    if owner then pcall(chatBox.sendMessageToPlayer, msg, owner, chatTag())
    else pcall(chatBox.sendMessage, msg, chatTag()) end
  end
end

local function checkAlerts()
  local now = os.clock()
  for _, tr in pairs(turtles) do
    local ago = now - tr.lastHeard
    if tr.phase == "done" and not tr.doneAlerted then
      tr.doneAlerted = true; alertPlayer(turtleName(tr) .. " finished its dig")
    elseif ago > STALE_SECS and not tr.alerted and tr.phase ~= "done" then
      tr.alerted = true; alertPlayer(turtleName(tr) .. " lost contact (" .. math.floor(ago) .. "s)")
    elseif ago < STALE_SECS then
      tr.alerted = nil
    end
  end
end

local function handle(line, reply, origin)
  ensureIndex()                                     -- one rebuild only if the pool changed since last
  local args = {}
  for w in line:gmatch("%S+") do args[#args + 1] = w end
  local cmd = (args[1] or ""):lower()

  if cmd == "sort" then
    mode = "SORT"; lastSnap = nil
    local msg = "sorted " .. sortBarrel() .. " items"
    if origin == "chat" then
      if manager then msg = msg .. ", swept " .. sweepPlayer() .. " from your inventory"
      else msg = msg .. " (no manager: inventory not swept)" end
    end
    reply(msg)
  elseif cmd == "get" then
    local id, err = resolve(args[2] and args[2]:lower() or nil)
    if not id then reply(err) else
      local n = tonumber(args[3]) or 64
      if origin == "chat" and manager then
        reply("delivered " .. deliverToPlayer(id, n) .. " x " .. id .. " to your inventory")
      else
        local got, usedIO = retrieve(id, n)
        if usedIO then mode = "WAIT" end
        reply("dispensed " .. got .. " x " .. id)
      end
    end
  elseif cmd == "withdraw" then
    local id, err = resolve(args[2] and args[2]:lower() or nil)
    if not id then reply(err)
    elseif not manager then reply("no inventory manager found")
    else reply("withdrew " .. deliverToPlayer(id, tonumber(args[3]) or 64) .. " x " .. id .. " to you") end
  elseif cmd == "deposit" then
    if not manager then reply("no inventory manager found")
    elseif not args[2] or args[2]:lower() == "all" then
      reply("deposited " .. sweepPlayer() .. " items from your inventory")
    else
      local id = resolvePlayer(args[2]:lower())
      reply("deposited " .. depositFromPlayer(id, tonumber(args[3]) or 64) .. " x " .. id)
    end
  elseif cmd == "process" or cmd == "smelt" then
    -- process <smelt|cook|wash> <id> [n]   ( smelt <id> [n] is an alias for process smelt )
    -- fire-and-forget: push from the pool into the fan's input barrel; the result
    -- lands in OUT_BARREL and vacuums back to the pool. vacuum + reindex first so
    -- items just deposited into an input chest (e.g. treefarm's logs) are poolable.
    local typ, ai
    if cmd == "smelt" then typ, ai = "smelt", 2
    else typ, ai = (args[2] or ""):lower(), 3 end
    local barrel = PROC_BARREL[typ]
    if not barrel then
      reply("usage: process <smelt|cook|wash> <id> [n]")
    elseif not peripheral.isPresent(barrel) then
      reply("no " .. typ .. " barrel")
    else
      vacuumInputs(); ensureIndex()   -- pool just-deposited inputs (vacuum flags dirty) before resolving
      local id, err = resolve(args[ai] and args[ai]:lower() or nil)
      if not id then reply(err) else
        local n = tonumber(args[ai + 1]) or 64
        reply("pushed " .. deliverItem(barrel, id, n) .. " x " .. shortId(id) .. " to " .. typ)
      end
    end
  elseif cmd == "auto" then
    -- auto <type> add|remove <id>  |  auto [type]   (back-compat: auto add|remove <id> => smelt)
    local a2 = (args[2] or ""):lower()
    local typ, sub, q
    if PROC_BARREL[a2] then typ, sub, q = a2, (args[3] or ""):lower(), args[4] and args[4]:lower() or nil
    else typ, sub, q = "smelt", a2, args[3] and args[3]:lower() or nil end
    local function listType(t)
      local parts = {}
      for id in pairs(AUTO[t]) do parts[#parts + 1] = id end
      table.sort(parts)
      return #parts > 0 and table.concat(parts, ", ") or "(none)"
    end
    if sub == "add" then
      if not q then reply("usage: auto " .. typ .. " add <id>")
      else
        local id, err = resolve(q)
        if not id and q:find(":", 1, true) then id = q end   -- accept explicit id not in storage
        if id then AUTO[typ][id] = true; saveAuto(); reply("auto-" .. typ .. " += " .. id)
        else reply(err or ("no match for " .. q)) end
      end
    elseif sub == "remove" or sub == "rm" or sub == "del" then
      local target
      if q and AUTO[typ][q] then target = q
      elseif q then
        local hits = {}
        for id in pairs(AUTO[typ]) do if id:find(q, 1, true) then hits[#hits + 1] = id end end
        if #hits == 1 then target = hits[1] end
      end
      if target then AUTO[typ][target] = nil; saveAuto(); reply("auto-" .. typ .. " -= " .. target)
      else reply("no auto-" .. typ .. " entry matches '" .. tostring(q) .. "'") end
    elseif PROC_BARREL[a2] then
      reply("auto-" .. typ .. ": " .. listType(typ))
    else
      local lines = {}
      for _, t in ipairs(PROC_TYPES) do lines[#lines + 1] = t .. ": " .. listType(t) end
      reply(table.concat(lines, " | "))
    end
  elseif cmd == "mark" then
    local name = resolvePeripheral(args[2])
    local role = (args[3] or ""):lower()
    if not name then
      reply("no single inventory matches '" .. tostring(args[2]) .. "' (try invs)")
    elseif name == IO_BARREL then
      reply(IO_BARREL .. " is the I/O barrel, always both")
    elseif role ~= "input" and role ~= "output" and role ~= "storage" and role ~= "fuel" then
      reply("usage: mark <name> <input|output|storage|fuel>")
    else
      roles[name] = (role ~= "storage") and role or nil
      saveRoles(); discover()
      reply("marked " .. name .. " as " .. role)
    end
  elseif cmd == "marks" then
    local parts = { IO_BARREL .. "=both" }
    for n, r in pairs(SPECIAL_ROLE) do parts[#parts + 1] = n .. "=" .. r end
    for n, r in pairs(roles) do parts[#parts + 1] = n .. "=" .. r end
    reply(table.concat(parts, "  "))
  elseif cmd == "invs" then
    local parts = {}
    for _, n in ipairs(peripheral.getNames()) do
      if not SIDES[n] and peripheral.hasType(n, "inventory") then
        local r = (n == IO_BARREL) and "both" or SPECIAL_ROLE[n] or roles[n] or "storage"
        parts[#parts + 1] = n .. "(" .. r .. ")"
      end
    end
    reply(table.concat(parts, " "))
  elseif cmd == "fuel" then
    local name = resolvePeripheral(args[2])
    local amount = tonumber(args[3]) or 64
    if not name then
      reply("no single inventory matches '" .. tostring(args[2]) .. "' (try invs)")
    else
      reply("delivered " .. deliverFuel(name, amount) .. " fuel to " .. name)
    end
  elseif cmd == "give" then
    local name = resolvePeripheral(args[2])
    local id = args[3]
    if id and not index.items[id] then local r = resolve(id); if r then id = r end end
    local amount = tonumber(args[4]) or 64
    if not name then
      reply("no single inventory matches '" .. tostring(args[2]) .. "' (try invs)")
    elseif not id then
      reply("usage: give <chest> <id> <count>")
    else
      reply("delivered " .. deliverItem(name, id, amount) .. " " .. shortId(id) .. " to " .. name)
    end
  elseif cmd == "stats" then
    reply(textutils.serialize(gatherStats()))
  elseif cmd == "items" then
    ensureIndex()
    local arr = {}
    for id, e in pairs(index.items) do arr[#arr + 1] = { id = id, n = e.count } end
    table.sort(arr, function(a, b) return a.n > b.n end)
    for i = #arr, 201, -1 do arr[i] = nil end      -- cap payload at 200 types
    reply(textutils.serialize({
      mode = mode, usedSlots = index.usedSlots, totalSlots = index.totalSlots,
      totalItems = index.totalItems, types = index.types, list = arr,
    }))
  elseif cmd == "rtb" then
    local ids = resolveTurtles((args[2] or "all"):lower())
    for _, id in ipairs(ids) do pendingCmd[id] = "rtb" end
    reply("rtb queued for " .. #ids .. " turtle(s); applies at next check-in")
  elseif cmd == "continue" then
    local ids = resolveTurtles((args[2] or "all"):lower())
    for _, id in ipairs(ids) do pendingCmd[id] = "continue" end
    reply("continue sent to " .. #ids .. " turtle(s)")
  elseif cmd == "fleet" then
    local arr, now = {}, os.clock()
    for id, tr in pairs(turtles) do
      arr[#arr + 1] = {
        id = id, kind = tr.kind, label = tr.label, phase = tr.phase, pct = tr.pct, fuel = tr.fuel, fuelMax = tr.fuelMax,
        pos = tr.pos, last = tr.last, eta = tr.eta, halted = tr.halted,
        stuck = isStuck(tr, now), ago = math.floor(now - tr.lastHeard),
        logs = tr.logs, mineAgo = tr.lastMine and math.floor(now - tr.lastMine) or nil,
        dist = tr.dist, rng = rangeState(tr.dist),
      }
    end
    table.sort(arr, function(a, b) return (a.label or tostring(a.id)) < (b.label or tostring(b.id)) end)
    reply(textutils.serialize(arr))
  elseif cmd == "mons" or cmd == "mon" then
    if args[2] then
      local target = args[2]
      local pg = args[3] and args[3]:lower() or nil
      if pg == "auto" then
        monAssign[target] = nil; saveMons(); reply("cleared assignment for " .. target)
      elseif target:lower() == "auto" then
        monAssign = {}; saveMons(); reply("all monitors back to auto (size-based)")
      elseif pg == "overview" or pg == "stats" or pg == "turtles" or pg == "quarry" or pg == "store" or pg == "blank" then
        if pg == "quarry" then pg = "turtles" end
        if pg == "stats" then pg = "overview" end
        monAssign[target] = pg; saveMons(); reply(target .. " -> " .. pg)
      else
        reply("usage: mon <name> <overview|turtles|store|blank|auto>  |  mon auto  (reset all)")
      end
    else
      local parts = {}
      for _, mon in ipairs(monitors) do
        local nm = peripheral.getName(mon)
        local w, h = mon.getSize()
        parts[#parts + 1] = nm .. " " .. w .. "x" .. h .. " [" .. (monAssign[nm] or "auto") .. "]"
      end
      reply(#monitors .. " monitors: " .. table.concat(parts, " | "))
    end
  elseif cmd == "find" then
    reply(search(args[2] and args[2]:lower() or nil))
  elseif cmd == "list" then
    reply(("%d items, %d types, %d/%d slots used")
      :format(index.totalItems, index.types, index.usedSlots, index.totalSlots))
  elseif cmd == "reboot" then
    local what = (args[2] or "store"):lower()
    if what == "store" then
      reply("rebooting store")
      logAction(line)
      sleep(0.5)               -- let the reply flush to chat/comms before the process dies
      os.reboot()
    elseif what == "fleet" or what == "stations" or what == "all" then
      local out = {}
      if what == "fleet" or what == "all" then           -- turtles: latched, applied at next check-in
        local ids = resolveTurtles("all")
        for _, id in ipairs(ids) do pendingCmd[id] = "reboot" end
        out[#out + 1] = #ids .. " turtle(s)"
      end
      if what == "stations" or what == "all" then          -- gps towers + boiler: gps-proto broadcast
        for _ = 1, 3 do comms.send("all", { type = "reboot" }, GPS_PROTO); sleep(0.15) end
        out[#out + 1] = "towers+boiler"
      end
      logAction(line)
      reply("reboot sent to " .. table.concat(out, " + ") .. " (reboot the store by hand)")
    else
      reply("usage: reboot [store|fleet|stations|all]")
    end
  elseif cmd == "help" then
    reply("sort | get <id> [n] | withdraw <id> [n] | deposit [id|all] [n] | process <smelt|cook|wash> <id> [n] | smelt <id> [n] | rtb [id|all] | continue [id|all] | auto <type> add|remove <id> | fuel <name> [n] | find <text> | list | mark <name> <input|output|storage|fuel> | marks | invs | reboot [store|fleet|stations|all]")
  else
    reply("unknown command: " .. cmd)
  end
  logAction(line)
end

----------------------------------------------------------------- auto-sort
local function snapshot()
  local list = peripheral.call(IO_BARREL, "list") or {}
  if next(list) == nil then return "" end           -- idle steady state: skip the sort/concat
  local parts = {}
  for s, it in pairs(list) do parts[#parts + 1] = s .. it.name .. it.count end
  table.sort(parts)
  return table.concat(parts, "|")
end

local function autoSortCheck()
  local s = snapshot()
  if mode == "WAIT" then
    if s == "" then mode = "SORT" end
    lastSnap = s
  elseif s == "" then
    lastSnap = s
  elseif s == lastSnap then
    logAction("auto-sorted " .. sortBarrel())
    lastSnap = nil
  else
    lastSnap = s
  end
end

----------------------------------------------------------------- overview
-- fan-barrel backlog: list each present barrel once per render pass, not per monitor
local function refreshProc()
  for _, typ in ipairs(PROC_TYPES) do procPending[typ] = barrelPending(PROC_BARREL[typ]) end
  procFresh = true
end

local function drawOverview(mon)
  if not mon then return end
  if not procFresh then refreshProc() end
  mon.setTextScale(0.5)
  mon.setBackgroundColor(colors.black)
  mon.clear()
  local w, h = mon.getSize()
  local name = peripheral.getName(mon)
  local reg = { kind = "overview", buttons = {}, draw = drawOverview }
  touchRegions[name] = reg

  local function txt(x, y, s, fg, bg)
    if y < 1 or y > h then return end
    s = #s > w - x + 1 and s:sub(1, w - x + 1) or s
    mon.setCursorPos(x, y)
    mon.setTextColor(fg or colors.white)
    mon.setBackgroundColor(bg or colors.black)
    mon.write(s)
    mon.setBackgroundColor(colors.black)
  end
  local function strip(y, bg)
    if y < 1 or y > h then return end
    mon.setCursorPos(1, y); mon.setBackgroundColor(bg)
    mon.write(string.rep(" ", w)); mon.setBackgroundColor(colors.black)
  end
  local function bar(x, y, bw, frac, fill, track)
    if y < 1 or y > h or bw < 1 then return end
    frac = frac < 0 and 0 or (frac > 1 and 1 or frac)
    local f = math.floor(frac * bw + 0.5)
    mon.setCursorPos(x, y)
    mon.setBackgroundColor(fill); mon.write(string.rep(" ", f))
    mon.setBackgroundColor(track); mon.write(string.rep(" ", bw - f))
    mon.setBackgroundColor(colors.black)
  end
  local function clip(s, n) return #s > n and s:sub(1, n) or s end
  local function right(x2, y, s, fg) txt(x2 - #s + 1, y, s, fg) end

  -- title bar
  strip(1, colors.blue)
  txt(2, 1, "OVERVIEW", colors.white, colors.blue)
  local up = math.floor(os.clock() - startClock)
  local clk = ("%d:%02d"):format(math.floor(up / 60), up % 60)
  txt(math.floor((w - #clk) / 2) + 1, 1, clk, colors.lightBlue, colors.blue)
  local badge = mode == "SORT" and " SORT " or " WAIT "
  txt(w - #badge + 1, 1, badge, colors.black, mode == "SORT" and colors.lime or colors.orange)

  -- storage
  local frac = index.totalSlots > 0 and index.usedSlots / index.totalSlots or 0
  local fcol = frac > 0.9 and colors.red or (frac > 0.7 and colors.yellow or colors.lime)
  txt(1, 3, "STORAGE", colors.cyan)
  right(w, 3, index.usedSlots .. "/" .. index.totalSlots, colors.lightGray)
  bar(1, 4, w, frac, fcol, colors.gray)
  txt(1, 5, ("%d items   %d types   %d%%")
    :format(index.totalItems, index.types, math.floor(frac * 100)), colors.white)

  -- fuel (deliverable coal/charcoal in the pool, for refueling turtles)
  local fuel = 0
  for id in pairs(FUELS) do if index.items[id] then fuel = fuel + index.items[id].count end end
  txt(1, 6, "FUEL", colors.cyan)
  if fuel == 0 then
    right(w, 6, "NONE", colors.red)
    bar(1, 7, w, 1, colors.red, colors.gray)
  else
    right(w, 6, tostring(fuel), colors.orange)
    bar(1, 7, w, math.min(fuel / 256, 1), colors.orange, colors.gray)
  end

  -- fleet summary
  local tTotal, tActive, tHeld, fnow = 0, 0, 0, os.clock()
  for _, tr in pairs(turtles) do
    tTotal = tTotal + 1
    if tr.halted then tHeld = tHeld + 1 end
    if (fnow - tr.lastHeard) < STALE_SECS and tr.phase ~= "done" then tActive = tActive + 1 end
  end
  txt(1, 8, "FLEET", colors.cyan)
  right(w, 8, tTotal .. " up  " .. tActive .. " active" .. (tHeld > 0 and ("  " .. tHeld .. " held") or ""), colors.lightGray)

  -- size the bottom block (processing + log), trimming so it never eats rows 1-8
  local anyProc = false
  for _, typ in ipairs(PROC_TYPES) do
    if PROC_BARREL[typ] and peripheral.isPresent(PROC_BARREL[typ]) then anyProc = true end
  end
  local procRows = anyProc and 2 or 0
  local logLines = math.min(#history, 3)
  local function bh() return procRows + (logLines > 0 and logLines + 1 or 0) end
  while bh() > 0 and (h - bh()) < 8 do
    if logLines > 0 then logLines = logLines - 1
    elseif procRows > 0 then procRows = 0
    else break end
  end
  local fy0 = h - bh() + 1
  local topEnd = h - bh()

  -- top items bar chart, rows 9..topEnd
  if topEnd >= 9 then
    txt(1, 9, "TOP ITEMS", colors.cyan)
    local arr = {}
    for id, e in pairs(index.items) do arr[#arr + 1] = { id = id, n = e.count } end
    table.sort(arr, function(a, b) return a.n > b.n end)
    local maxN = arr[1] and arr[1].n or 1
    local nameW = math.max(6, math.floor(w * 0.4))
    local barW = w - nameW - 9
    local row = 10
    for _, it in ipairs(arr) do
      if row > topEnd then break end
      txt(1, row, clip(it.id:match("[^:]+$") or it.id, nameW), colors.white)
      if barW > 2 then bar(nameW + 1, row, barW, it.n / maxN, colors.cyan, colors.gray) end
      right(w, row, tostring(it.n), colors.yellow)
      row = row + 1
    end
  end

  -- processing (per-line backlog sitting in each fan's input barrel)
  if procRows > 0 then
    txt(1, fy0, "PROCESSING", colors.cyan)
    local parts = {}
    for _, typ in ipairs(PROC_TYPES) do
      local barrel = PROC_BARREL[typ]
      if barrel and peripheral.isPresent(barrel) then
        parts[#parts + 1] = ("%s %d"):format(typ, procPending[typ] or 0)
      end
    end
    txt(1, fy0 + 1, clip(table.concat(parts, "   "), w), colors.lightGray)
  end

  -- activity log
  if logLines > 0 then
    local ly = fy0 + procRows
    txt(1, ly, "ACTIVITY", colors.cyan)
    for i = 1, logLines do
      local msg = history[#history - logLines + i]
      txt(1, ly + i, clip(msg, w), i == logLines and colors.white or colors.lightGray)
    end
  end
end

----------------------------------------------------------------- quarry tracker
local function fmtAgo(s)
  s = math.floor(s)
  if s < 15 then return "now" end
  if s < 90 then return s .. "s" end
  return math.floor(s / 60) .. "m"
end
local function fmtEta(s)
  if not s or s <= 0 then return "?" end
  if s < 90 then return math.floor(s) .. "s" end
  if s < 5400 then return math.floor(s / 60) .. "m" end
  return string.format("%.1fh", s / 3600)
end

local function drawQuarry(mon)
  if not mon then return end
  mon.setTextScale(0.5)
  mon.setBackgroundColor(colors.black); mon.clear()
  local w, h = mon.getSize()
  local name = peripheral.getName(mon)
  local reg = { kind = "turtles", rows = {}, buttons = {}, draw = drawQuarry }
  touchRegions[name] = reg
  local function txt(x, y, s, fg, bg)
    if y < 1 or y > h then return end
    s = #s > w - x + 1 and s:sub(1, w - x + 1) or s
    mon.setCursorPos(x, y); mon.setTextColor(fg or colors.white)
    mon.setBackgroundColor(bg or colors.black); mon.write(s); mon.setBackgroundColor(colors.black)
  end
  local function bar(x, y, bw, frac, fill)
    frac = frac < 0 and 0 or (frac > 1 and 1 or frac)
    local f = math.floor(frac * bw + 0.5)
    mon.setCursorPos(x, y); mon.setBackgroundColor(fill); mon.write(string.rep(" ", f))
    mon.setBackgroundColor(colors.gray); mon.write(string.rep(" ", bw - f)); mon.setBackgroundColor(colors.black)
  end
  local function fillRow(y, bg)
    if y < 1 or y > h then return end
    mon.setCursorPos(1, y); mon.setBackgroundColor(bg); mon.write(string.rep(" ", w)); mon.setBackgroundColor(colors.black)
  end

  mon.setCursorPos(1, 1); mon.setBackgroundColor(colors.blue); mon.setTextColor(colors.white)
  mon.write(string.rep(" ", w)); mon.setCursorPos(2, 1); mon.write("TURTLES")
  local arr, now = {}, os.clock()
  for _, tr in pairs(turtles) do arr[#arr + 1] = tr end
  table.sort(arr, function(a, b) return (a.label or tostring(a.id)) < (b.label or tostring(b.id)) end)
  txt(w - #tostring(#arr), 1, tostring(#arr), colors.lightBlue, colors.blue)
  mon.setBackgroundColor(colors.black)

  local by = h
  local function button(bx, label, bg, act)
    txt(bx, by, label, colors.black, bg)
    reg.buttons[#reg.buttons + 1] = { x1 = bx, x2 = bx + #label - 1, y = by, act = act }
    return bx + #label + 1
  end
  local bbx = 1
  bbx = button(bbx, "[RTB]", colors.red, "rtb")
  bbx = button(bbx, "[CONT]", colors.green, "cont")
  bbx = button(bbx, "[RTB ALL]", colors.orange, "rtball")

  if #arr == 0 then txt(1, 3, "no turtles checked in yet", colors.gray); return end

  local maxRow = h - 2
  local row = 3
  for _, tr in ipairs(arr) do
    if row > maxRow then break end
    local on = (monSel[name] == tr.id)
    local rbg = on and colors.gray or nil
    if on then fillRow(row, colors.gray) end
    reg.rows[row] = tr.id
    local ago = now - tr.lastHeard
    local stale = ago > STALE_SECS
    local stuck = isStuck(tr, now)
    local statusCol, statusTxt
    if tr.err then statusCol, statusTxt = colors.red, "ERR " .. tostring(tr.err):sub(1, 12)
    elseif tr.halted then statusCol, statusTxt = colors.cyan, "HALTED"
    elseif tr.phase == "done" then statusCol, statusTxt = colors.lime, "DONE"
    elseif stale then statusCol, statusTxt = colors.red, "STALE " .. fmtAgo(ago)
    elseif stuck then statusCol, statusTxt = colors.orange, "STALL"
    else statusCol, statusTxt = (ago < 15 and colors.lime or colors.lightGray), fmtAgo(ago) end

    local tree = tr.kind == "tree"
    local nm = tr.label or ("t" .. tr.id)
    txt(1, row, nm, colors.white, rbg)
    txt(w - #statusTxt + 1, row, statusTxt, statusCol, rbg)
    local bx = #nm + 2
    if not tree then                                 -- mining progress %; trees have none
      local pctTxt = (tr.pct or 0) .. "%"
      txt(bx, row, pctTxt, colors.yellow, rbg)
      bx = bx + #pctTxt + 1
    end
    if tr.dist then
      local dTxt = math.floor(tr.dist) .. "m"
      txt(bx, row, dTxt, rangeColour(rangeState(tr.dist)), rbg)
      bx = bx + #dTxt + 1
    end
    if not tree and w - bx - #statusTxt - 1 > 4 then
      bar(bx, row, w - bx - #statusTxt - 1, (tr.pct or 0) / 100, colors.green)
    end
    row = row + 1

    if row <= maxRow then
      if on then fillRow(row, colors.gray) end
      reg.rows[row] = tr.id
      txt(2, row, tr.phase or "?", colors.lightGray, rbg)
      local dx = 2 + #(tr.phase or "?") + 1
      if tree then                                   -- last harvest stats instead of fuel/eta
        local cut = tr.lastMine and fmtAgo(now - tr.lastMine) or "-"
        txt(dx, row, ("logs %d   cut %s"):format(tr.logs or 0, cut), colors.lightGray, rbg)
      else
        local last = tr.last and (tr.last:match("[^:]+$") or tr.last) or "-"
        local ffrac = (tr.fuelMax and tr.fuelMax > 0) and (tr.fuel or 0) / tr.fuelMax or 0
        local fcol = ffrac > 0.5 and colors.lime or (ffrac > 0.2 and colors.orange or colors.red)
        bar(dx, row, 6, ffrac, fcol)
        txt(dx + 7, row, ("%d%% eta %s %s"):format(math.floor(ffrac * 100), fmtEta(tr.eta), last), colors.lightGray, rbg)
      end
      row = row + 1
    end
  end
end

----------------------------------------------------------------- store console
local function drawStore(mon)
  if not mon then return end
  mon.setTextScale(0.5)
  mon.setBackgroundColor(colors.black); mon.clear()
  local w, h = mon.getSize()
  local name = peripheral.getName(mon)
  local st = storeState(name)
  local reg = { kind = "store", items = {}, buttons = {}, draw = drawStore }
  touchRegions[name] = reg
  local function txt(x, y, s, fg, bg)
    if y < 1 or y > h then return end
    s = #s > w - x + 1 and s:sub(1, w - x + 1) or s
    mon.setCursorPos(x, y); mon.setTextColor(fg or colors.white)
    mon.setBackgroundColor(bg or colors.black); mon.write(s); mon.setBackgroundColor(colors.black)
  end
  local function fillRow(y, bg)
    if y < 1 or y > h then return end
    mon.setCursorPos(1, y); mon.setBackgroundColor(bg); mon.write(string.rep(" ", w)); mon.setBackgroundColor(colors.black)
  end
  local function btn(x, y, label, bg, act, val)
    txt(x, y, label, colors.black, bg)
    reg.buttons[#reg.buttons + 1] = { x1 = x, x2 = x + #label - 1, y = y, act = act, val = val }
    return x + #label + 1
  end
  local function short(id) return id:match("[^:]+$") or id end

  local arr = {}
  for id, e in pairs(index.items) do arr[#arr + 1] = { id = id, n = e.count } end
  table.sort(arr, STORE_SORTS[st.sortMode].cmp)
  if not st.selId and arr[1] then st.selId = arr[1].id end

  local LIST_TOP = 4
  local listBottom = h - 4
  local rows = math.max(0, listBottom - LIST_TOP + 1)
  st.rows = rows
  st.maxScroll = math.max(0, #arr - rows)
  st.scroll = math.max(0, math.min(st.scroll, st.maxScroll))

  mon.setCursorPos(1, 1); mon.setBackgroundColor(colors.blue); mon.setTextColor(colors.white)
  mon.write(string.rep(" ", w)); mon.setCursorPos(2, 1); mon.write("STORE")
  txt(w - #tostring(#arr), 1, tostring(#arr), colors.lightBlue, colors.blue)
  mon.setBackgroundColor(colors.black)

  local pct = index.totalSlots > 0 and math.floor(index.usedSlots / index.totalSlots * 100) or 0
  txt(1, 2, ("%d/%d  %d%%"):format(index.usedSlots, index.totalSlots, pct), colors.lightGray)
  btn(w - #(" " .. STORE_SORTS[st.sortMode].key .. " ") + 1, 2, " " .. STORE_SORTS[st.sortMode].key .. " ", colors.cyan, "sortcycle")
  txt(1, 3, string.rep("-", w), colors.gray)

  for i = 1, rows do
    local idx = st.scroll + i
    local it = arr[idx]
    local y = LIST_TOP + i - 1
    if it then
      local on = (it.id == st.selId)
      if on then fillRow(y, colors.gray) end
      local cnt = tostring(it.n)
      txt(1, y, short(it.id), on and colors.white or colors.lightGray, on and colors.gray or nil)
      txt(w - #cnt + 1, y, cnt, colors.yellow, on and colors.gray or nil)
      reg.items[y] = it.id
    end
  end
  txt(1, listBottom + 1, string.rep("-", w), colors.gray)

  local selE = st.selId and index.items[st.selId]
  txt(1, h - 3, selE and ("> " .. short(st.selId) .. " (" .. selE.count .. ")") or "> -", colors.white)

  txt(1, h - 2, "amt", colors.cyan)
  local ax = 5
  for _, a in ipairs(STORE_AMOUNTS) do
    ax = btn(ax, h - 2, " " .. a .. " ", a == st.amt and colors.lime or colors.gray, "amt", a)
  end

  local dx = btn(1, h - 1, "[TO DUZO]", st.dest == "duzo" and colors.lime or colors.gray, "dest", "duzo")
  btn(dx, h - 1, "[TO OUTPUT]", st.dest == "output" and colors.lime or colors.gray, "dest", "output")
  btn(w - 6, h - 1, " ^ ", colors.lightBlue, "scrollup")
  btn(w - 2, h - 1, " v ", colors.lightBlue, "scrolldn")

  if st.procPick then
    local bx = btn(1, h, "[SMELT]", colors.orange, "proc", "smelt")
    bx = btn(bx, h, "[COOK]", colors.red, "proc", "cook")
    bx = btn(bx, h, "[WASH]", colors.lightBlue, "proc", "wash")
    btn(bx, h, "[X]", colors.gray, "proccancel")
  else
    local bx = btn(1, h, "[GET]", colors.green, "get")
    bx = btn(bx, h, "[PROCESS]", colors.orange, "procopen")
    btn(bx, h, "[DEPOSIT]", colors.lightBlue, "deposit")
  end
end

----------------------------------------------------------------- monitor manager
local PAGES = { drawOverview, drawQuarry, drawStore }   -- biggest monitor first
local PAGEMAP = {
  overview = drawOverview, stats = drawOverview,
  turtles = drawQuarry, quarry = drawQuarry,
  store = drawStore,
}
local CYCLE = 6
local cyclePage, lastCycle = 1, 0

local function blankMon(mon) mon.setBackgroundColor(colors.black); mon.clear(); touchRegions[peripheral.getName(mon)] = nil end

local lastPaint = {}   -- monitor name -> { fn, rev } at its last paint

-- overview/quarry show a live clock / "ago" so they repaint every tick; the store page is
-- static between index changes, so skip its repaint when nothing it shows has changed.
local function paintMon(mon, fn)
  local name = peripheral.getName(mon)
  local lp = lastPaint[name]
  if not fn then
    if lp and lp.fn == "blank" then return end
    blankMon(mon); lastPaint[name] = { fn = "blank", rev = uiRev }; return
  end
  local timed = (fn == drawOverview or fn == drawQuarry)
  if not timed and lp and lp.fn == fn and lp.rev == uiRev then return end
  fn(mon)
  lastPaint[name] = { fn = fn, rev = uiRev }
end

local function renderMonitors()
  local n = #monitors
  if n == 0 then return end
  procFresh = false
  if next(monAssign) ~= nil then
    for _, mon in ipairs(monitors) do
      paintMon(mon, PAGEMAP[monAssign[peripheral.getName(mon)]])
    end
  elseif n >= #PAGES then
    for i, mon in ipairs(monitors) do
      paintMon(mon, PAGES[i])
    end
  else
    local now = os.clock()
    if now - lastCycle > CYCLE then cyclePage = cyclePage % #PAGES + 1; lastCycle = now end
    for _, mon in ipairs(monitors) do paintMon(mon, PAGES[cyclePage]) end
  end
end

----------------------------------------------------------------- loops
local function enqueue(line)
  cmdQueue[#cmdQueue + 1] = { line = line, reply = function(s) end, origin = "touch" }
end

local function storeGet(name)
  local st = monStore[name]
  if not (st and st.selId) then return end
  if st.dest == "duzo" then enqueue("withdraw " .. st.selId .. " " .. st.amt)
  else enqueue("get " .. st.selId .. " " .. st.amt) end
end

local function storeProcess(name, typ)
  local st = monStore[name]
  if st and st.selId then enqueue("process " .. typ .. " " .. st.selId .. " " .. st.amt) end
end

local function monitorTouchLoop()
  while true do
    local _, side, x, y = os.pullEvent("monitor_touch")
    local reg = touchRegions[side]
    if reg then
      local hit
      for _, b in ipairs(reg.buttons) do
        if y == b.y and x >= b.x1 and x <= b.x2 then hit = b; break end
      end
      if reg.kind == "turtles" then
        if hit then
          if hit.act == "rtb" then if monSel[side] then enqueue("rtb " .. monSel[side]) end
          elseif hit.act == "cont" then if monSel[side] then enqueue("continue " .. monSel[side]) end
          elseif hit.act == "rtball" then enqueue("rtb all") end
        elseif reg.rows and reg.rows[y] then monSel[side] = reg.rows[y] end
      elseif reg.kind == "store" then
        local st = storeState(side)
        if hit then
          if hit.act == "amt" then st.amt = hit.val
          elseif hit.act == "dest" then st.dest = hit.val
          elseif hit.act == "sortcycle" then st.sortMode = st.sortMode % #STORE_SORTS + 1
          -- scroll is clamped to maxScroll by the trailing reg.draw, not here
          elseif hit.act == "scrollup" then st.scroll = math.max(0, st.scroll - (st.rows or 1))
          elseif hit.act == "scrolldn" then st.scroll = st.scroll + (st.rows or 1)
          elseif hit.act == "get" then storeGet(side)
          elseif hit.act == "procopen" then st.procPick = true
          elseif hit.act == "proccancel" then st.procPick = false
          elseif hit.act == "proc" then storeProcess(side, hit.val); st.procPick = false
          elseif hit.act == "deposit" then enqueue("deposit all") end
        elseif reg.items and reg.items[y] then st.selId = reg.items[y] end
      end
      if reg.draw then reg.draw(peripheral.wrap(side)) end
    end
  end
end

local function terminalLoop()
  while true do
    write("> ")
    local line = read()
    if line and #line > 0 then
      cmdQueue[#cmdQueue + 1] = { line = line, reply = function(s) print(s) end, origin = "terminal" }
    end
  end
end

local function chatLoop()
  while true do
    local _, user, msg, uuid, hidden = os.pullEvent("chat")
    if hidden then
      cmdQueue[#cmdQueue + 1] = { line = msg, reply = function(s)
        if chatBox then pcall(chatBox.sendMessageToPlayer, s, user, chatTag()) end
      end, origin = "chat" }
    end
  end
end

local function workerLoop()
  buildIndex()
  local lastProc, lastSort, lastDash, lastVac, lastAlert, lastIdx, lastFull =
    0, 0, 0, 0, 0, 0, 0
  while true do
    while #cmdQueue > 0 do
      local c = table.remove(cmdQueue, 1)
      handle(c.line, c.reply, c.origin)
    end
    local now = os.clock()
    if now - lastVac   > 1  then vacuumInputs();   lastVac   = now end   -- inputs/OUT_BARREL -> pool
    if now - lastSort  > 1  then autoSortCheck();  lastSort  = now end
    if now - lastFull  > 30 then indexDirty = true; lastFull = now end   -- periodic drift heal
    if now - lastIdx   > 1  then ensureIndex();    lastIdx   = now end   -- rebuild <=1/s, only if changed
    if now - lastProc  > 3  then processStep();    lastProc  = now end   -- uses the fresh index above
    if now - lastAlert > 5  then checkAlerts();    lastAlert = now end
    if now - lastDash  > 1  then renderMonitors(); lastDash  = now end
    if #cmdQueue == 0 then sleep(0.3) else sleep(0) end  -- handle commands that landed mid-tick promptly
  end
end

local function openLinks()
  local r = comms.open({ freq = RADIO_FREQ, proto = STORE_PROTOCOL })
  comms.listenAs(STORE_HOSTNAME)
  local range = TOWER_RANGE
  if range <= 0 and r.name then
    local ok, h = pcall(peripheral.call, r.name, "getHeight")
    if ok and type(h) == "number" then range = math.min(h * 128, 3072) end
  end
  if range > 0 then safeDist = range * SAFE_FRAC end
  local t = comms.transports()
  return #t > 0 and table.concat(t, "+") or nil
end

local function commsLoop()
  while true do
    local m = comms.receive(STORE_PROTOCOL)
    if m then
      local msg = m.body
      if type(msg) == "table" and msg.type == "telem" then
        onTelem(m.from, msg, m.dist)
        local c = pendingCmd[m.from]; pendingCmd[m.from] = nil
        comms.send(m.from, c or "ok", STORE_PROTOCOL)
      elseif type(msg) == "table" and msg.type == "alert" then
        alertPlayer((msg.label or ("turtle " .. m.from)) .. ": " .. tostring(msg.msg))
        local tr = turtles[m.from]
        if tr then tr.err = msg.msg; tr.lastHeard = os.clock() end
        comms.send(m.from, "ok", STORE_PROTOCOL)
      elseif type(msg) == "string" then
        local from = m.from
        cmdQueue[#cmdQueue + 1] = { line = msg, reply = function(s)
          comms.send(from, s, STORE_PROTOCOL)
        end, origin = "remote" }
      end
    end
  end
end

----------------------------------------------------------------- config (first boot)
local function listNetInvs()
  local out = {}
  for _, n in ipairs(peripheral.getNames()) do
    if not SIDES[n] and peripheral.hasType(n, "inventory") then out[#out + 1] = n end
  end
  return out
end

local function askField(label, required)
  while true do
    write(label .. ": ")
    local s = (read() or ""):gsub("^%s*(.-)%s*$", "%1")
    if s ~= "" or not required then return s end
    print("  required")
  end
end

local function loadOrAskCfg()
  if fs.exists(CFG_FILE) then
    local f = fs.open(CFG_FILE, "r"); local t = textutils.unserialize(f.readAll()); f.close()
    if type(t) == "table" and type(t.io) == "string" and t.io ~= "" then
      IO_BARREL      = t.io
      MANAGER_BARREL = t.manager or ""
      MANAGER_DIR    = t.managerDir or "up"
      SMELT_BARREL   = t.smelt or ""
      COOK_BARREL    = t.cook or ""
      WASH_BARREL    = t.wash or ""
      OUT_BARREL     = t.out or ""
      applyProcTables()
      return
    end
  end
  print("store first boot - name the barrels (wired-modem names).")
  local invs = listNetInvs()
  if #invs > 0 then
    print("inventories on the network:")
    for _, n in ipairs(invs) do print("  " .. n) end
  else
    print("(no networked inventories seen - check the modems)")
  end
  print("blank = none/disabled; the I/O barrel is required.")
  IO_BARREL      = askField("I/O barrel", true)
  MANAGER_BARREL = askField("manager buffer barrel (blank = no manager)", false)
  MANAGER_DIR    = askField("manager face [up]", false)
  if MANAGER_DIR == "" then MANAGER_DIR = "up" end
  SMELT_BARREL   = askField("smelt barrel - lava fan (blank = none)", false)
  COOK_BARREL    = askField("cook barrel - fire fan (blank = none)", false)
  WASH_BARREL    = askField("wash barrel - water fan (blank = none)", false)
  OUT_BARREL     = askField("fan output barrel (blank = none)", false)
  local f = fs.open(CFG_FILE, "w")
  f.write(textutils.serialize({
    io = IO_BARREL, manager = MANAGER_BARREL, managerDir = MANAGER_DIR,
    smelt = SMELT_BARREL, cook = COOK_BARREL, wash = WASH_BARREL, out = OUT_BARREL,
  }))
  f.close()
  applyProcTables()
  print("saved to " .. CFG_FILE .. "  (run 'store reset' to re-enter)")
end

----------------------------------------------------------------- main
local function main()
  if args[1] == "reset" and fs.exists(CFG_FILE) then fs.delete(CFG_FILE) end
  loadOrAskCfg()
  loadRoles()
  loadAuto()
  loadMons()
  discover()
  if SIDES[IO_BARREL] then
    print("IO_BARREL is '" .. IO_BARREL .. "', a block touching the computer.")
    print("It must be on the wired network (give it a modem), not attached directly.")
    return
  end
  if not peripheral.isPresent(IO_BARREL) then
    print("I/O barrel '" .. IO_BARREL .. "' not found. Inventories on the network:")
    for _, n in ipairs(peripheral.getNames()) do
      if peripheral.hasType(n, "inventory") and not SIDES[n] then print("  " .. n) end
    end
    print("Run 'store reset' to re-enter the barrel names.")
    return
  end
  if #skipped > 0 then
    print("WARNING: ignoring inventories attached directly to the computer")
    print("(they can't transfer over the network - give each a wired modem):")
    for _, n in ipairs(skipped) do print("  " .. n) end
  end
  mode = (snapshot() == "") and "SORT" or "WAIT"   -- workerLoop builds the index on entry
  local link = openLinks()
  local nproc = 0
  for _, typ in ipairs(PROC_TYPES) do
    if PROC_BARREL[typ] and peripheral.isPresent(PROC_BARREL[typ]) then nproc = nproc + 1 end
  end
  print(("store ready: %d storage, %d in, %d out, %d fuel, %d proc barrels, chat=%s, monitors=%d, link=%s, manager=%s")
    :format(#storage, #inputs, #outputs, #fuels, nproc,
            chatBox and "y" or "n", #monitors, link or "none", manager and "y" or "n"))
  local loops = { terminalLoop, chatLoop, workerLoop, monitorTouchLoop }
  if link then loops[#loops + 1] = commsLoop end
  parallel.waitForAny(table.unpack(loops))
end

main()
