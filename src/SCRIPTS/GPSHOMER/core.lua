-- =====================================================================
-- core.lua  --  Shared logic core for GPS Homer.
-- =====================================================================
-- SD card path: /SCRIPTS/GPSHOMER/core.lua
--
-- Single source of truth for thresholds, sensor names, sounds and the whole
-- runtime logic. Loaded (via loadScript()/loadfile) by ALL consumers and must
-- always be installed alongside them:
--   * the telemetry widget  /WIDGETS/GPSHOMER/main.lua      (display only)
--   * the function script    /SCRIPTS/FUNCTIONS/gpshom.lua  (voice events only)
--   * the tools script       /SCRIPTS/TOOLS/GPSHOMER.lua    (configuration)
--
-- "core does everything except drawing": the hardware glue (getValue / playFile
-- / getTime / getRSSI) lives here exactly once; there are NO lcd.* calls and NO
-- mutable module state (the caller owns its state, so multiple widget instances
-- never collide). The pure math functions are desktop-testable.
-- =====================================================================
-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 Mariator-pro
--
-- This program is free software; you can redistribute it and/or modify
-- it under the terms of the GNU General Public License version 2 as
-- published by the Free Software Foundation.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
-- =====================================================================

local M = {}

-- ---------------------------------------------------------------------------
-- Declarations (single source of truth)
-- ---------------------------------------------------------------------------

-- Telemetry sensor names (Betaflight + ELRS over CRSF). Hard-coded (no
-- auto-discovery in V1); the widget/tool never name a sensor themselves.
M.SENSORS = {
  gps  = "GPS",
  sats = "Sats",
  gspd = "GSpd",
  hdg  = "Hdg",
  alt  = "Alt",    -- altitude; GAlt (GPS altitude) is preferred when discovered
  galt = "GAlt",
  rqly = "RQly",
}

-- Event sounds. Folder fixed (case-sensitive FAT: folder upper, files lower);
-- per event the config may hold a file name or `false` (that event muted).
-- Absolute path bypasses EdgeTX's per-language resolution so the pilot's own
-- voice plays regardless of locale.
M.VERSION   = "0.1.0"

-- Simulator switch: true replaces all telemetry reads with the scripted flight
-- in sim.lua (Companion cannot feed GPS/GSpd/Hdg). Must be false for flying.
M.SIMULATE  = false
M.SOUND_DIR = "/SOUNDS/en/scripts/GPSHOMER/"
M.SOUNDS = {
  fix  = "gpsfix.wav",   -- "home set"
  lost = "gpslost.wav",  -- "GPS lost"
  rec  = "gpsrec.wav",   -- "GPS recovered"
}

-- Factory defaults for the event sounds, frozen BEFORE any config overlay so the
-- tool can offer a true "Default" per event and applyConfigOverrides stays
-- idempotent regardless of call order.
M.SOUND_DEFAULTS = { fix = M.SOUNDS.fix, lost = M.SOUNDS.lost, rec = M.SOUNDS.rec }

-- Tunable parameters. HOME_MIN_SATS and the two HAPTIC values are pilot-editable
-- (via the tool / config.lua); the rest are fixed core constants (PC edit only).
-- Times are in SECONDS (converted to ms at each comparison), TICK_MS is in ms.
M.PARAMS = {
  HOME_MIN_SATS  = 6,      -- FR-6: min. sats for the home set   (config: homeMinSats)
  HAPTIC          = false, -- Vibrate alongside an event sound (opt-in; config: haptic)
  HAPTIC_STRENGTH = 2,     -- Pulse-length tier: 1 = soft, 2 = normal, 3 = strong
  COURSE_MIN_SPD = 6,      -- FR-10: km/h below which the GPS course is not usable
  HOME_STABLE_T  = 3,      -- FR-6: fix must stay ok this long before home is set (s)
  FIX_LOSS_T     = 3,      -- NFR-4: fix-loss debounce (s)
  LINK_LOSS_T    = 1.5,    -- ACTIVE -> ENDED after this much sustained link loss (s)
  ENDED_HOLD_T   = 60,     -- FR-13: ENDED holds the last position this long (s)
  AHEAD_DEG      = 15,     -- |rel| <= this -> "ahead"
  BEHIND_DEG     = 165,    -- |rel| >= this -> "behind"
  TICK_MS        = 100,    -- NFR-1: 10 Hz update throttle (ms)
}

