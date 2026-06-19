-- startup  --  universal boot for every fleet device. Pulls the latest code from GitHub
-- (see update.lua), then launches this device's program based on device.cfg. Deploy this
-- file (with update.lua + comms.lua) as `startup` on EVERY device; it asks the device's
-- role once on first boot and remembers it in device.cfg.
--
--   role    program launched
--   ----    ----------------
--   store   store.lua + gpshost.lua (cohost) in parallel; store auto-restarts on exit
--   tower   gpshost.lua                       (standalone gps tower)
--   quarry  quarry2.lua
--   tree    treefarm.lua
--   wheat   wheatfarm.lua
--   crafter crafter.lua
--   boiler  boilerkeeper.lua
--   pad     storepad.lua
--   ship    shipnav.lua                       (airship XYZ autopilot; prompts relays -> shipnav.cfg)
--   map     fleetmap.lua                      (fleet map on an advanced monitor)
--
--   startup reset   re-ask the role (wipes device.cfg)
--
-- store role: set gpshost.state first (run `gpshost` once by hand) so the co-hosted gps
-- host does not sit on its position prompt while the store's terminal is also live.
--
-- If a previous update was interrupted mid-swap a core file may be missing; we restore it
-- from its .bak before doing anything. (If `startup` itself is ever destroyed, re-wget it.)

local CFG = "device.cfg"

local ROLES = {
  store  = { store = true },
  tower  = { run = "gpshost.lua" },
  quarry = { run = "quarry2.lua" },
  tree   = { run = "treefarm.lua" },
  wheat  = { run = "wheatfarm.lua" },
  crafter = { run = "crafter.lua" },
  boiler = { run = "boilerkeeper.lua" },
  pad    = { run = "storepad.lua" },
  ship   = { run = "shipnav.lua" },
  map    = { run = "fleetmap.lua" },
}

local function empty(path)
  local f = fs.open(path, "r"); if not f then return true end
  local d = f.readAll(); f.close()
  return (not d) or #d == 0
end

local function heal(name)
  if (not fs.exists(name) or empty(name)) and fs.exists(name .. ".bak") then
    if fs.exists(name) then fs.delete(name) end
    fs.move(name .. ".bak", name)
    print("startup: restored " .. name .. " from backup")
  end
end

local args = { ... }
if args[1] == "reset" and fs.exists(CFG) then fs.delete(CFG) end

heal("update.lua"); heal("comms.lua")

local function loadCfg()
  if not fs.exists(CFG) then return nil end
  local f = fs.open(CFG, "r"); local t = textutils.unserialize(f.readAll()); f.close()
  if type(t) == "table" and t.role and ROLES[t.role] then return t end
  return nil
end

local cfg = loadCfg()
if not cfg then
  local names = {}
  for r in pairs(ROLES) do names[#names + 1] = r end
  table.sort(names)
  print("device role? (" .. table.concat(names, " / ") .. ")")
  local role
  while not (role and ROLES[role]) do write("> "); role = read() end
  cfg = { role = role }
  local f = fs.open(CFG, "w"); f.write(textutils.serialize(cfg)); f.close()
end

-- pull latest code (best effort: a network failure never blocks boot)
if fs.exists("update.lua") then pcall(shell.run, "update.lua") end

-- the just-pulled entry program could have been mid-swap; heal it too
local role = ROLES[cfg.role]
if role.store then heal("store.lua"); heal("gpshost.lua") else heal(role.run) end

if role.store then
  parallel.waitForAny(
    function() while true do shell.run("store.lua"); sleep(3) end end,           -- restart store on exit so a misconfig can't take gps down with it
    function() while true do shell.run("gpshost.lua", "cohost"); sleep(3) end end
  )
else
  shell.run(role.run)
end
