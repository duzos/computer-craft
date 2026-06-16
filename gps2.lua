-- gps2.lua  radio-GPS client library. locate() pings the gpshost towers on the
-- "gps" proto, AVERAGES each tower's reported distance (the radio link distance is
-- noisy ~sub-meter, so we sample), and 3D-trilaterates a fix from >=4 towers via
-- least squares. trilaterate2d() is the fallback: an (x,z) fix from >=3 towers --
-- pass a known Y for accuracy, or nil for a rough top-down fix that ignores altitude.
--
-- Requires the RADIO ANTENNA: distance only arrives on radio_message, so a wireless-
-- modem-only device gets no fix. comms transports must already be open by the caller
-- (locate uses the "gps" proto explicitly, so it coexists with fleet "store" comms).

local comms = require("comms")

local gps2 = {}
local GPS_PROTO = "gps"

local function det3(m)
  return m[1][1] * (m[2][2] * m[3][3] - m[2][3] * m[3][2])
       - m[1][2] * (m[2][1] * m[3][3] - m[2][3] * m[3][1])
       + m[1][3] * (m[2][1] * m[3][2] - m[2][2] * m[3][1])
end

local function solve3(A, b)
  local D = det3(A)
  if math.abs(D) < 1e-6 then return nil end          -- singular: towers coplanar/degenerate
  local function withCol(ci)
    local M = {}
    for r = 1, 3 do
      M[r] = { A[r][1], A[r][2], A[r][3] }
      M[r][ci] = b[r]
    end
    return M
  end
  return { det3(withCol(1)) / D, det3(withCol(2)) / D, det3(withCol(3)) / D }
end

-- least-squares trilateration from points {x,y,z,d}: subtract point 1's sphere
-- equation from the rest to linearise, then solve the 3x3 normal equations. Works
-- for exactly 4 towers (exact) or more (overdetermined least squares).
function gps2.trilaterate(pts)
  if #pts < 4 then return nil, "need at least 4 points" end
  local x0, y0, z0, d0 = pts[1].x, pts[1].y, pts[1].z, pts[1].d
  local s0 = x0 * x0 + y0 * y0 + z0 * z0
  local AtA = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
  local Atb = { 0, 0, 0 }
  for i = 2, #pts do
    local p = pts[i]
    local row = { 2 * (p.x - x0), 2 * (p.y - y0), 2 * (p.z - z0) }
    local bi = (p.x * p.x + p.y * p.y + p.z * p.z) - s0 - (p.d * p.d) + (d0 * d0)
    for a = 1, 3 do
      for c = 1, 3 do AtA[a][c] = AtA[a][c] + row[a] * row[c] end
      Atb[a] = Atb[a] + row[a] * bi
    end
  end
  local sol = solve3(AtA, Atb)
  if not sol then return nil, "degenerate tower geometry (coplanar?)" end
  return { x = sol[1], y = sol[2], z = sol[3] }
end

-- (x,z) fix from >=3 towers without a 4th (3 spheres give an ambiguous 3D point).
-- With a knownY each slant range is corrected to a true horizontal range (accurate);
-- with knownY = nil the slant ranges are used directly -- a rougher top-down x/z that
-- needs no Y (error grows with your vertical offset from the towers). Then
-- 2D-trilaterate (2x2 normal equations). returns { x, y = knownY, z } or nil, error.
function gps2.trilaterate2d(pts, knownY)
  if #pts < 3 then return nil, "need at least 3 points" end
  local hp = {}
  for _, p in ipairs(pts) do
    local r = p.d
    if knownY then
      local dy = p.y - knownY
      local h2 = p.d * p.d - dy * dy
      r = math.sqrt(h2 > 0 and h2 or 0)
    end
    hp[#hp + 1] = { x = p.x, z = p.z, r = r }
  end
  local x1, z1, r1 = hp[1].x, hp[1].z, hp[1].r
  local s1 = x1 * x1 + z1 * z1
  local A = { { 0, 0 }, { 0, 0 } }
  local b = { 0, 0 }
  for i = 2, #hp do
    local p = hp[i]
    local row = { 2 * (p.x - x1), 2 * (p.z - z1) }
    local bi = (p.x * p.x + p.z * p.z) - s1 - (p.r * p.r) + (r1 * r1)
    for a = 1, 2 do
      for c = 1, 2 do A[a][c] = A[a][c] + row[a] * row[c] end
      b[a] = b[a] + row[a] * bi
    end
  end
  local det = A[1][1] * A[2][2] - A[1][2] * A[2][1]
  if math.abs(det) < 1e-6 then return nil, "degenerate (towers collinear?)" end
  local x = (b[1] * A[2][2] - A[1][2] * b[2]) / det
  local z = (A[1][1] * b[2] - b[1] * A[2][1]) / det
  return { x = x, y = knownY, z = z }
end

-- ping the towers, gather >=4 (pos,dist) samples, average dist per tower, solve.
-- returns fix{x,y,z}, pts   or   nil, errorstring
function gps2.locate(timeout, pings)
  timeout = timeout or 2
  pings   = pings or 8
  local hosts = {}
  local deadline = os.clock() + timeout
  local gap = timeout / pings
  comms.send("all", { type = "gpsq" }, GPS_PROTO)
  local lastPing = os.clock()
  while os.clock() < deadline do
    local m = comms.receive(GPS_PROTO, 0.3)
    if m and m.dist and type(m.body) == "table"
       and m.body.type == "gpsr" and type(m.body.pos) == "table" then
      local h = hosts[m.from]
      if not h then h = { pos = m.body.pos, dists = {} }; hosts[m.from] = h end
      h.dists[#h.dists + 1] = m.dist
    end
    if os.clock() - lastPing >= gap then
      comms.send("all", { type = "gpsq" }, GPS_PROTO)
      lastPing = os.clock()
    end
  end
  local pts = {}
  for _, h in pairs(hosts) do
    local n = #h.dists
    if n > 0 then
      local s = 0
      for _, d in ipairs(h.dists) do s = s + d end
      pts[#pts + 1] = { x = h.pos.x, y = h.pos.y, z = h.pos.z, d = s / n }
    end
  end
  if #pts < 4 then return nil, ("need 4 towers in range, heard %d"):format(#pts) end
  local fix, err = gps2.trilaterate(pts)
  if not fix then return nil, err end
  return fix, pts
end

return gps2
