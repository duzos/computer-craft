-- range.lua  --  modem / GPS range tester for an advanced wireless pocket computer
-- pings GPS hosts on the GPS channel and shows which are in range and how far.
-- GPS hosts reply with their coords; the modem_message carries the distance.

local CHANNEL_GPS = 65534

local function findModem()
  for _, s in ipairs(peripheral.getNames()) do
    if peripheral.getType(s) == "modem" and peripheral.call(s, "isWireless") then return s end
  end
end

local side = findModem()
if not side then
  print("No wireless modem found.")
  print("Needs an advanced WIRELESS pocket computer.")
  return
end
local modem = peripheral.wrap(side)
local reply = os.getComputerID()
modem.open(reply)

local W, H = term.getSize()

local function ping()
  modem.transmit(CHANNEL_GPS, reply, "PING")
  local hosts, quit = {}, false
  local t = os.startTimer(1.2)
  while true do
    local ev, a, b, _, d, e = os.pullEvent()
    if ev == "modem_message" then
      if b == reply and type(d) == "table"
         and type(d[1]) == "number" and type(d[2]) == "number" and type(d[3]) == "number" then
        hosts[#hosts + 1] = { x = d[1], y = d[2], z = d[3], dist = e }
      end
    elseif ev == "char" and a == "q" then
      quit = true; break
    elseif ev == "timer" and a == t then
      break
    end
  end
  return hosts, quit
end

local function at(x, y, s, c)
  term.setCursorPos(x, y); if c then term.setTextColor(c) end; term.write(s)
end

local function render(hosts)
  term.setBackgroundColor(colors.black); term.clear()

  term.setCursorPos(1, 1); term.setBackgroundColor(colors.blue)
  term.setTextColor(colors.white); term.clearLine(); term.write(" RANGE TESTER")
  term.setBackgroundColor(colors.black)

  at(1, 2, "modem: " .. side, colors.lightGray)

  local n = #hosts
  local cc = n >= 4 and colors.lime or (n > 0 and colors.yellow or colors.red)
  at(1, 3, "GPS hosts: ", colors.cyan); term.setTextColor(cc); term.write(tostring(n))

  table.sort(hosts, function(a, b) return (a.dist or 1e9) < (b.dist or 1e9) end)
  local row = 4
  if n == 0 then
    at(1, row, " none in range", colors.red)
  else
    for i, hst in ipairs(hosts) do
      if row > H - 4 then break end
      local d = hst.dist and ("%dm"):format(math.floor(hst.dist + 0.5)) or "?"
      at(1, row, (" %d %s"):format(i, d), colors.white)
      term.setTextColor(colors.gray)
      term.write((" %d,%d,%d"):format(hst.x, hst.y, hst.z))
      row = row + 1
    end
  end

  at(1, H - 2, "FIX: ", colors.cyan)
  if n >= 4 then term.setTextColor(colors.lime); term.write("yes")
  else term.setTextColor(colors.red); term.write(("need %d more"):format(4 - n)) end

  at(1, H - 1, "pos: ", colors.cyan)
  local x, y, z = gps.locate(1)
  if x then term.setTextColor(colors.white); term.write(("%d,%d,%d"):format(x, y, z))
  else term.setTextColor(colors.red); term.write("no fix") end

  at(1, H, "q to quit", colors.gray)
end

while true do
  local hosts, quit = ping()
  if quit then break end
  render(hosts)
end
term.setBackgroundColor(colors.black); term.setTextColor(colors.white)
term.clear(); term.setCursorPos(1, 1); print("range tester stopped.")
