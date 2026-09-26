-- =====================================================================
-- gpshom.lua  --  EdgeTX function script: GPS Homer voice events only.
-- =====================================================================
-- SD card path: /SCRIPTS/FUNCTIONS/gpshom.lua
-- Requires the shared module /SCRIPTS/GPSHOMER/core.lua on the SD card.
-- Plays the home-set / GPS-lost / GPS-recovered events (voice and haptic)
-- without any display, so it also runs on radios without a color screen.
-- Do not run it alongside the widget: both would announce every event.
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

local CORE_PATH = "/SCRIPTS/GPSHOMER/core.lua"

local core    -- the loaded core module
local state   -- core's caller-owned flight state

-- loadScript does file I/O, so load core once here, not every run.
-- Same cadence as the widget: run() fires every mixer cycle, the core needs 10 Hz.
local TICK_INTERVAL        -- getTime units, from core.PARAMS.TICK_MS
local lastTick             -- nil until the first run

local function init_func()
  core  = assert(loadScript(CORE_PATH))()
  state = core.newState()
  TICK_INTERVAL = math.max(1, math.floor(core.PARAMS.TICK_MS / 10))
end

-- pcall: a transient error in core must not halt this script -- it is the only
-- voice path here. But it must not stay silent forever either: after
-- ERROR_LIMIT consecutive failures, sound an alarm and rethrow so EdgeTX stops it.
local ERROR_LIMIT = 5
local errorStreak = 0

local function run_func()
  local now = getTime()
  if lastTick and now - lastTick < TICK_INTERVAL then return end
  lastTick = now
  local ok, err = pcall(core.update, state)
  if ok then
    errorStreak = 0
    return
  end
  errorStreak = errorStreak + 1
  if errorStreak >= ERROR_LIMIT then
    playTone(1600, 300, 0, PLAY_NOW)
    error(err)
  end
end

return { init = init_func, run = run_func }
