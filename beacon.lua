-- beacon.lua  lightweight presence layer over comms, so devices can see each other on
-- the map. A device that wants to appear broadcasts
--   { type="loc", id, label, kind, pos={x,y,z} }
-- every few seconds on the shared "gps" proto. It rides the same channel as the GPS
-- pings rather than opening a new proto: the gpshost towers only act on type "gpsq" /
-- "reboot", so a "loc" passes them by, and any map that is already listening on the gps
-- proto (gpsprobe, shipnav's GPS loop) hears it for free. Cheap on purpose - a few
-- seconds between sends, never per tick.
--
-- A tracker collects recently heard beacons and drops stale ones (TTL). It is renderer-
-- agnostic: list() hands back plain { id, label, kind, pos, dist, last } records and the
-- caller turns them into map markers (map.marker(r.pos.x, r.pos.z, r.label, r.kind)).

local comms = require("comms")

local beacon = {}
beacon.PROTO    = "gps"   -- share the GPS channel; towers ignore unknown types
beacon.INTERVAL = 3       -- default seconds between sends
beacon.TTL      = 12      -- seconds a beacon is kept after it was last heard

function beacon.send(label, kind, pos, proto)
  if not (pos and pos.x and pos.z) then return false end
  comms.send("all", {
    type = "loc", id = os.getComputerID(), label = label, kind = kind,
    pos = { x = pos.x, y = pos.y, z = pos.z },
  }, proto or beacon.PROTO)
  return true
end

-- a self-throttling emitter: call tick(now, pos) every loop, it sends at most every
-- `interval` seconds and only when it has a position. Returns true on the ticks it sent.
function beacon.sender(label, kind, interval, proto)
  local last = -1e9
  interval = interval or beacon.INTERVAL
  return function(now, pos)
    if pos and pos.x and (now - last) >= interval then
      if beacon.send(label, kind, pos, proto) then last = now; return true end
    end
    return false
  end
end

-- tracker.offer(from, body, dist, now) ingests one received message (no-op unless it is
-- a loc); tracker.list(now) returns the live records and prunes the stale ones.
function beacon.tracker(ttl)
  local self = { ttl = ttl or beacon.TTL, seen = {} }
  function self.offer(from, body, dist, now)
    if type(body) ~= "table" or body.type ~= "loc" or type(body.pos) ~= "table" then return false end
    local id = body.id or from
    self.seen[id] = {
      id = id, label = body.label or ("#" .. tostring(id)), kind = body.kind,
      pos = body.pos, dist = dist, last = now,
    }
    return true
  end
  function self.list(now)
    local out = {}
    for id, r in pairs(self.seen) do
      if now - r.last <= self.ttl then out[#out + 1] = r else self.seen[id] = nil end
    end
    return out
  end
  return self
end

return beacon
