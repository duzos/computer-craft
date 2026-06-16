-- gpshost.lua  radio-GPS host. one per tower: replies to locate requests with its
-- surveyed position so turtles/pocket can 3D-trilaterate a fix.
--
-- On first boot it ASKS for this tower's position and saves it to gpshost.state, so
-- the same file deploys to all 4 towers unchanged -- you just type each tower's
-- coords once. Enter the F3 coords of the TOP of this tower's radio antenna: the
-- probe showed radio distance is measured to the tower TOP, not the base.
--   run:  gpshost          (load saved pos, or ask on first boot)
--         gpshost reset     (wipe saved pos and re-survey)
--
-- Deploy on each of the 4 tower computers. Two placement rules or the fix breaks:
--   * the 4 towers must form a FAT TETRAHEDRON -- well spread horizontally AND at
--     clearly different heights (coplanar towers make the vertical solve singular).
--   * give each host computer the RADIO ANTENNA ONLY (no wireless modem), so every
--     reply carries a radio distance and nothing races the dedupe with a distance-
--     less rednet copy.

local comms = require("comms")

local GPS_PROTO  = "gps"
local RADIO_FREQ = 1000
local STATE_FILE = "gpshost.state"

local function loadPos()
  if not fs.exists(STATE_FILE) then return nil end
  local f = fs.open(STATE_FILE, "r"); local t = textutils.unserialize(f.readAll()); f.close()
  if type(t) == "table" and type(t.x) == "number" and type(t.y) == "number" and type(t.z) == "number" then
    return t
  end
  return nil
end

local function savePos(pos)
  local f = fs.open(STATE_FILE, "w"); f.write(textutils.serialize(pos)); f.close()
end

local function askNum(label)
  while true do
    write(label .. ": ")
    local v = tonumber(read())
    if v then return v end
    print("  not a number, try again")
  end
end

local args = { ... }
local cohost = (args[1] == "cohost")   -- launched by the store's startup; its reboot is the store's job
if args[1] == "reset" and fs.exists(STATE_FILE) then fs.delete(STATE_FILE) end

local POS = loadPos()
if not POS then
  print("gpshost first boot -- enter this tower's ANTENNA-TOP coords (F3):")
  POS = { x = askNum("x"), y = askNum("y"), z = askNum("z") }
  savePos(POS)
  print("saved to " .. STATE_FILE .. "  (run 'gpshost reset' to re-survey)")
end

comms.open({ freq = RADIO_FREQ, proto = GPS_PROTO })
if not comms.up() then print("no radio/modem found; gps host cannot run"); return end
print(("gps host #%d at (%d,%d,%d) on '%s' -- Ctrl+T to quit")
  :format(os.getComputerID(), POS.x, POS.y, POS.z, GPS_PROTO))

while true do
  local m = comms.receive(GPS_PROTO)
  if m and type(m.body) == "table" then
    if m.body.type == "gpsq" then
      comms.send(m.from, { type = "gpsr", pos = POS }, GPS_PROTO)
    elseif m.body.type == "reboot" and not cohost then
      os.reboot()   -- fleet reboot broadcast: standalone towers cycle to pick up new code
    end
  end
end
