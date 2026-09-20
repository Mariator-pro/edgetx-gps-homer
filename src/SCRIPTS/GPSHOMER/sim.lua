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
--   0-6    sats climb 3 -> 9 on the ground   -> ACQUIRING, then home set
--   6-36   fly out heading 0 (north), 40 km/h, climb to 80 m
--          -> home lies exactly south: H sits on the S letter (NorthUp)
--   36-56  leg east at 40 km/h: bearing to home drifts 180 -> ~214 deg,
--          the S letter comes back once the H has moved a letter width away
--   56-96  full circle (heading +9 deg/s) at 40 km/h
--   96-126 fly straight back towards home at 50 km/h
--   126-136 hover at home, speed 0            -> absolute direction fallback
--   136-142 sats drop to 2                    -> fix lost / recovered
--   142-148 telemetry off                     -> ENDED
--   148    loop
-- =====================================================================
return function(core)
  local HOME_LAT, HOME_LON = 48.13745, 11.57518
  local LOOP = 148
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
    if t < 6 then
      sats = math.min(9, 3 + math.floor(t))
    elseif t < 36 then
      gspd, hdg, alt = 40, 0, math.min(80, (t - 6) * 5)
    elseif t < 56 then
      gspd, hdg, alt = 40, 90, 80
    elseif t < 96 then
      gspd, hdg, alt = 40, (90 + (t - 56) * 9) % 360, 80
    elseif t < 126 then
      gspd, alt = 50, 80 - (t - 96) * 2
      hdg = core.bearingTo(lat, lon, HOME_LAT, HOME_LON)
      if core.haversine(lat, lon, HOME_LAT, HOME_LON) < 15 then gspd = 0 end
    elseif t < 136 then
      gspd, alt = 0, 20
    elseif t < 142 then
      sats, alt = 2, 20
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
      sensorMissing = false,
    }
  end
end