-- playHaptic pulse length per strength tier, and pulses per event: GPS lost
-- fires twice to feel clearly stronger than the two "good news" events.
M.HAPTIC_DUR    = { [1] = 15, [2] = 30, [3] = 50 }
M.HAPTIC_PULSES = { fix = 1, lost = 2, rec = 1 }

-- Editable ranges: the SINGLE source for both the on-radio editor and the
-- runtime clamp in normalizeConfig, so they can never drift apart.
M.LIMITS = {
  homeMinSats     = { min = 4, max = 20, step = 1 },
  hapticStrength  = { min = 1, max = 3,  step = 1 },
}

M.CONFIG_PATH           = "/SCRIPTS/GPSHOMER/config.lua"
M.CONFIG_SCHEMA_VERSION = 1

-- Snapshot of the factory defaults for the overridable params, taken before
-- any config overlay. This is what the tool reads for "Reset to defaults" and
-- what normalizeConfig falls back to (PARAMS is already overlaid by then).
M.DEFAULTS = {
  homeMinSats    = M.PARAMS.HOME_MIN_SATS,
  haptic         = M.PARAMS.HAPTIC,
  hapticStrength = M.PARAMS.HAPTIC_STRENGTH,
}
local DEFAULTS = M.DEFAULTS

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Two-argument atan: EdgeTX's Lua may or may not accept math.atan(y, x), so
-- probe once (atan(1, -1) > 1.5 only with the two-argument form) and fall back
-- to a quadrant-correct implementation on top of the one-argument atan.
local atan2
do
  local ok, v = pcall(function() return math.atan(1, -1) end)
  local twoArg = ok and type(v) == "number" and v > 1.5
  if twoArg then
    atan2 = function(y, x) return math.atan(y, x) end
  else
    atan2 = function(y, x)
      if x > 0 then return math.atan(y / x) end
      if x < 0 then
        if y >= 0 then return math.atan(y / x) + math.pi end
        return math.atan(y / x) - math.pi
      end
      if y > 0 then return math.pi / 2 end
      if y < 0 then return -math.pi / 2 end
      return 0
    end
  end
end
M.atan2 = atan2

-- Clamp n into [lo, hi]; a non-number falls back.
local function clampNum(n, lo, hi, fallback)
  if type(n) ~= "number" then return fallback end
  if n < lo then return lo elseif n > hi then return hi end
  return n
end

-- A boolean is kept as is; anything else falls back.
local function boolOr(v, fallback)
  if type(v) == "boolean" then return v end
  return fallback
end

-- True unless fstat positively says the file is gone. fstat is absent on the
-- desktop and pcall-guarded, so "unknown" keeps the custom name.
local function soundFileExists(name)
  if not fstat then return true end
  local ok, info = pcall(fstat, M.SOUND_DIR .. name)
  return not ok or info ~= nil
end

-- Sound override helper: a string is a custom file name (dropped to the default
-- when the file no longer exists on the card, so the event still sounds), `false`
-- means the pilot muted this event, and anything else (nil/garbage) falls back
-- to the default so playFile can never receive junk.
local function soundOr(v, fallback)
  if type(v) == "string" then
    if soundFileExists(v) then return v end
    return fallback
  end
  if v == false then return false end
  return fallback
end

-- getTime() ticks are 10 ms; work in ms so the SECONDS params scale cleanly.
local function nowMs()
  return getTime() * 10
end

-- getFieldInfo() is nil for a sensor that was never discovered; pcall-guarded
-- because the API may raise on some builds / on the desktop.
local function sensorExists(name)
  local ok, info = pcall(getFieldInfo, name)
  return ok and info ~= nil
end

