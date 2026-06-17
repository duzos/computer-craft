-- redstone.lua  --  prompt for a redstone level and emit it from the computer.
-- no peripheral needed: every computer drives redstone on its own six sides via the
-- built-in redstone API. type 0-15 to set the analog signal on SIDE, q to quit.

local SIDE = "back"   -- side to emit on: top/bottom/left/right/front/back

local function main()
  redstone.setAnalogOutput(SIDE, redstone.getAnalogOutput(SIDE))   -- hold current on (re)start
  print(("redstone on %s  (current %d)  -- enter 0-15, or q to quit")
    :format(SIDE, redstone.getAnalogOutput(SIDE)))
  while true do
    write("level> ")
    local s = (read() or ""):gsub("^%s*(.-)%s*$", "%1")
    if s == "q" or s == "quit" then break end
    local n = tonumber(s)
    if n and n >= 0 and n <= 15 and n == math.floor(n) then
      redstone.setAnalogOutput(SIDE, n)
      print(("  %s = %d"):format(SIDE, n))
    else
      print("  need a whole number 0-15")
    end
  end
end

main()
