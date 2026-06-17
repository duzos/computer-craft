-- gpsrange.lua  PHASE 0 GPS range/accuracy probe for the fleet GPS rollout.
-- Deploy to a QUARRY turtle (it pulls this file from GitHub with the rest of the fleet).
-- The turtle digs straight DOWN one block at a time and, at every depth, attempts several
-- GPS fixes via gps2.locate, logging fix availability + accuracy to gpsrange.csv. This
-- answers the one unknown blocking world-coord navigation: HOW DEEP does a >=4-tower fix
-- survive underground, and how noisy is the fix. Hand gpsrange.csv to the implementer.
--
-- NEEDS: the 4 gpshost towers running + a mini radio antenna on this turtle (distance only
--        arrives over radio). No store link required -- this probe is fully standalone.
-- RUN:   gpsrange                  dig to bedrock (or MAXDEPTH), probing every block
--        gpsrange <maxdepth>       cap the descent (e.g. 'gpsrange 60')
-- Optionally type the turtle's CURRENT F3 coords when asked: with them, each row also gets
-- the true position (X/Z constant, Y-1 per block) and the fix error. Blank = availability
-- only. The turtle climbs back to the start when done; ~6s per depth, so budget ~8-10 min.

local comms = require("comms")
local gps2  = require("gps2")

local RADIO_FREQ = 1000
local SAMPLES    = 3       -- GPS fixes attempted per depth (spread across them = jitter)
local PINGS      = 12      -- pings per fix (gps2 averages them)
local TIMEOUT    = 2       -- seconds per fix
local CSV        = "gpsrange.csv"

local MAXDEPTH = tonumber((...)) or 80

local function dist3(a, b)
  return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
end

-- optional number -> 2dp string, nil/false -> ""
local function f2(v)
  if type(v) ~= "number" then return "" end
  return string.format("%.2f", v)
end

local function logLine(s)
  local f = fs.open(CSV, "a")        -- append per line so a Ctrl+T abort keeps the data
  f.writeLine(s)
  f.close()
end

local function hasRadio()
  for _, t in ipairs(comms.transports()) do if t == "radio" then return true end end
  return false
end

local function ensureFuel(need)
  if turtle.getFuelLevel() == "unlimited" then return true end
  for s = 1, 16 do turtle.select(s); turtle.refuel() end
  turtle.select(1)
  return turtle.getFuelLevel() >= need
end

-- dig + step down one block; returns false at bedrock / when blocked
local function descend()
  local tries = 0
  while turtle.detectDown() do
    if not turtle.digDown() then return false end   -- unbreakable (bedrock)
    tries = tries + 1
    if tries > 8 then break end
    sleep(0.4)                                       -- let gravel/sand settle
  end
  return turtle.down()
end

-- attempt SAMPLES fixes at the current spot; returns heard, okCount, mean{x,y,z}|nil, spread|nil
local function probe()
  local fixes, heard = {}, 0
  for _ = 1, SAMPLES do
    local fix, second = gps2.locate(TIMEOUT, PINGS)
    if fix then
      fixes[#fixes + 1] = fix
      if type(second) == "table" and #second > heard then heard = #second end
    else
      local n = tostring(second or ""):match("heard (%d+)")
      if n and tonumber(n) > heard then heard = tonumber(n) end
    end
  end
  local okCount = #fixes
  if okCount == 0 then return heard, 0, nil, nil end
  local sx, sy, sz = 0, 0, 0
  for _, p in ipairs(fixes) do sx = sx + p.x; sy = sy + p.y; sz = sz + p.z end
  local mean = { x = sx / okCount, y = sy / okCount, z = sz / okCount }
  local spread = 0
  for _, p in ipairs(fixes) do
    local d = dist3(p, mean)
    if d > spread then spread = d end
  end
  return heard, okCount, mean, spread
end

local function askNum(label)
  write(label .. ": ")
  return tonumber(read())
end

local function main()
  comms.open({ freq = RADIO_FREQ })
  if not hasRadio() then
    print("no radio antenna found -- GPS needs the mini antenna (distance is radio-only).")
    return
  end

  print("Phase 0 GPS range probe  (towers must be running)")
  print("Optional: enter this turtle's CURRENT F3 coords for accuracy (blank x = skip).")
  local sx = askNum("x")
  local known, sy, sz = false, nil, nil
  if sx then
    sy = askNum("y"); sz = askNum("z")
    known = (sy ~= nil and sz ~= nil)
  end

  if not ensureFuel(2 * MAXDEPTH + 20) then
    local fuel = turtle.getFuelLevel()
    MAXDEPTH = math.max(0, math.floor((fuel - 20) / 2))
    print(("low fuel (%s) -- capping descent at depth %d"):format(tostring(fuel), MAXDEPTH))
  end

  if fs.exists(CSV) then fs.delete(CSV) end
  logLine(("# gpsrange  computerID=%d  freq=%d  samples=%d  pings=%d  known=%s")
    :format(os.getComputerID(), RADIO_FREQ, SAMPLES, PINGS, tostring(known)))
  logLine("depth,trueX,trueY,trueZ,heard,okSamples,fixX,fixY,fixZ,spread,horizErr,vertErr,totErr")

  local deep4, deepFix = -1, -1
  local depth = 0
  while depth <= MAXDEPTH do
    local heard, okCount, mean, spread = probe()
    if heard >= 4 then deep4 = depth end
    if okCount > 0 then deepFix = depth end

    local tx, ty, tz, horizErr, vertErr, totErr
    if known then
      tx, ty, tz = sx, sy - depth, sz
      if mean then
        horizErr = math.sqrt((mean.x - tx) ^ 2 + (mean.z - tz) ^ 2)
        vertErr  = math.abs(mean.y - ty)
        totErr   = dist3(mean, { x = tx, y = ty, z = tz })
      end
    end

    logLine(table.concat({
      depth,
      known and tx or "", known and ty or "", known and tz or "",
      heard, okCount,
      f2(mean and mean.x), f2(mean and mean.y), f2(mean and mean.z),
      f2(spread), f2(horizErr), f2(vertErr), f2(totErr),
    }, ","))
    print(("d%-3d heard %d  %s%s"):format(
      depth, heard,
      okCount > 0 and "fix" or "FAIL",
      (known and mean) and ("  err " .. f2(totErr) .. "m") or ""))

    if depth >= MAXDEPTH then break end
    if not descend() then
      logLine("# stopped: bedrock or blocked at depth " .. depth)
      break
    end
    depth = depth + 1
  end

  logLine(("# deepest >=4-tower fix: depth %d   deepest any fix: depth %d"):format(deep4, deepFix))
  print(("done. deepest 4-tower fix at depth %d, any fix at depth %d"):format(deep4, deepFix))

  print("climbing back to start...")
  for _ = 1, depth do
    while turtle.detectUp() do if not turtle.digUp() then break end end
    if not turtle.up() then break end
  end
  print("wrote " .. CSV .. " -- send it to the implementer.")
end

main()