-- getValue() returns 0 for undiscovered sensors, indistinguishable from a real
-- zero; pcall-guarded so a broken API call never crashes the widget.
local function safeGet(name)
  local ok, v = pcall(getValue, name)
  if ok then return v end
  return nil
end

-- ---------------------------------------------------------------------------
-- Validation (pure)
-- ---------------------------------------------------------------------------

-- A usable GPS reading: a table with numeric lat/lon inside the valid ranges;
-- 0/0 ("null island") is what a GPS without a fix reports and is rejected.
function M.validGps(t)
  if type(t) ~= "table" then return false end
  local lat, lon = t.lat, t.lon
  if type(lat) ~= "number" or type(lon) ~= "number" then return false end
  if lat < -90 or lat > 90 then return false end
  if lon < -180 or lon > 180 then return false end
  if lat == 0 and lon == 0 then return false end
  return true
end

-- A number inside [lo, hi], else nil (discarded sample).
function M.validRange(v, lo, hi)
  if type(v) ~= "number" then return nil end
  if v < lo or v > hi then return nil end
  return v
end

-- ---------------------------------------------------------------------------
-- Geometry (pure)
-- ---------------------------------------------------------------------------

-- Great-circle distance in metres (haversine, spherical earth).
function M.haversine(lat1, lon1, lat2, lon2)
  local R    = 6371000
  local rad  = math.rad
  local dLat = rad(lat2 - lat1)
  local dLon = rad(lon2 - lon1)
  local a    = math.sin(dLat / 2) ^ 2
             + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.sin(dLon / 2) ^ 2
  return R * 2 * atan2(math.sqrt(a), math.sqrt(1 - a))
end

-- Initial bearing from (lat, lon) to home, 0..360 with 0 = North.
function M.bearingTo(lat, lon, homeLat, homeLon)
  local rad  = math.rad
  local dLon = rad(homeLon - lon)
  local y    = math.sin(dLon) * math.cos(rad(homeLat))
  local x    = math.cos(rad(lat)) * math.sin(rad(homeLat))
             - math.sin(rad(lat)) * math.cos(rad(homeLat)) * math.cos(dLon)
  return (math.deg(atan2(y, x)) + 360) % 360
end

-- Home direction relative to the nose: -180..+180, positive = right.
function M.relAngle(bearing, course)
  return ((bearing - course + 540) % 360) - 180
end

-- Eight compass sectors, 45 deg each, centred on the cardinal directions.
local SECTORS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
function M.sectorOf(bearing)
  return SECTORS[math.floor((bearing % 360 + 22.5) / 45) % 8 + 1]
end

-- The GPS course is only meaningful above a minimum ground speed.
function M.courseValid(gspd)
  return (gspd or 0) >= M.PARAMS.COURSE_MIN_SPD
end

-- ---------------------------------------------------------------------------
-- Config overlay (pure: no file I/O, directly unit-testable)
-- ---------------------------------------------------------------------------

-- Normalise a parsed config table into a clean copy (never touches PARAMS; the
-- only I/O is one fstat per custom sound): homeMinSats clamped to LIMITS, wrong
-- types replaced by the factory default, a sound is a file name, false (muted)
-- or nil (default). The ONE place that decides what a config value means: the
-- runtime overlay below and the tool's editor both go through here, so they
-- can never disagree on a hand-edited file.
function M.normalizeConfig(cfg)
  cfg = cfg or {}
  local L   = M.LIMITS
  local snd = (type(cfg.sounds) == "table") and cfg.sounds or {}
  return {
    homeMinSats = clampNum(cfg.homeMinSats,
                    L.homeMinSats.min, L.homeMinSats.max, DEFAULTS.homeMinSats),
    haptic         = boolOr(cfg.haptic, DEFAULTS.haptic),
    hapticStrength = clampNum(cfg.hapticStrength,
                    L.hapticStrength.min, L.hapticStrength.max, DEFAULTS.hapticStrength),
    sounds = {
      fix  = soundOr(snd.fix,  nil),
      lost = soundOr(snd.lost, nil),
      rec  = soundOr(snd.rec,  nil),
    },
  }
end

