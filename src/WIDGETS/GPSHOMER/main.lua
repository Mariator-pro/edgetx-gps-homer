-- =====================================================================
-- main.lua  --  EdgeTX telemetry widget for GPS Homer.
-- =====================================================================
-- SD card path: /WIDGETS/GPSHOMER/main.lua
-- Requires the shared module /SCRIPTS/GPSHOMER/core.lua on the SD card.
--
-- Display ONLY: all telemetry/state logic lives in core.lua. The widget renders
-- the values core.update() returns and never derives state itself, so the tile
-- can never disagree with core's debounces / home-set / ENDED timing.
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

-- ---------------------------------------------------------------------------
-- Responsive scaling: positions scale with S against a 480 px reference; fonts
-- stay fixed EdgeTX stages and are chosen by measurement.
-- ---------------------------------------------------------------------------
local REF_W = 480
local S     = (LCD_W or REF_W) / REF_W
local function sx(v) return math.floor(v * S + 0.5) end

-- ---------------------------------------------------------------------------
-- Shared core module, loaded once for all instances. If it cannot be loaded the
-- widget shows a "Core missing" tile instead of evaluating anything (NFR-2).
-- ---------------------------------------------------------------------------
local CORE_PATH    = "/SCRIPTS/GPSHOMER/core.lua"
local COMPASS_PATH = "/SCRIPTS/GPSHOMER/compass.lua"   -- compass drawing, shared with other widgets
local core, compass
do
  local function load(path)
    local chunk = loadScript and loadScript(path)
    if chunk then
      local ok, mod = pcall(chunk)
      if ok then return mod end
    end
  end
  core, compass = load(CORE_PATH), load(COMPASS_PATH)   -- no compass: the core lists it as setup error
end

