-- =====================================================================
-- sim.lua  --  Scripted flight for the EdgeTX simulator (dev tool only).
-- =====================================================================
-- SD card path: /SCRIPTS/GPSHOMER/sim.lua
--
-- The Companion simulator cannot feed GPS/GSpd/Hdg, so with core.SIMULATE =
-- true this replaces core.readSnapshot: every telemetry value the core
-- consumes (link, position, sats, speed, course, altitude, sensor presence)
-- comes from the script below. With SIMULATE = false the file is never loaded.
--
-- Timeline (seconds after load):
--   0-6    sats climb 3 -> 9 on the ground   -> ACQUIRING
--   6-10   disarmed with a stable fix        -> READY ("Ready to fly")
--   10     armed                             -> home set
--   10-14  armed, still on the ground         -> AT HOME (no course, no bearing)
--   14-44  fly out heading 0 (north), accelerating 0 -> 40 km/h over 8 s
--          (AT HOME until 15 m away, then the arrow), climb to 80 m
--          -> home lies exactly south: H sits on the S letter (NorthUp)
--   44-64  leg east at 40 km/h: bearing to home drifts 180 -> ~214 deg,
--          the S letter comes back once the H has moved a letter width away
--   64-74  hover far out at 3 km/h, GPS course jumping around
--          -> below COURSE_MIN_SPD: absolute bearing instead of the arrow
--   74-114 full circle (heading +9 deg/s) at 40 km/h
--   114-144 fly straight back towards home at 50 km/h
--   144-154 hover at home, speed 0           -> AT HOME again
--   154-160 sats drop to 2                   -> fix lost (announced after 3 s)
--   160-166 sats back to 9                   -> fix recovered
--   166-172 telemetry off                    -> ENDED
--   172    loop
-- =====================================================================
return function(core)
  local HOME_LAT, HOME_LON = 48.13745, 11.57518
  local LOOP = 172
  local t0
  local lat, lon = HOME_LAT, HOME_LON
  local lastT

  local function step(t, gspdKmh, hdg)
    local dt = lastT and (t - lastT) or 0
    lastT = t
    local d = gspdKmh / 3.6 * dt                       -- metres moved
    lat = lat + d * math.cos(math.rad(hdg)) / 111320
    lon = lon + d * math.sin(math.rad(hdg)) / (111320 * math.cos(math.rad(lat)))
  end

  return function()
    local now = getTime() / 100
    if not t0 then t0 = now end
    local t = (now - t0) % LOOP
    if t < 0.2 and lastT and lastT > 1 then           -- new loop: back on the pad
      lat, lon, lastT = HOME_LAT, HOME_LON, nil
    end

    local telem, sats, gspd, hdg, alt = true, 9, 0, 0, 0
    local armed = t >= 10
    if t < 6 then
      sats = math.min(9, 3 + math.floor(t))
    elseif t < 14 then
      -- on the ground: disarmed until 10 s (READY), then armed but not moving (AT HOME)
    elseif t < 44 then
      gspd, hdg, alt = math.min(40, (t - 14) * 5), 0, math.min(80, (t - 14) * 4)
    elseif t < 64 then
      gspd, hdg, alt = 40, 90, 80
    elseif t < 74 then
      gspd, hdg, alt = 3, math.floor(t * 97) % 360, 80   -- hovering: course is GPS noise
    elseif t < 114 then
      gspd, hdg, alt = 40, (90 + (t - 74) * 9) % 360, 80
    elseif t < 144 then
      gspd, alt = 50, 80 - (t - 114) * 2
      hdg = core.bearingTo(lat, lon, HOME_LAT, HOME_LON)
      if core.haversine(lat, lon, HOME_LAT, HOME_LON) < 8 then gspd = 0 end   -- inside HOME_NEAR_M -> AT HOME
    elseif t < 154 then
      gspd, alt = 0, 20
    elseif t < 160 then
      sats, alt = 2, 20
    elseif t < 166 then
      alt = 20                    -- sats back to 9 -> "GPS recovered"
    else
      telem = false
    end
    step(now, gspd, hdg)

    return {
      telem         = telem,
      gps           = telem and { lat = lat, lon = lon } or nil,
      sats          = telem and sats or nil,
      gspd          = telem and gspd or nil,
      hdg           = telem and hdg  or nil,
      alt           = telem and alt  or nil,
      armed         = armed,
      armedKnown    = true,
      sensorMissing = false,
    }
  end
end