-- Overlay a parsed config table onto PARAMS/SOUNDS. DEFAULTS / SOUND_DEFAULTS
-- are left untouched (the tool's Reset relies on that snapshot guarantee).
function M.applyConfigOverrides(cfg)
  local n = M.normalizeConfig(cfg)
  M.PARAMS.HOME_MIN_SATS   = n.homeMinSats
  M.PARAMS.HAPTIC          = n.haptic
  M.PARAMS.HAPTIC_STRENGTH = n.hapticStrength
  for _, k in ipairs({ "fix", "lost", "rec" }) do
    local v = n.sounds[k]
    if v == nil then v = M.SOUND_DEFAULTS[k] end
    M.SOUNDS[k] = v
  end
end

-- Load the optional config ONCE at module load. Thresholds are ground config
-- (not retuned mid-flight), so a single read is enough and there is no per-tick
-- file I/O. Fully fault tolerant: a missing, unparsable or schema-mismatched
-- file silently leaves the defaults in force (the config is not flight
-- critical; the tool reports and repairs a broken file on the ground).
-- loadScript is the documented EdgeTX loader (nil when missing/broken) and does
-- not exist on desktop, so unit tests are unaffected.
local function loadConfigOnce()
  local chunk = loadScript and loadScript(M.CONFIG_PATH)
  if not chunk then return end
  local ok, result = pcall(chunk)
  if not ok or type(result) ~= "table" then return end
  if result.schemaVersion ~= M.CONFIG_SCHEMA_VERSION then return end
  M.applyConfigOverrides(result)
end
pcall(loadConfigOnce)

-- ---------------------------------------------------------------------------
-- Telemetry I/O -- the single place that reads all sensors raw.
-- ---------------------------------------------------------------------------

-- The sensors the script cannot work without (all from the FC's GPS frame).
-- Alt is display-only and RQly has a fallback, so neither is mandatory.
local REQUIRED = { "gps", "sats", "gspd", "hdg" }

-- Read + validate every sensor. Invalid samples become nil so evaluate() keeps
-- the last valid value. sensorMissing distinguishes "sensor never discovered"
-- (no GPS telemetry configured) from "0 satellites" / a momentary bad value.
function M.readSnapshot()
  local S       = M.SENSORS
  local rawGps  = safeGet(S.gps)
  local gps     = M.validGps(rawGps) and { lat = rawGps.lat, lon = rawGps.lon } or nil
  local sats    = M.validRange(safeGet(S.sats), 0, 99)
  local gspd    = M.validRange(safeGet(S.gspd), 0, 500)
  local hdg     = M.validRange(safeGet(S.hdg),  0, 360)
  -- Altitude: GAlt when the radio discovered it (EdgeTX names the GPS altitude
  -- so on some setups), else Alt; neither -> nil, never a misleading 0.
  local altName = sensorExists(S.galt) and S.galt or (sensorExists(S.alt) and S.alt) or nil
  local alt     = altName and M.validRange(safeGet(altName), -500, 10000) or nil

  -- Online detection: RQly > 0 when the sensor exists; else fall back to the
  -- radio RSSI; last resort a plausible GPS reading (3.2).
  local telem
  if sensorExists(S.rqly) then
    telem = (safeGet(S.rqly) or 0) > 0
  else
    local ok, rssi = pcall(getRSSI)
    if ok and type(rssi) == "number" then
      telem = rssi > 0
    else
      telem = gps ~= nil
    end
  end

  local sensorMissing = false
  for _, k in ipairs(REQUIRED) do
    if not sensorExists(S[k]) then sensorMissing = true end
  end

  return {
    telem         = telem,
    gps           = gps,
    sats          = sats,
    gspd          = gspd,
    hdg           = hdg,
    alt           = alt,
    sensorMissing = sensorMissing,
  }
end

-- SIMULATE: sim.lua returns a replacement readSnapshot that plays a scripted
-- flight, so every value the core consumes comes from the script.
if M.SIMULATE then
  pcall(function()
    local chunk = loadScript and loadScript("/SCRIPTS/GPSHOMER/sim.lua")
    if chunk then M.readSnapshot = chunk()(M) end
  end)
end

-- ---------------------------------------------------------------------------
-- State (caller-owned: no module state, one table per widget instance)
-- ---------------------------------------------------------------------------

-- Reset the whole per-flight state. Called for a fresh instance and on a
-- reconnect / ENDED-timeout (a reconnect counts as a new flight, FR-12). It does
-- NOT touch `status` -- the caller sets the target state. Note this DROPS the last
-- position, so it must never run on the ACTIVE->ENDED transition (which freezes
-- the position for the ENDED screen).
function M.resetFlight(state)
  state.homeSet          = false
  state.homeLat          = nil
  state.homeLon          = nil
  state.fixOkSince       = nil   -- home-set stabilisation timer (nil = not started)
  state.fixLostSince     = nil   -- fix-loss debounce timer
  state.fixLost          = false
  state.linkLostSince    = nil   -- link-loss debounce timer
  state.endedAt          = 0     -- when ENDED was entered (only read after set)
  state.homeAnnounced    = false
  state.fixLostAnnounced = false
  -- last valid telemetry holds (also the frozen ENDED position)
  state.lastLat  = nil
  state.lastLon  = nil
  state.lastSats = nil
  state.lastGspd = nil
  state.lastHdg  = nil
  state.lastAlt  = nil
end

function M.newState()
  local s = {}
  M.resetFlight(s)
  s.status = "NO_TELEM"
  return s
end

-- ---------------------------------------------------------------------------
-- State machine (pure: mutates `state`, returns a result table; no I/O)
-- States: NO_TELEM / ACQUIRING / ACTIVE / ENDED. `now` is in ms.
-- ---------------------------------------------------------------------------
function M.evaluate(state, snap, now)
  local P      = M.PARAMS
  local result = {}

  -- Hold the last valid telemetry (frozen for the ENDED screen). Invalid samples
  -- arrive as nil and are ignored, so held values never regress to garbage.
  if snap.gps  then state.lastLat, state.lastLon = snap.gps.lat, snap.gps.lon end
  if snap.sats then state.lastSats = snap.sats end
  if snap.gspd then state.lastGspd = snap.gspd end
  if snap.hdg  then state.lastHdg  = snap.hdg  end
  if snap.alt  then state.lastAlt  = snap.alt  end

  -- ---- telemetry offline ----
  if not snap.telem then
    if state.status == "ACTIVE" then
      if not state.linkLostSince then state.linkLostSince = now end
      if now - state.linkLostSince >= P.LINK_LOSS_T * 1000 then
        state.status  = "ENDED"        -- freeze position, stay silent (FR-13)
        state.endedAt = now
      end
    elseif state.status == "ACQUIRING" then
      if not state.linkLostSince then state.linkLostSince = now end
      if now - state.linkLostSince >= P.LINK_LOSS_T * 1000 then
        M.resetFlight(state)           -- nothing to show -> straight to NO_TELEM
        state.status = "NO_TELEM"
      end
    elseif state.status == "ENDED" then
      if now - state.endedAt >= P.ENDED_HOLD_T * 1000 then
        M.resetFlight(state)           -- hold elapsed -> discard position
        state.status = "NO_TELEM"
      end
    end
    result.status  = state.status
    result.lastLat = state.lastLat
    result.lastLon = state.lastLon
    return result
  end

  -- ---- telemetry online ----
  state.linkLostSince = nil

  -- A return of telemetry from a terminal/idle state is a NEW flight (FR-12).
  if state.status == "ENDED" or state.status == "NO_TELEM" then
    M.resetFlight(state)
    state.status = "ACQUIRING"
  end

  -- Current-sample fix validity: required sensors present, position plausible, and
  -- enough satellites -- all from THIS sample so a dropout breaks stabilisation.
  local fixOk = (not snap.sensorMissing)
            and snap.gps ~= nil
            and snap.sats ~= nil
            and snap.sats >= P.HOME_MIN_SATS

  -- ---- home not yet set: try to set it (ACQUIRING) ----
  if not state.homeSet then
    if fixOk then
      if not state.fixOkSince then state.fixOkSince = now end
      if now - state.fixOkSince >= P.HOME_STABLE_T * 1000 then
        state.homeSet = true
        state.homeLat = snap.gps.lat
        state.homeLon = snap.gps.lon
        if not state.homeAnnounced then
          result.homeSet      = true   -- one-shot event
          state.homeAnnounced = true
        end
      end
    else
      state.fixOkSince = nil           -- stabilisation must be uninterrupted
    end
  end

  if not state.homeSet then
    state.status             = "ACQUIRING"
    result.status            = "ACQUIRING"
    result.sats              = snap.sats or state.lastSats
    result.sensorMissing = snap.sensorMissing
    return result
  end

  -- ---- ACTIVE ----
  state.status = "ACTIVE"

  -- Fix-loss debounce: display stays put with the last valid values; only the
  -- flag (and the one-shot events) flip once the loss/return is confirmed.
  if not fixOk then
    if not state.fixLostSince then state.fixLostSince = now end
    if not state.fixLost and (now - state.fixLostSince) >= P.FIX_LOSS_T * 1000 then
      state.fixLost = true
      if not state.fixLostAnnounced then
        result.fixLostEvent    = true    -- one-shot for the sound
        state.fixLostAnnounced = true
      end
    end
  else
    state.fixLostSince = nil
    if state.fixLost then
      state.fixLost          = false
      state.fixLostAnnounced = false   -- re-arm so a later loss re-announces
      result.fixRecovered    = true
    end
  end

  -- Derived display values from the last valid telemetry.
  local lat, lon = state.lastLat, state.lastLon
  if lat and lon and state.homeLat then
    result.distanceM     = M.haversine(lat, lon, state.homeLat, state.homeLon)
    result.bearingToHome = M.bearingTo(lat, lon, state.homeLat, state.homeLon)
    result.sector        = M.sectorOf(result.bearingToHome)
    result.courseValid   = M.courseValid(state.lastGspd or 0)
    if result.courseValid then
      result.course = state.lastHdg or 0     -- GPS course, for the compass ring
      result.rel    = M.relAngle(result.bearingToHome, result.course)
    end
  end

  result.status            = "ACTIVE"
  result.sats              = snap.sats or state.lastSats
  result.alt               = state.lastAlt
  result.gspd              = state.lastGspd
  result.lastLat           = lat
  result.lastLon           = lon
  result.fixLost           = state.fixLost   -- persistent flag: widget colours sats red
  result.sensorMissing = snap.sensorMissing
  return result
end

-- ---------------------------------------------------------------------------
-- Orchestration: one full cycle read -> evaluate -> event sounds.
-- ---------------------------------------------------------------------------

local function playSound(file)
  if playFile and type(file) == "string" then
    playFile(M.SOUND_DIR .. file)
  end
end

-- Vibrate alongside an event (HAPTIC_PULSES pulses). No-op when haptic is off
-- or the build lacks playHaptic (desktop tests / motorless radios).
local function eventHaptic(key)
  if not M.PARAMS.HAPTIC or not playHaptic then return end
  local dur    = M.HAPTIC_DUR[M.PARAMS.HAPTIC_STRENGTH] or M.HAPTIC_DUR[2]
  local pulses = M.HAPTIC_PULSES[key] or 1
  for i = 1, pulses do
    playHaptic(dur, (i < pulses) and dur or 0)   -- gap between pulses, none after the last
  end
end

-- Sound plus haptic cue for one event. A muted event (SOUNDS.key == false)
-- skips playFile but still buzzes: haptic has its own on/off setting.
local function announce(key)
  playSound(M.SOUNDS[key])
  eventHaptic(key)
end

function M.update(state, now)
  now = now or nowMs()
  local snap   = M.readSnapshot()
  local result = M.evaluate(state, snap, now)
  result.snapshot = snap

  -- Each event fires once per transition (evaluate guarantees the one-shot).
  -- A missing WAV plays silently, no error.
  if result.homeSet      then announce("fix")  end
  if result.fixLostEvent then announce("lost") end
  if result.fixRecovered then announce("rec")  end

  return result
end

return M