-- Tick throttle (core.PARAMS.TICK_MS, in getTime's 10 ms units) so the update
-- cadence is the same whether driven by refresh() or background(); a repeated
-- failure streak trips a terminal error tile instead of crashing.
local TICK_INTERVAL = core and math.max(1, math.floor(core.PARAMS.TICK_MS / 10)) or 10
local ERROR_LIMIT   = 5

-- ---------------------------------------------------------------------------
-- Colour palettes, set per frame from the Theme option. Escalation colours are
-- theme-independent (Designguide 2).
-- ---------------------------------------------------------------------------
local DARK = {
  transparent = false,
  panel  = lcd.RGB( 18,  20,  18),
  fg     = lcd.RGB(235, 235, 235),
  muted  = lcd.RGB(150, 150, 150),
  track  = lcd.RGB( 55,  58,  55),
  accent = lcd.RGB(124, 210,  48),
}
local LIGHT = {
  transparent = true,
  panel  = nil,
  fg     = lcd.RGB(  0,   0,   0),
  muted  = lcd.RGB( 90,  90,  90),
  track  = lcd.RGB(200, 200, 205),
  accent = lcd.RGB(  1, 152,   8),
}
local CRIT_COL = lcd.RGB(220,  40,  40)  -- red: sats bar stage <= 1, fix loss, errors
local WARN_COL = lcd.RGB(255, 180,   0)  -- yellow: sats bar stage 2
-- Mascot-eye colours (theme-independent).
local EYE_WHITE = lcd.RGB(245, 245, 245)
local EYE_RIM   = lcd.RGB( 20,  20,  20)

-- Active palette + brand colour, set per frame. Safe as module globals: refresh()
-- is the only draw path and only one instance draws at a time.
local COLORS = DARK
local BRAND  = DARK.accent

-- Resolve the brand/heading colour from the Accent option (Designguide 4):
-- 1 Default = palette accent, 2 Theme = COLOR_THEME_FOCUS, 3 Custom = AccentColor.
-- Only tints the heading, never the escalation colours.
local function brandColor(opt, customCol)
  if opt == 2 and lcd.getColor then
    local c = lcd.getColor(COLOR_THEME_FOCUS)
    if c then return c end
  elseif opt == 3 and customCol then
    local c = lcd.getColor and lcd.getColor(customCol) or customCol
    if c then return c end
  end
  return COLORS.accent
end

-- ---------------------------------------------------------------------------
-- Text helper: custom colour via CUSTOM_COLOR so a raw RGB never collides with
-- the size/attribute bits in the flags (Designguide 8). flags = size/align only.
-- ---------------------------------------------------------------------------
local function dtext(x, y, text, color, flags)
  lcd.setColor(CUSTOM_COLOR, color)
  lcd.drawText(x, y, text, CUSTOM_COLOR + (flags or 0))
end

-- Font stages, largest -> smallest.
local FONT_STEPS = { XXLSIZE, DBLSIZE, MIDSIZE, 0, SMLSIZE }

-- Text-metric caches: fonts never change at runtime, so measurements are
-- session-constant (height per font, width per font+text).
local FONT_H, TEXT_W = {}, {}
local function fontH(flags)
  flags = flags or 0
  local h = FONT_H[flags]
  if not h then h = select(2, lcd.sizeText("0", flags)); FONT_H[flags] = h end
  return h
end
-- Width cache is capped: every new live value (distance, voltage ...) adds an
-- entry, so it starts over once TEXT_W_MAX entries are stored.
local TEXT_W_MAX = 200
local textWCount = 0
local function textW(text, flags)
  flags = flags or 0
  local byFlag = TEXT_W[flags]
  if not byFlag then byFlag = {}; TEXT_W[flags] = byFlag end
  local w = byFlag[text]
  if not w then
    if textWCount >= TEXT_W_MAX then
      TEXT_W, textWCount = {}, 0
      byFlag = {}; TEXT_W[flags] = byFlag
    end
    w = lcd.sizeText(text, flags); byFlag[text] = w
    textWCount = textWCount + 1
  end
  return w
end

-- One stage smaller than `flag` (SMLSIZE stays SMLSIZE).
local function smallerFont(flag)
  for i = 1, #FONT_STEPS - 1 do
    if FONT_STEPS[i] == flag then return FONT_STEPS[i + 1] end
  end
  return SMLSIZE
end

-- Largest font stage whose text fits maxW x maxH; maxFont caps the largest step.
local function fitFont(text, maxW, maxH, maxFont)
  local capped = not maxFont
  for _, f in ipairs(FONT_STEPS) do
    if f == maxFont then capped = true end
    if capped and textW(text, f) <= maxW and (not maxH or fontH(f) <= maxH) then return f end
  end
  return SMLSIZE
end

-- Shrink `flag` step by step until `text` fits maxW (never below SMLSIZE).
local function fitWidth(text, flag, maxW)
  while flag ~= SMLSIZE and textW(text, flag) > maxW do
    flag = smallerFont(flag)
  end
  return flag
end

-- Number with its unit one font step smaller, bottom-aligned, sx(3) apart.
-- Returns the drawn width.
local function drawValueUnit(x, y, value, unit, color, valueFlag)
  dtext(x, y, value, color, valueFlag)
  local vw, vh = textW(value, valueFlag), fontH(valueFlag)
  local uf     = smallerFont(valueFlag)
  local uw, uh = textW(unit, uf), fontH(uf)
  dtext(x + vw + sx(3), y + (vh - uh), unit, color, uf)
  return vw + sx(3) + uw
end

-- Width of a value+unit pair as drawValueUnit lays it out.
local function valueUnitW(value, unit, flag)
  return textW(value, flag) + sx(3) + textW(unit, smallerFont(flag))
end

-- ---------------------------------------------------------------------------
-- Value formatting (Widget-only; core delivers raw values)
-- ---------------------------------------------------------------------------

-- Distance is always a whole number, also above 1 km (unit drawn separately).
local function fmtDist(m)
  if not m then return "--" end
  return string.format("%d", math.floor(m + 0.5))
end

-- Shared with the tool, so both read identically. Guarded like every other
-- core lookup here: without core the widget only draws the reinstall tile.
local coord = core and core.formatCoord


-- ---------------------------------------------------------------------------
-- Heading + status/error tiles (shared helper, Spec 4.1)
-- ---------------------------------------------------------------------------

-- Page header: accent square + "GPS", SMLSIZE; the
-- error tiles pass the brand name instead.
local function headerW(label) return sx(5) + sx(3) + textW(label or "GPS", SMLSIZE) end
local function drawHeader(x, y, label)
  local h  = fontH(SMLSIZE)
  local sq = sx(5)
  lcd.drawFilledRectangle(x, y + math.floor((h - sq) / 2), sq, sq, BRAND)
  dtext(x + sq + sx(3), y, label or "GPS", BRAND, SMLSIZE)
  return headerW(label)
end

-- Decorative googly eyes beside the brand heading (error tiles only): pupils
-- circle every 1.8 s, a blink every 2.5 s for 0.25 s.
local function drawMascotEyes(x, y, w, h)
  local t     = getTime()
  local r     = math.max(sx(3), math.floor(h * 0.30))
  local cy    = y + math.floor(h / 2)
  local cx1   = x + r
  local cx2   = cx1 + 2 * r + sx(2)
  local blink = (t % 250) < 25
  local ph    = (t % 180) / 180 * 2 * math.pi
  local dx    = math.floor(math.cos(ph) * r * 0.4)
  local dy    = math.floor(math.sin(ph) * r * 0.4)
  for _, cx in ipairs({ cx1, cx2 }) do
    lcd.drawFilledCircle(cx, cy, r, EYE_RIM)
    lcd.drawFilledCircle(cx, cy, r - 1, EYE_WHITE)
    if blink then
      lcd.drawFilledRectangle(cx - r, cy - sx(1), 2 * r, math.max(2, sx(2)), EYE_RIM)
    else
      lcd.drawFilledCircle(cx + dx, cy + dy, math.max(1, math.floor(r * 0.5)), EYE_RIM)
    end
  end
end

-- Height of the brand-heading band: top pad + the taller of text / eyes.
local function headingBandH(eyes)
  local hh = fontH(SMLSIZE)
  return sx(4) + (eyes and math.max(hh, sx(14)) or hh) + sx(2)
end

-- Top-left "GPS-HOMER" brand heading in BRAND; the mascot eyes only on error
-- tiles (ENDED and the splash tiles stay calm).
local function drawBrandHeading(eyes)
  local pad  = sx(4)
  local used = drawHeader(pad, pad, "GPS-HOMER")   -- same square as the page header
  if eyes then
    drawMascotEyes(pad + used + sx(6), pad, sx(20), math.max(fontH(SMLSIZE), sx(14)))
  end
end

-- Centered message lines below topY (never slide up into a header above them).
local function drawCenteredLines(z, lines, topY, font)
  topY = topY or 0
  font = font or SMLSIZE
  local lineH  = fontH(font) + sx(3)
  local startY = topY + math.floor(((z.h - topY) - #lines * lineH) / 2)
  if startY < topY then startY = topY end
  for i, t in ipairs(lines) do
    if t then
      dtext(math.floor((z.w - textW(t, font)) / 2), startY + (i - 1) * lineH, t, COLORS.fg, font)
    end
  end
end

-- Message tile (ENDED / errors): brand heading + up to three centered lines.
-- The heading is kept as long as possible; the message font shrinks first,
-- then (three lines: ENDED) the title line goes so the heading stays over the
-- two position lines, and the heading is only dropped once even that no
-- longer fits. Priority: header+STD -> header+SML -> header+2 SML -> STD -> SML
-- -> 2 SML.
-- eyes = mascot beside the heading (error tiles only).
local function drawStatusTile(z, line1, line2, eyes, line3)
  local lines = { line1, line2, line3 }
  local n     = #lines
  local hb    = headingBandH(eyes)
  local stdH  = fontH(0) + sx(3)
  local smlH  = fontH(SMLSIZE) + sx(3)
  if z.h - hb >= n * stdH then
    drawBrandHeading(eyes); drawCenteredLines(z, lines, hb, 0)
  elseif z.h - hb >= n * smlH then
    drawBrandHeading(eyes); drawCenteredLines(z, lines, hb, SMLSIZE)
  elseif line3 and z.h - hb >= 2 * smlH then
    drawBrandHeading(eyes); drawCenteredLines(z, { line2, line3 }, hb, SMLSIZE)
  elseif z.h >= n * stdH then
    drawCenteredLines(z, lines, 0, 0)
  elseif z.h >= n * smlH or not line3 then
    drawCenteredLines(z, lines, 0, SMLSIZE)
  else
    drawCenteredLines(z, { line2, line3 }, 0, SMLSIZE)
  end
end

-- Status line with 0-3 trailing dots (one step per DOT_PERIOD). Centred as if
-- all three dots were present, dots drawn left-fixed after the text, so the
-- text never jitters.
local DOT_PERIOD = 50   -- getTime ticks per dot (~0.5 s)
local function drawWaitingStatus(cx, y, base)
  local n      = math.floor(getTime() / DOT_PERIOD) % 4
  local startX = cx - math.floor(textW(base .. "...", SMLSIZE) / 2)
  dtext(startX, y, base, COLORS.muted, SMLSIZE)
  if n > 0 then dtext(startX + textW(base, SMLSIZE), y, string.rep(".", n), COLORS.muted, SMLSIZE) end
end

-- Splash tile (WAITING / ACQUIRING): big centred GPS-HOMER title over the
-- animated status line and an optional third line. The title font is sized to
-- a fixed-width anchor (one step smaller than what fits 95 % x 50 %) so it does
-- not depend on the status text. Drop order on short zones: title, third line.
local TITLE_SIZE_REF = string.rep("M", 8)
local function drawSplashTile(z, base, third)
  local pad, gap, lineGap = sx(4), sx(4), sx(2)
  local cx     = math.floor(z.w / 2)
  local tFlag  = smallerFont(fitFont(TITLE_SIZE_REF, math.floor(z.w * 0.95), math.floor(z.h * 0.5)))
  local titleH = fontH(tFlag)
  local subH   = fontH(SMLSIZE)
  local blockH = subH + lineGap + subH          -- status + third line
  local avail  = z.h - 2 * pad
  local function drawBlock(sy)
    drawWaitingStatus(cx, sy, base)
    if third then
      dtext(cx - math.floor(textW(third, SMLSIZE) / 2), sy + subH + lineGap, third, COLORS.muted, SMLSIZE)
    end
  end
  if avail >= titleH + gap + blockH then
    local top = math.floor((z.h - (titleH + gap + blockH)) / 2)
    dtext(cx - math.floor(textW("GPS-HOMER", tFlag) / 2), top, "GPS-HOMER", BRAND, tFlag)
    drawBlock(top + titleH + gap)
  elseif avail >= blockH then
    drawBlock(math.floor((z.h - blockH) / 2))
  else
    drawWaitingStatus(cx, math.floor((z.h - subH) / 2), base)
  end
end

-- Pulsing red dot, top-right (fades in and out every 2 s); the caller draws it only
-- while telemetry is arriving. drawFilledCircle has no opacity, so the colour is
-- blended by hand between the background and red (light theme: white, the real
-- background there depends on the radio theme).
local HEARTBEAT_PERIOD = 200   -- getTime ticks
local HEARTBEAT_RED    = { 220, 40, 40 }
local HEARTBEAT_BG     = { dark = { 18, 20, 18 }, light = { 255, 255, 255 } }
local function drawHeartbeat(ctx)
  local t  = 0.5 - 0.5 * math.cos(2 * math.pi * (getTime() % HEARTBEAT_PERIOD) / HEARTBEAT_PERIOD)
  local bg = COLORS.transparent and HEARTBEAT_BG.light or HEARTBEAT_BG.dark
  local function mix(i) return math.floor(bg[i] + (HEARTBEAT_RED[i] - bg[i]) * t + 0.5) end
  local r = sx(3)
  lcd.drawFilledCircle(ctx.zone.w - sx(4) - r, sx(4) + r, r, lcd.RGB(mix(1), mix(2), mix(3)))
end

-- ---------------------------------------------------------------------------
-- Direction arrow (ACTIVE, course valid) -- Designguide 7.1
-- ---------------------------------------------------------------------------

-- A point at polar (radius, angDeg) around (cx, cy), rotated by relDeg, with
-- 0 deg = straight up and positive angles clockwise (screen convention).
local function rot(cx, cy, radius, angDeg, relDeg)
  local a = math.rad(relDeg + angDeg)
  return math.floor(cx + radius * math.sin(a) + 0.5),
         math.floor(cy - radius * math.cos(a) + 0.5)
end

-- Arrow from the shared compass (notched dart, tip at radius r).
local function drawArrow(cx, cy, r, deg, col) compass.arrow(cx, cy, r, deg, col) end

-- House on the home point, from the shared compass.
local function drawHouse(cx, cy, r, col) compass.house(cx, cy, r, col, COLORS.track) end

-- Space reserved outside the ring for the letters: the shared compass puts them
-- on its letter track; 75 % of the reported SMLSIZE height (generous leading,
-- glyphs about half of it) plus the half band.
local function ringMargin() return math.floor(fontH(SMLSIZE) * 0.75) + sx(2) end

local RING_W = math.max(2, sx(2))   -- home dot and arrow inset in the boxes without a ring

local function drawCrosshair(cx, cy, r, col) compass.crosshair(cx, cy, r, RING_W, col) end

-- Compass mode (widget option): 1 Nose up = OSD style, up is the flight
-- direction, the arrow is the steering hint to home, the ring turns with the
-- course. 2 North up = map style, the ring is fixed, the arrow is the course
-- and an H on the ring marks home. Drawing in the shared compass.lua.
local NORTH_UP = false
local function compassColors() return { track = COLORS.track, fg = COLORS.fg, muted = COLORS.muted } end
local function drawCompassArrow(cx, cy, R, d, compact)
  compass.draw(cx, cy, R, { course = d.courseValid and (d.course or 0) or nil, rel = d.rel,
                            bearing = d.bearingToHome }, NORTH_UP, compact, compassColors())
end

-- Ring radius for a W x areaH box, capped at rCap: with the letters outside
-- when they fit (ringMargin), else compact, filling the box up to sx(2)
-- (room for the home dot). Below sx(12) there is no ring at all.
-- Returns R, compact.
local function ringFit(W, areaH, rCap)
  local half = math.floor(math.min(W, areaH) / 2)
  local R    = math.min(half - ringMargin(), rCap)
  if R >= sx(12) then return R, false end
  return math.min(half - sx(2), rCap), true
end

-- ---------------------------------------------------------------------------
-- ACTIVE renderer (the only bespoke renderer)
-- ---------------------------------------------------------------------------

-- Layout is picked by measured fit against the real font metrics. TIER_TOL
-- keeps a one-pixel difference at a boundary from flipping the layout.
local TIER_TOL = sx(4)
local GAP      = sx(4)

-- Sats block (top of the list, the primary value): the count in MIDSIZE
-- (default font in MEDIUM), "SATS" caption and the signal bars beside it on
-- its baseline. Below it the value list in SMLSIZE: one row per metric, label
-- left (muted), value+unit right-aligned so the numbers line up.
-- Units follow the radio's system setting (read once with core), so the rows
-- are fixed at load. ALT and SPD are shown as the radio's sensors deliver them (the sensor
-- unit is set on the radio), so the setting only labels them; the distance is
-- computed from the coordinates in metres and is scaled to the display unit.
local IMPERIAL  = core and core.PARAMS.UNITS == "imperial"
local DIST_F    = IMPERIAL and 3.28084 or 1
local LIST_ROWS = {
  { key = "alt",  label = "ALT",  unit = IMPERIAL and "ft"  or "m",    ref = "9999"  },
  { key = "dist", label = "DIST", unit = IMPERIAL and "ft"  or "m",    ref = "9999"  },
  { key = "spd",  label = "SPD",  unit = IMPERIAL and "mph" or "km/h", ref = "99.9"  },
}
local LABEL_GAP = sx(6)
-- Header band height plus the gap to the sats block (sx(1), anchored so the
-- distance stays constant on every zone). Measured per call: lcd.sizeText is
-- not valid before the first frame.
local function headerH() return fontH(SMLSIZE) + sx(1) end

-- Signal-style bars: five bars of rising height, filled from the sat count
-- (thresholds below), track colour when empty.
local SATS_BAR_MIN = { 4, 6, 10, 15, 20 }   -- sats needed for bar 1..5
-- Digits inside a text box (shares of its reported height, which includes generous
-- line spacing): baseline and digit height, measured for SMLSIZE to XXLSIZE in the
-- TX15 and TX16S MK3 simulators (baseline 0.76 to 0.79, height 0.53 to 0.68: the
-- smaller value keeps the bars from rising above the digits).
local CAP_BASE, CAP_H = 0.778, 0.54
local BAR_W, BAR_GAP = sx(3), sx(1)
local BARS_W = #SATS_BAR_MIN * (BAR_W + BAR_GAP) - BAR_GAP
local function satsBars(sats)
  local n = 0
  for i, min in ipairs(SATS_BAR_MIN) do if sats >= min then n = i end end
  return n
end
local function drawSatsBars(x, y, h, sats, col)
  local n = satsBars(sats or 0)
  for i = 1, #SATS_BAR_MIN do
    local bh = math.max(sx(2), math.floor(h * i / #SATS_BAR_MIN))
    lcd.drawFilledRectangle(x + (i - 1) * (BAR_W + BAR_GAP), y + h - bh, BAR_W, bh,
      (i <= n) and col or COLORS.track)
  end
end

-- Heights below what lcd.sizeText reports: EdgeTX includes generous line
-- spacing (SMLSIZE ~18 px for ~9 px glyphs on 480 px radios), so rows sit on
-- a tighter pitch and the sats block gives up some of its leading, or three
-- rows would not fit a half zone on a 480 x 272 radio.
local LIST_FONT = SMLSIZE
local function satsBlockH(bf) return fontH(bf) - sx(4) end
-- Minimum column width for the block, from the "99" reference.
local function satsBlockW(bf)
  return textW("99", bf) + LABEL_GAP + textW("SATS", SMLSIZE) + LABEL_GAP + BARS_W
end

-- DOP from the FC on the ground ("PDOP 1.3", INAV / ArduPilot "HDOP"), shown
-- on the preflight page only.
local function dopText(dop)
  if dop < 9.95 then return string.format("%.1f", dop) end
  return string.format("%d", math.min(99, math.floor(dop + 0.5)))
end
-- Colour stages like the sats, from the core's DOP stage.
local function dopColor(dop, kind)
  local s = core.dopStage(dop, kind)
  return (s == 0 and COLORS.accent) or (s == 1 and WARN_COL) or CRIT_COL
end

-- Column width from fixed references (not the live text) so it never jumps.
local function listColW(bf)
  local lw, vw = 0, 0
  for _, r in ipairs(LIST_ROWS) do
    lw = math.max(lw, textW(r.label, SMLSIZE))
    vw = math.max(vw, valueUnitW(r.ref, r.unit, LIST_FONT))
  end
  return math.max(lw + LABEL_GAP + vw, satsBlockW(bf))
end
-- Row band: 20 % of the height under the header, at least one SMLSIZE line
-- (the sibling widgets' info-row band), so the rows spread over the tile.
local function listPitch(H) return math.max(fontH(LIST_FONT), math.floor(H * 0.20)) end

local function listValue(r, d)
  if r.key == "dist" then return fmtDist(d.distanceM and d.distanceM * DIST_F) end
  if r.key == "alt"  then return d.alt  and string.format("%d",   math.floor(d.alt + 0.5)) or "--" end
  if not d.gspd then return "--" end
  -- From 100 on without the decimal, so "99.9" is the widest value (narrow column).
  if d.gspd >= 99.95 then return string.format("%d", math.floor(d.gspd + 0.5)) end
  return string.format("%.1f", d.gspd)
end

-- Sats colour by bar stage: <= 1 bar or debounced fix loss red, 2 bars yellow,
-- 3+ bars green (palette accent). Count and bars share it.
local function satsColor(sats, fixLost)
  if fixLost then return CRIT_COL end
  if not sats then return COLORS.fg end   -- missing value: neutral, not 0 sats
  local n = satsBars(sats)
  if n <= 1 then return CRIT_COL end
  if n == 2 then return WARN_COL end
  return COLORS.accent
end

-- Sats block: count, caption LABEL_GAP behind it (moves with the digit count,
-- the same gap the sibling widgets keep behind their big value), bars
-- right-aligned with the value column.
local function drawSatsBlock(x0, y, colW, bf, d)
  local col  = satsColor(d.sats, d.fixLost)
  local base = y + fontH(bf)
  local smlH = fontH(SMLSIZE)
  local txt  = d.sats and tostring(d.sats) or "--"
  dtext(x0, y, txt, col, bf)
  dtext(x0 + textW(txt, bf) + LABEL_GAP, base - smlH, "SATS", COLORS.muted, SMLSIZE)
  -- bars at most as tall as the digits of the count (top of the digits to their baseline)
  local bh = fontH(bf)
  local digBase, digH = math.floor(bh * CAP_BASE + 0.5), math.floor(bh * CAP_H + 0.5)
  drawSatsBars(x0 + colW - BARS_W, y + digBase - digH, digH, d.sats, col)
  return satsBlockH(bf)
end

-- One list row: label left, value (+ unit) right-aligned.
local function drawRow(x0, y, colW, r, d)
  local v = listValue(r, d)
  dtext(x0, y, r.label, COLORS.muted, LIST_FONT)
  drawValueUnit(x0 + colW - valueUnitW(v, r.unit, LIST_FONT), y, v, r.unit, COLORS.fg, LIST_FONT)
end

-- Rows sit in equal bands stacked up from the bottom edge (`bottom` = tile
-- bottom, pad from the zone edge), each row's text centred in its band; spare
-- height opens up between the sats block and the list.
local function drawList(x0, bottom, colW, rows, rowH, d)
  local y = bottom - #rows * rowH + math.floor((rowH - fontH(LIST_FONT)) / 2)
  for _, r in ipairs(rows) do
    drawRow(x0, y, colW, r, d)
    y = y + rowH
  end
end

-- Tier thresholds. Checks are in absolute pixels because fonts do NOT scale
-- with S (only positions do). The reference texts and height stacks are the
-- ones the sibling widgets use, so every tile on a screen switches tier at the
-- same zone size.
local function activeFitsFull(W, H)
  local gap   = sx(4)
  local gridW = textW("RSS -000 dBm", SMLSIZE) + gap
              + textW("FM Angle?", SMLSIZE) + gap
              + textW("LQ 100 %", SMLSIZE) + sx(2)
  local smlH  = fontH(SMLSIZE)
  local hdrH  = smlH                            -- compact header (one text line, no padding)
  local needH = hdrH + sx(1)                    -- header + gap to content
              + fontH(MIDSIZE) + sx(1) + sx(12) -- big value band + gap + min bar
              + sx(3) + 2 * smlH                -- gap + two info rows
  return W >= gridW - TIER_TOL and H >= needH - TIER_TOL
end

-- MEDIUM spreads header + 4 rows as evenly-spaced lines, so it holds as long
-- as that pitch keeps a compressed (smlH - sx(5)); below that it drops to SMALL.
local function activeFitsMedium(W, H)
  local smlH  = fontH(SMLSIZE)
  local needH = smlH + 4 * (smlH - sx(5))   -- header + four rows at a compressed pitch
  local needW = textW("RSS -000 dBm", SMLSIZE) + sx(8)
              + textW("MODE 150Hz", SMLSIZE)
  return W >= needW - TIER_TOL and H >= needH - TIER_TOL
end

-- Direction box: the arrow (or the absolute home direction when the course is
-- invalid) centred in x0..x0+W / top..top+boxH. Arrow radius = what fits the box,
-- capped at rCap. The degree label sits right of the arrow, vertically centred,
-- with the largest font that fits; if even SMLSIZE does not fit beside it, the
-- arrow shrinks and the label goes below (never in SMALL, which has no label).
-- Ring without arrow or H plus a status line where "HOME <rel>" normally sits:
-- READY ("READY TO FLY" / "NO HOME") and standing on the home point ("AT HOME").
-- SMALL has no room for the ring: the word alone, centred, in SMLSIZE.
local function drawRingStatus(x0, top, W, boxH, d, rCap, small, txt, short, col, house)
  local cx    = x0 + math.floor(W / 2)
  local smlH  = fontH(SMLSIZE)
  local areaH = boxH - smlH - sx(2)
  local R, compact = ringFit(W, areaH, rCap)
  if small then
    -- Same SMLSIZE as the arrow's label so the box does not jump between
    -- states; the long form when it fits, else the short word.
    if textW(txt, SMLSIZE) > W then txt = short end
    dtext(x0 + math.floor((W - textW(txt, SMLSIZE)) / 2), top + math.floor((boxH - smlH) / 2), txt, col, SMLSIZE)
    return
  end
  -- Status as the bottom line of the box (level with the last list row);
  -- above it the ring when it has room, else only the house (AT HOME).
  if R >= sx(12) then
    local rcy = top + math.floor(areaH / 2)
    compass.ring(cx, rcy, R, NORTH_UP and 0 or -(d.course or 0), nil, compact, NORTH_UP, compassColors())
    if house then drawHouse(cx, rcy, math.floor(R * 0.55), COLORS.fg) end
  else
    if textW(txt, SMLSIZE) > W then txt = short end
    local hr = math.floor(math.min(W, areaH) / 2 * 0.55)
    if house and hr >= sx(8) then drawHouse(cx, top + math.floor(areaH / 2), hr, COLORS.fg) end
  end
  dtext(x0 + math.floor((W - textW(txt, SMLSIZE)) / 2), top + boxH - smlH, txt, col, SMLSIZE)
end

-- FC status that replaces the "HOME <rel>" line: long text, short form, colour.
-- Colour of a label from the shared compass (colour key).
local function labelCol(k)
  return (k == "warn" and WARN_COL) or (k == "crit" and CRIT_COL) or (k == "muted" and COLORS.muted) or COLORS.fg
end

local function drawDirection(x0, top, W, boxH, d, rCap, small)
  local cx = x0 + math.floor(W / 2)
  local cy = top + math.floor(boxH / 2)
  -- What to show and the text under it come from the shared compass:
  -- READY / NO HOME ring, AT HOME house, or the arrow.
  local kind, lb = compass.label({ gpsState = d.gpsState, noHome = d.noHome, atHome = d.atHome, alert = d.alert,
                                   courseValid = d.courseValid, rel = d.rel, sector = d.sector, bearing = d.bearingToHome },
                                 { ahead = core.PARAMS.AHEAD_DEG, behind = core.PARAMS.BEHIND_DEG })
  if kind ~= "arrow" then
    drawRingStatus(x0, top, W, boxH, d, rCap, small, lb.text, lb.short, labelCol(lb.col), kind == "house")
    return
  end
  do
    -- Label under / beside the ring: "HOME" with the steering hint or the
    -- absolute bearing; an FC alert takes the slot without the caption, its
    -- short form when the long one does not fit. `ref` keeps the slot steady.
    local lbl, ref, cap, lblCol = lb.text, lb.ref, lb.cap, labelCol(lb.col)
    if not cap then
      lbl = (not small and textW(lb.text, SMLSIZE) <= W) and lb.text or lb.short
      ref = lbl
    end
    local smlH = fontH(SMLSIZE)
    -- Compass ring + arrow inside (55 % of the ring), degree label at the box
    -- bottom.
    local areaH = (lbl ~= "") and (boxH - smlH - sx(2)) or boxH
    local R, compact = ringFit(W, areaH, rCap)
    if not small and R >= sx(12) then
      local rcy = top + math.floor(areaH / 2)
      drawCompassArrow(cx, rcy, R, d, compact)
      if lbl ~= "" then
        -- "HOME  30 R": caption muted, value fg, the pair centred under the ring.
        local ly = top + areaH + sx(2)
        if cap then
          local cw, vw = textW(cap, SMLSIZE), textW(lbl, SMLSIZE)
          local lx  = x0 + math.floor((W - (cw + LABEL_GAP + vw)) / 2)
          dtext(lx, ly, cap, COLORS.muted, SMLSIZE)
          dtext(lx + cw + LABEL_GAP, ly, lbl, COLORS.fg, SMLSIZE)
        else
          dtext(x0 + math.floor((W - textW(lbl, SMLSIZE)) / 2), ly, lbl, lblCol, SMLSIZE)
        end
      end
      return
    end
    -- No room for the lettered ring: arrow (in SMALL inside a bare band when
    -- it fits), label below (or beside in SMALL).
    local r = math.min(math.floor(math.min(boxH, W) / 2), rCap)
    if r < sx(8) then r = sx(8) end
    if small then
      -- Ring and label centred as one group; the label slot is measured from
      -- the "180 R" reference so the group does not shift with the value.
      local avail, refW = W - 2 * r - GAP, textW(ref, SMLSIZE)
      local lw = 0
      if lbl ~= "" and refW <= avail then
        if not cap then
          lw = refW
        elseif 2 * smlH + sx(1) <= 2 * r then
          lw = math.max(textW("HOME", SMLSIZE), refW)
        elseif textW("HOME", SMLSIZE) + LABEL_GAP + refW <= avail then
          lw = textW("HOME", SMLSIZE) + LABEL_GAP + refW
        else
          lw = refW
        end
      end
      cx = x0 + math.floor((W - 2 * r - (lw > 0 and GAP + lw or 0)) / 2) + r
    end
    local side = x0 + W - (cx + r) - GAP
    if lbl ~= "" and not small and boxH - smlH - sx(2) >= 2 * sx(8) then
      -- Label below the arrow (list layout); the arrow gives up the label height.
      r  = math.min(r, math.floor((boxH - smlH - sx(2)) / 2))
      cy = top + math.floor((boxH - smlH - sx(2)) / 2)
      dtext(x0 + math.floor((W - textW(lbl, SMLSIZE)) / 2), top + boxH - smlH, lbl, lblCol, SMLSIZE)
    elseif lbl ~= "" and textW(ref, SMLSIZE) <= side then
      -- Beside the arrow: muted "HOME" caption over the value when two lines
      -- fit the arrow height, else on one line, else the value alone.
      local lx, cw = cx + r + GAP, textW("HOME", SMLSIZE) + LABEL_GAP
      if not cap then
        dtext(lx, cy - math.floor(smlH / 2), lbl, lblCol, SMLSIZE)
      elseif 2 * smlH + sx(1) <= 2 * r then
        dtext(lx, cy - smlH - math.floor(sx(1) / 2), "HOME", COLORS.muted, SMLSIZE)
        dtext(lx, cy + math.ceil(sx(1) / 2), lbl, COLORS.fg, SMLSIZE)
      elseif cw + textW(ref, SMLSIZE) <= side then
        dtext(lx, cy - math.floor(smlH / 2), "HOME", COLORS.muted, SMLSIZE)
        dtext(lx + cw, cy - math.floor(smlH / 2), lbl, COLORS.fg, SMLSIZE)
      else
        dtext(lx, cy - math.floor(smlH / 2), lbl, COLORS.fg, SMLSIZE)
      end
    end
    if small and r >= sx(12) then
      -- Bare compass band around the arrow (no letters); North up puts the
      -- home dot on the band.
      drawCompassArrow(cx, cy, r - sx(1), d, true)
    elseif (NORTH_UP or not d.courseValid) and d.bearingToHome then
      -- Map style without a ring: course arrow (crosshair without a course),
      -- home as a dot on the rim.
      local dr = RING_W + sx(1)
      local hx, hy = rot(cx, cy, r - dr, d.bearingToHome, 0)
      lcd.drawFilledCircle(hx, hy, dr, COLORS.fg)
      if d.courseValid then
        drawArrow(cx, cy, r - 2 * dr - sx(1), d.course or 0, COLORS.fg)
      else
        drawCrosshair(cx, cy, r - 2 * dr - sx(1), COLORS.fg)
      end
    elseif d.courseValid then
      drawArrow(cx, cy, r, d.rel, COLORS.fg)
    else
      drawCrosshair(cx, cy, r, COLORS.fg)
    end
  end
end

-- FULL tier: header, sats block (MIDSIZE) over the three rows spread down to
-- the bottom edge, ring + arrow in the rest of the width.
local function drawActiveFull(W, H, x0, y0, d)
  drawHeader(x0, y0)
  local top  = y0 + headerH()
  local Hl   = H - headerH()
  local colW = listColW(MIDSIZE)
  drawSatsBlock(x0, top, colW, MIDSIZE, d)
  drawList(x0, y0 + H, colW, LIST_ROWS, listPitch(Hl), d)
  local bx = x0 + colW + GAP
  drawDirection(bx, top, x0 + W - bx, Hl, d, sx(60), false)
end

-- MEDIUM tier: header (line 0) plus four evenly spread lines: sats block,
-- then ALT, DIST, SPD. The sats count takes the largest font (up to MIDSIZE)
-- that fits half the width and half the span from line 1 to line 3, so it
-- grows with the zone like the sibling widgets' big value. On a short zone
-- the pitch is floored so the rows keep a readable spacing. Direction box
-- right of the list.
local function drawActiveMedium(W, H, x0, y0, d)
  drawHeader(x0, y0)
  local smlH    = fontH(SMLSIZE)
  local span    = H - smlH
  local minSpan = 4 * (smlH - sx(4))
  if span < minSpan then span = minSpan end
  local function rowY(i) return y0 + math.floor(i * span / 4 + 0.5) end
  local top  = rowY(1)
  local bf   = fitFont("99", math.floor(W * 0.5), math.floor((rowY(3) - sx(2) - top) * 0.5), MIDSIZE)
  local colW = listColW(bf)
  drawSatsBlock(x0, top, colW, bf, d)
  for i, r in ipairs(LIST_ROWS) do drawRow(x0, rowY(i + 1), colW, r, d) end
  local bx = x0 + colW + GAP
  drawDirection(bx, top, x0 + W - bx, y0 + H - top, d, sx(60), false)
end

-- The whole ACTIVE tile: FULL, MEDIUM, or SMALL. SMALL degrades by the text
-- lines that fit: header once two fit, an ALT row under the sats count once
-- three fit, the sats block (count, caption, bars) always. The arrow gets
-- whichever layout leaves it larger: stacked (header,
-- sats, ALT, arrow below over the full width) or side by side (header, sats
-- and ALT in a left column, arrow right of it over the full height; the short
-- title leaves that room). The sats count takes the largest font (up to
-- MIDSIZE) that fits half the width and its band.
local function drawActive(W, H, x0, y0, d)
  if activeFitsFull(W, H) then
    drawActiveFull(W, H, x0, y0, d)
  elseif activeFitsMedium(W, H) then
    drawActiveMedium(W, H, x0, y0, d)
  else
    local smlH  = fontH(SMLSIZE)
    local nRows = math.floor((H + sx(1)) / (smlH + sx(1)))
    local hdr   = (nRows >= 2) and (smlH + sx(1)) or 0
    local altH  = (nRows >= 3) and (smlH + sx(1)) or 0
    local altR  = LIST_ROWS[1]
    local altW  = (altH > 0) and (textW(LIST_ROWS[1].label, SMLSIZE) + LABEL_GAP
                  + valueUnitW(LIST_ROWS[1].ref, LIST_ROWS[1].unit, LIST_FONT)) or 0
    local bfS   = fitFont("99", math.floor(W * 0.5), H - hdr - altH, MIDSIZE)
    local colW  = math.max(hdr > 0 and headerW() or 0, satsBlockW(bfS), altW)
    local rSide = math.floor(math.min(W - colW - GAP, H) / 2)
    local bfT   = fitFont("99", math.floor(W * 0.5), math.floor((H - hdr - altH - sx(2)) * 0.5), MIDSIZE)
    local satsH = fontH(bfT) + sx(1)
    local rTop  = math.floor(math.min(W, H - hdr - satsH - altH) / 2)
    if hdr > 0 then drawHeader(x0, y0) end
    if rSide >= rTop then
      -- Sats under the header (centred in the column when there is no ALT row),
      -- ALT on the bottom edge, arrow box right of the column.
      local sy = (altH > 0) and (y0 + hdr) or (y0 + hdr + math.floor((H - hdr - fontH(bfS)) / 2))
      drawSatsBlock(x0, sy, colW, bfS, d)
      if altH > 0 then drawList(x0, y0 + H, colW, { altR }, smlH, d) end
      drawDirection(x0 + colW + GAP, y0, W - colW - GAP, H, d, rSide, true)
    else
      drawSatsBlock(x0, y0 + hdr, W, bfT, d)
      if altH > 0 then drawList(x0, y0 + hdr + satsH + smlH, W, { altR }, smlH, d) end
      drawDirection(x0, y0 + hdr + satsH + altH, W, H - hdr - satsH - altH, d, rTop, true)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Preflight and end pages (flight phases PRE and ENDED): header and margins as
-- on the live tile, rows evenly spread below the header.
-- ---------------------------------------------------------------------------

-- Colour of a check level: 0 accent, 1 yellow, 2 red.
local function levelColor(level)
  if level == 2 then return CRIT_COL end
  if level == 1 then return WARN_COL end
  return COLORS.accent
end

-- Seconds left on a page timer that started at `since` (the core's ms clock,
-- getTime() * 10) and runs `total` ms.
local function secsLeft(since, total)
  return math.max(0, math.ceil((total - (getTime() * 10 - since)) / 1000))
end

-- Countdown at the bottom right: text left of a bar that runs empty. The text
-- shrinks to the seconds when the row is too narrow.
local function drawCountdown(x0, W, y, secs, total, label)
  local smlH = fontH(SMLSIZE)
  local barH = math.max(3, sx(6))
  local barW = math.max(sx(30), math.floor(W * 0.35))
  local bx   = x0 + W - barW
  local by   = y + math.floor((smlH - barH) / 2)
  lcd.drawFilledRectangle(bx, by, barW, barH, COLORS.track)
  local fw = math.floor(barW * math.max(0, math.min(1, secs / total)))
  if fw > 0 then lcd.drawFilledRectangle(bx, by, fw, barH, COLORS.muted) end
  local txt = string.format("%s in %d s", label, secs)
  if textW(txt, SMLSIZE) > bx - sx(6) - x0 then txt = string.format("%d s", secs) end
  dtext(bx - sx(6) - textW(txt, SMLSIZE), y, txt, COLORS.muted, SMLSIZE)
end

-- Status line: dot plus text in the level colour (GPS READY / FIX SETTLING / NO FIX).
local function drawStatusLine(x, y, st)
  local smlH = fontH(SMLSIZE)
  local r    = math.max(2, sx(4))
  local col  = levelColor(st.level)
  lcd.drawFilledCircle(x + r, y + math.floor(smlH / 2), r, col)
  dtext(x + 2 * r + sx(4), y, st.text, col, SMLSIZE)
  return 2 * r + sx(4) + textW(st.text, SMLSIZE)
end

-- Rows evenly spread below the header like MEDIUM (header = row 0, n rows, the
-- last at the bottom pad); the pitch never drops below a compressed line.
local function rowSpread(H, y0, n)
  local smlH    = fontH(SMLSIZE)
  local span    = H - smlH
  local minSpan = n * (smlH - sx(4))
  if span < minSpan then span = minSpan end
  return function(i) return y0 + math.floor(i * span / n + 0.5) end
end

-- Muted label followed by its value.
local function drawKV(x, y, label, value, col)
  dtext(x, y, label, COLORS.muted, SMLSIZE)
  dtext(x + textW(label, SMLSIZE), y, value, col or COLORS.fg, SMLSIZE)
end

-- Preflight page: satellites big (font box sized for "0.00V") with SATS and the bars as on the live view, then DOP and fix
-- type, the GPS status and the countdown to the flight page while the check
-- is met. Status and countdown rows are fixed, the countdown row stays empty
-- while it does not run, so nothing moves. Smaller zones keep sats, DOP/fix,
-- status and countdown as far as they fit (two rows: sats and status), the
-- shortest only the sats.
local function drawPre(W, H, x0, y0, r, state)
  local smlH   = fontH(SMLSIZE)
  local col    = satsColor(r.sats, r.fixLost)
  local satTxt = r.sats and tostring(r.sats) or "--"
  local st     = core.preflight(core.fixState(r), r.dop, r.dopKind)
  local secs   = state.readySince and secsLeft(state.readySince, core.PRE_HOLD_T)
  -- rows below the header at the compressed pitch
  local nRows  = math.floor((H - smlH) / (smlH - sx(4)))
  if nRows < 1 then
    local f = fitFont(satTxt .. " SATS", W, H)
    dtext(x0, y0 + math.floor((H - fontH(f)) / 2), satTxt .. " SATS", col, f)
    return
  end
  drawHeader(x0, y0)
  local bottomY = y0 + H - smlH
  local half    = math.floor(W / 2)
  local function countdown(y)
    if secs then drawCountdown(x0, W, y, secs, core.PRE_HOLD_T / 1000, "Flight page") end
  end
  local function infoRow(y)
    drawKV(x0, y, (r.dopKind or "PDOP") .. " ", r.dop and dopText(r.dop) or "--",
           r.dop and dopColor(r.dop, r.dopKind))
    drawKV(x0 + half, y, "FIX ", r.fix or "--")
  end

  if not activeFitsFull(W, H) then
    local k    = (activeFitsMedium(W, H) and nRows >= 4) and 4 or math.min(3, nRows)
    local rowY = rowSpread(H, y0, k)
    local top  = rowY(1)
    local bf   = fitFont("99", math.floor(W * 0.5), (k >= 2 and rowY(2) or y0 + H) - sx(2) - top, MIDSIZE)
    drawSatsBlock(x0, top, math.min(W, satsBlockW(bf)), bf, r)   -- bars right behind SATS
    if k == 4 then
      infoRow(rowY(2))
      drawStatusLine(x0, rowY(3), st)
      countdown(rowY(4))
    else
      -- no row of its own: the countdown joins the status line, the info row keeps its place
      if k >= 3 then infoRow(rowY(2)) end
      if k >= 2 then
        local cx = x0 + drawStatusLine(x0, rowY(k), st) + sx(8)
        if secs then drawCountdown(cx, x0 + W - cx, rowY(k), secs, core.PRE_HOLD_T / 1000, "Flight page") end
      end
    end
    return
  end

  -- FULL: the spare height is shared out evenly between the blocks.
  local top  = y0 + headerH()
  local bigF = fitFont("0.00V", math.floor(W * 0.5), math.floor((bottomY - top) * 0.4))
  local bigH = fontH(bigF)
  drawSatsBlock(x0, top, math.min(W, listColW(bigF)), bigF, r)   -- as on the live view, bigger count
  local fixed = bigH + 2 * smlH
  local gap   = math.max(0, math.floor((bottomY - top - fixed) / 3))
  local infoY = top + bigH + gap
  infoRow(infoY)
  drawStatusLine(x0, infoY + smlH + gap, st)
  countdown(bottomY)
end

-- End page: the flight's highest distance, altitude and speed and the landing
-- position, and the countdown to the wait page. On short zones the position
-- stays longest (it finds the model), the maxima go first; the shortest show
-- only the position (on two lines when one is too narrow).
local function drawEnded(W, H, x0, y0, r, state)
  local smlH = fontH(SMLSIZE)
  local function num(v, f) return v and (string.format("%d", math.floor(v * (f or 1) + 0.5))) or "--" end
  local du   = LIST_ROWS[2].unit
  local pos  = (r.lastLat and r.lastLon) and (coord(r.lastLat) .. ", " .. coord(r.lastLon)) or "--"
  local rows = {                          -- { order on screen, label, value, short label }
    { 4, "LAST POSITION", pos, "LAST POS" },
    { 1, "MAX DISTANCE", num(r.maxDistM, DIST_F) .. " " .. du, "MAX DIST" },
    { 2, "MAX ALTITUDE", num(r.maxAlt) .. " " .. LIST_ROWS[1].unit, "MAX ALT" },
    { 3, "MAX SPEED", num(r.maxGspd) .. " " .. LIST_ROWS[3].unit, "MAX SPD" },
  }
  local n = math.floor((H - smlH) / (smlH - sx(4)))   -- compressed lines below the header
  if n < 2 then
    if textW(pos, SMLSIZE) <= W or not r.lastLat then
      dtext(x0, y0 + math.floor((H - smlH) / 2), pos, COLORS.fg, SMLSIZE)
    else
      dtext(x0, y0, coord(r.lastLat), COLORS.fg, SMLSIZE)
      if H >= 2 * smlH - sx(4) then dtext(x0, y0 + smlH - sx(2), coord(r.lastLon), COLORS.fg, SMLSIZE) end
    end
    return
  end
  local k = math.min(#rows, n - 1)
  local keep = {}
  for i = 1, k do keep[i] = rows[i] end
  table.sort(keep, function(a, b) return a[1] < b[1] end)
  drawHeader(x0, y0)
  local rowY = rowSpread(H, y0, k + 1)
  for i, row in ipairs(keep) do
    local vw  = textW(row[3], SMLSIZE)
    local lbl = row[2]
    if textW(lbl, SMLSIZE) + sx(6) + vw > W then lbl = row[4] end   -- short label when the long one does not fit
    if textW(lbl, SMLSIZE) + sx(6) + vw <= W then                   -- a narrow zone keeps the value only
      dtext(x0, rowY(i), lbl, COLORS.muted, SMLSIZE)
    end
    dtext(x0 + W - vw, rowY(i), row[3], COLORS.fg, SMLSIZE)
  end
  drawCountdown(x0, W, rowY(k + 1), secsLeft(state.endedAt or 0, core.ENDED_HOLD_T),
                core.ENDED_HOLD_T / 1000, "Wait page")
end

-- ---------------------------------------------------------------------------
-- Tile dispatch: map the core's phase and GPS state to a screen (display
-- derivation, Spec 3.1). PRE: preflight page; FLIGHT: by the GPS state.
-- Stable errors win over volatile states (Spec 4.1 priority).
-- ---------------------------------------------------------------------------
local function drawTile(ctx, z, x0, y0, W, H)
  if not core then
    drawStatusTile(z, "Core missing", "Reinstall GPS Homer", true); return
  end
  if not compass then   -- the core names it in the settings tool
    drawStatusTile(z, "Configuration error", "Please check Tool Flight Bag", true); return
  end
  if ctx.fatalError then
    drawStatusTile(z, "Widget error", "Restart radio", true); return
  end

  local r = ctx.result
  if not r then
    drawSplashTile(z, "Waiting for telemetry"); return
  end
  -- Sensor existence comes from getFieldInfo and never flickers on a missed
  -- frame, so it wins over the volatile link state (no waiting tile flashing
  -- over a real setup error).
  if core.configDamaged or (r.snapshot and r.snapshot.sensorMissing) then
    drawStatusTile(z, "Configuration error", "Please check Tool Flight Bag", true); return
  end

  local ph, gs = r.phase, r.gpsState
  local linkUp = r.snapshot and r.snapshot.telem   -- heartbeat only while packets arrive
  if ph == "ENDED" then
    drawEnded(W, H, x0, y0, r, ctx.state)
  elseif ph == "PRE" then
    drawPre(W, H, x0, y0, r, ctx.state)
    if linkUp then drawHeartbeat(ctx) end
  elseif ph ~= "FLIGHT" then -- WAITING
    drawSplashTile(z, "Waiting for telemetry")
  elseif gs == "HOME" or gs == "READY" then
    -- READY = the same live view before home is set: no arrow/H, DIST "--",
    -- a status line instead of "HOME <rel>".
    ctx.smooth = ctx.smooth or {}
    ctx.smooth.rel    = compass.smooth(ctx.smooth.rel,    r.rel)
    ctx.smooth.course = compass.smooth(ctx.smooth.course, r.course)
    local d = {
      gpsState = gs, rel = ctx.smooth.rel, bearingToHome = r.bearingToHome, sector = r.sector,
      courseValid = r.courseValid, course = ctx.smooth.course, distanceM = r.distanceM, sats = r.sats,
      alt = r.alt, gspd = r.gspd, fixLost = r.fixLost, noHome = r.noHome, atHome = r.atHome,
      alert = r.alert,
    }
    drawActive(W, H, x0, y0, d)
    if linkUp then drawHeartbeat(ctx) end
  else -- ACQUIRING
    -- "4 Sats (min 6)": found so far, and the count home needs.
    drawSplashTile(z, "Searching satellites",
                   string.format("%d Sats (min %d)", r.sats or 0, core.PARAMS.HOME_MIN_SATS))
    if linkUp then drawHeartbeat(ctx) end
  end
end

-- ---------------------------------------------------------------------------
-- Widget lifecycle
-- ---------------------------------------------------------------------------
local function create(zone, opts)
  local ctx = {
    zone = zone, options = opts,
    lastTick = 0, errorStreak = 0, fatalError = false, result = nil,
  }
  if core then
    ctx.state = core.newState()
    ctx.state.useMsp = true   -- DOP over MSP: the widget shows it, the voice script does not
  end
  return ctx
end

local function update(ctx, opts)
  ctx.options = opts
end

-- One throttled, fault-tolerant data cycle (no lcd.*). background() only runs
-- off-screen, so refresh() must drive it too or the tile freezes. A repeated
-- failure streak trips the terminal error tile.
-- This widget's own copy of the incoming CRSF frames, drained once per tick and
-- handed to the core (DOP replies); the core decides what it takes.
local MAX_POPS_PER_TICK = 20

local function pollFrames(ctx)
  if not crossfireTelemetryPop then return end   -- no CRSF on this radio
  for _ = 1, MAX_POPS_PER_TICK do
    local cmd, data = crossfireTelemetryPop()
    if cmd == nil then break end
    core.handleFrame(ctx.state, cmd, data)
  end
end

local function tick(ctx)
  if not core or ctx.fatalError then return end
  local now = getTime()
  if ctx.lastTick ~= 0 and (now - ctx.lastTick) < TICK_INTERVAL then return end
  ctx.lastTick = now
  local ok, res = pcall(function()
    pollFrames(ctx)
    return core.update(ctx.state)
  end)
  if ok then
    ctx.result      = res
    ctx.errorStreak = 0
  else
    ctx.errorStreak = ctx.errorStreak + 1
    if ctx.errorStreak >= ERROR_LIMIT then ctx.fatalError = true end
  end
end

local function background(ctx)
  tick(ctx)
end

local function refresh(ctx, event, touchState)
  tick(ctx)   -- drive logic in the foreground too (background won't run then)

  local z = ctx.zone
  COLORS   = (ctx.options.Theme == 2) and LIGHT or DARK
  BRAND    = brandColor(ctx.options.Accent, ctx.options.AccentColor)
  NORTH_UP = (ctx.options.Compass == 2)

  -- Background per theme (Designguide 3): Dark paints its own panel; Light gets a
  -- milky overlay. Transparency choice 1..6 = 0..100 % see-through -> opacity
  -- 0..15 (15 = invisible); anything else (e.g. a pre-choice value) = default.
  if not COLORS.transparent then
    lcd.drawFilledRectangle(0, 0, z.w, z.h, COLORS.panel)
  else
    local trans = ctx.options.Transparency
    if type(trans) ~= "number" or trans < 1 or trans > 6 then trans = 3 end
    if trans < 6 then
      lcd.drawFilledRectangle(0, 0, z.w, z.h, COLOR_THEME_PRIMARY2, 3 * (trans - 1))
    end
  end

  -- Whole render is fault-tolerant so a draw error never crashes EdgeTX.
  local ok = pcall(function()
    local pad = sx(4)
    drawTile(ctx, z, pad, pad, z.w - 2 * pad, z.h - 2 * pad)
  end)
  if not ok then
    dtext(sx(4), sx(4), "Widget error", COLORS.muted, SMLSIZE)
  end
end

return {
  name    = "GPS Homer",
  options = {
    { "Theme",        CHOICE, 1, { "Dark", "Light" } },
    { "Compass",      CHOICE, 1, { "NoseUp", "NorthUp" } },
    { "Transparency", CHOICE, 3, { "0%", "20%", "40%", "60%", "80%", "100%" } },
    { "Accent",       CHOICE, 1, { "Default", "Theme", "Custom" } },
    { "AccentColor",  COLOR,  lcd.RGB(124, 210, 48) },
  },
  create     = create,
  update     = update,
  refresh    = refresh,
  background = background,
}
