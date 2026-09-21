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
local CORE_PATH = "/SCRIPTS/GPSHOMER/core.lua"
local core
do
  local chunk = loadScript and loadScript(CORE_PATH)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok then core = mod end
  end
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
local function textW(text, flags)
  flags = flags or 0
  local byFlag = TEXT_W[flags]
  if not byFlag then byFlag = {}; TEXT_W[flags] = byFlag end
  local w = byFlag[text]
  if not w then w = lcd.sizeText(text, flags); byFlag[text] = w end
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

-- Decimal degrees -> 41\194\17637'18.56"N (degree sign as UTF-8 bytes, the only
-- non-ASCII glyph; EdgeTX renders it in its own GPS sensor view). Rounded to
-- 1/100 s in integer math so seconds can never print as 60.00.
local function dms(v, pos, neg)
  local hemi = (v < 0) and neg or pos
  local t = math.floor(math.abs(v) * 360000 + 0.5)   -- hundredths of a second
  local d = math.floor(t / 360000); t = t - d * 360000
  local m = math.floor(t / 6000);   t = t - m * 6000
  return string.format("%d\194\176%02d'%05.2f\"%s", d, m, t / 100, hemi)
end

-- Degree label from the nose-relative angle. Thresholds come from core.PARAMS
-- (never hard-coded): |rel| <= AHEAD_DEG -> "ahead", >= BEHIND_DEG -> "behind",
-- otherwise the magnitude with an L/R side.
local function relLabel(rel)
  if not rel then return "" end
  local a = math.abs(rel)
  if a <= core.PARAMS.AHEAD_DEG then return "ahead" end
  if a >= core.PARAMS.BEHIND_DEG then return "behind" end
  return string.format("%d %s", math.floor(a + 0.5), (rel > 0) and "R" or "L")
end

-- ---------------------------------------------------------------------------
-- Heading + status/error tiles (shared helper, Spec 4.1)
-- ---------------------------------------------------------------------------

-- Brand header for the ACTIVE tile: accent square + "GPS-HOMER", SMLSIZE.
local function headerW() return sx(5) + sx(3) + textW("GPS-HOMER", SMLSIZE) end
local function drawHeader(x, y)
  local h  = fontH(SMLSIZE)
  local sq = sx(5)
  lcd.drawFilledRectangle(x, y + math.floor((h - sq) / 2), sq, sq, BRAND)
  dtext(x + sq + sx(3), y, "GPS-HOMER", BRAND, SMLSIZE)
  return headerW()
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
  local used = drawHeader(pad, pad)   -- same square + label as the ACTIVE header
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
-- The heading is kept as long as possible; the message font shrinks first, the
-- heading is only dropped once even a small message no longer fits.
-- Priority (Spec 4.1): header+STD -> header+SML -> STD -> SML.
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
  elseif z.h >= n * stdH then
    drawCenteredLines(z, lines, 0, 0)
  else
    drawCenteredLines(z, lines, 0, SMLSIZE)
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

-- Splash tile (NO_TELEM / ACQUIRING): big centred GPS-HOMER title over the
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

-- Blinking red dot top-right while the telemetry link is up (1 s on / 1 s off);
-- stops the instant the link drops. Shown in ACTIVE and ACQUIRING.
local HEARTBEAT_R    = sx(3)
local HEARTBEAT_HALF = 100   -- getTime ticks per half period
local function drawHeartbeat(ctx, z)
  local snap = ctx.result and ctx.result.snapshot
  if not (snap and snap.telem) then return end
  if math.floor(getTime() / HEARTBEAT_HALF) % 2 ~= 0 then return end
  lcd.drawFilledCircle(z.w - sx(4) - HEARTBEAT_R, sx(4) + HEARTBEAT_R, HEARTBEAT_R, CRIT_COL)
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

-- Filled triangle with an outline fallback for builds without the filled variant
-- (verify on the simulator; the render is pcall-wrapped regardless).
local function fillTri(x1, y1, x2, y2, x3, y3, col)
  if lcd.drawFilledTriangle then
    lcd.drawFilledTriangle(x1, y1, x2, y2, x3, y3, col)
  elseif lcd.drawTriangle then
    lcd.drawTriangle(x1, y1, x2, y2, x3, y3, col)
  end
end

-- Filled dart with a tail notch ("paper plane"), rotated by rel. Four points:
-- tip (r, 0), wings (r, +/-140), tail notch (0.35 r, 180); drawn as two filled
-- triangles (tip-wingL-notch, tip-notch-wingR). Foreground fill: neutral, so it
-- is never read as part of the sats traffic light.
local function drawArrow(cx, cy, r, relDeg, col)
  local tx, ty = rot(cx, cy, r, 0, relDeg)
  local lx, ly = rot(cx, cy, r, -140, relDeg)
  local rx, ry = rot(cx, cy, r, 140, relDeg)
  local nx, ny = rot(cx, cy, r * 0.35, 180, relDeg)
  fillTri(tx, ty, lx, ly, nx, ny, col)
  fillTri(tx, ty, nx, ny, rx, ry, col)
end

-- Small house (standing on the home point): filled roof over a filled body,
-- door in track colour so it reads as a house on both themes. Radius r like
-- the arrow; the whole icon spans about 1.5 r and is centred on (cx, cy).
local function drawHouse(cx, cy, r, col)
  local roofTop, eave, base = cy - math.floor(r * 0.75), cy - math.floor(r * 0.1), cy + math.floor(r * 0.75)
  local halfRoof, halfBody = math.floor(r * 0.85), math.floor(r * 0.6)
  fillTri(cx, roofTop, cx - halfRoof, eave, cx + halfRoof, eave, col)
  lcd.setColor(CUSTOM_COLOR, col)
  lcd.drawFilledRectangle(cx - halfBody, eave, 2 * halfBody, base - eave, CUSTOM_COLOR)
  local dw = math.max(2, math.floor(r * 0.3))
  local dh = math.max(3, math.floor(r * 0.45))
  lcd.setColor(CUSTOM_COLOR, COLORS.track)
  lcd.drawFilledRectangle(cx - math.floor(dw / 2), base - dh, dw, dh, CUSTOM_COLOR)
end

-- Space reserved outside the ring for the letters: 75 % of the reported
-- SMLSIZE height (the reported height carries generous leading; glyphs are
-- about half of it), so the ring does not shrink for empty leading.
local function ringMargin() return math.floor(fontH(SMLSIZE) * 0.75) end

-- Compass ring: a band in track colour (RING_W thick) with N/E/S/W outside it
-- and short tick marks at the intercardinals, all rotated by `rot` (Nose up:
-- -course, so they show where north lies relative to the nose; North up: 0).
local CARDINALS = { "N", "E", "S", "W" }
local RING_W    = math.max(2, sx(2))   -- ring band thickness
local TICK_LEN  = math.max(3, sx(4))   -- intercardinal tick length outside the ring

-- Ring band: annulus when the build has it, else stacked circles. A full
-- 0..360 annulus draws nothing (EdgeTX turns it into a zero-length arc), so
-- the band is two half arcs; width = outer - inner radius.
local function drawRing(cx, cy, R)
  lcd.setColor(CUSTOM_COLOR, COLORS.track)
  if lcd.drawAnnulus then
    lcd.drawAnnulus(cx, cy, R - RING_W, R, 0, 180, CUSTOM_COLOR)
    lcd.drawAnnulus(cx, cy, R - RING_W, R, 180, 360, CUSTOM_COLOR)
  elseif lcd.drawCircle then
    for i = 0, RING_W - 1 do lcd.drawCircle(cx, cy, R - i, CUSTOM_COLOR) end
  end
end
-- Text centred on a circle of radius `tr` at angle `ang` (0 = up, clockwise).
local function drawRingText(cx, cy, tr, ang, txt, col)
  local x, y = rot(cx, cy, tr, ang, 0)
  dtext(x - math.floor(textW(txt, SMLSIZE) / 2), y - math.floor(fontH(SMLSIZE) / 2), txt, col, SMLSIZE)
end
-- Lubber line (Nose up): a fixed filled triangle at 12 o'clock on the letter
-- radius, tip towards the ring; the letter that turns underneath is left out.
local function drawNoseMark(cx, cy, tr)
  local h = math.max(3, math.floor(fontH(SMLSIZE) * 0.4))   -- half height
  local w = math.max(2, math.floor(h * 0.6))                 -- half width: slim
  local y = cy - tr
  fillTri(cx - w, y - h, cx + w, y - h, cx, y + h, COLORS.fg)
end

-- `skipAng` (optional): a cardinal that would touch the H badge drawn there
-- (half letter + badge radius) is left out; in Nose up the nose mark at 0
-- deg does the same.
-- `compact`: the bare band (no letters, ticks or nose mark) for boxes too
-- low for the letter margin, so the ring can use the whole box.
local NORTH_UP = false
local function drawCompass(cx, cy, R, rotDeg, skipAng, compact)
  drawRing(cx, cy, R)
  local tr = R + math.floor(fontH(SMLSIZE) / 2)   -- letters outside the ring
  local minSep = math.deg((textW("W", SMLSIZE) / 2 + fontH(SMLSIZE) / 2) / tr)
  if compact then return tr end
  if not NORTH_UP then skipAng = 0; drawNoseMark(cx, cy, tr) end
  for i, c in ipairs(CARDINALS) do
    local ang  = (i - 1) * 90 + rotDeg
    local diff = skipAng and math.abs(((ang - skipAng + 540) % 360) - 180) or 999
    if diff > minSep then drawRingText(cx, cy, tr, ang, c, COLORS.muted) end
  end
  -- Tick marks: at the cardinals a short tick inside the band (the letter sits
  -- outside); at the intercardinals a longer tick crossing the band, inside to
  -- outside. The outer part is skipped under the H badge / nose mark.
  if lcd.drawLine then
    lcd.setColor(CUSTOM_COLOR, COLORS.track)   -- same colour as the band
    local inner  = R - RING_W
    local tickIn = math.max(2, math.floor(TICK_LEN * 2 / 3))   -- inner part a third shorter
    for i = 0, 7 do
      local ang  = i * 45 + rotDeg
      local x1, y1 = rot(cx, cy, inner - tickIn, ang, 0)
      local rOut = inner
      if i % 2 == 1 then
        local diff = skipAng and math.abs(((ang - skipAng + 540) % 360) - 180) or 999
        rOut = (diff > minSep) and (R + 2 + TICK_LEN) or R
      end
      local x2, y2 = rot(cx, cy, rOut, ang, 0)
      lcd.drawLine(x1, y1, x2, y2, SOLID, CUSTOM_COLOR)
    end
  end
  return tr
end

-- Compass mode (widget option): 1 Nose up = OSD style, up is the flight
-- direction, the arrow is the steering hint to home, the ring turns with the
-- course. 2 North up = map style, the ring is fixed, the arrow is the course
-- and an "H" outside the ring marks the bearing to home; a cardinal letter
-- that would sit under the H is left out. Boxes too small for a ring keep the
-- map style with a home dot on the rim (see drawDirection).
local function drawCompassArrow(cx, cy, R, d, compact)
  local r = math.floor(R * 0.55)
  if NORTH_UP then
    local tr = drawCompass(cx, cy, R, 0, d.bearingToHome, compact)
    drawArrow(cx, cy, r, d.course or 0, COLORS.fg)
    if d.bearingToHome and compact then
      -- No room for the badge outside: a filled dot on the band marks home.
      local hx, hy = rot(cx, cy, R - math.floor(RING_W / 2), d.bearingToHome, 0)
      lcd.drawFilledCircle(hx, hy, RING_W + sx(1), COLORS.fg)
    elseif d.bearingToHome then
      -- H in a thin circle so the marker reads as a badge, not a fifth letter.
      if lcd.drawCircle then
        local hx, hy = rot(cx, cy, tr, d.bearingToHome, 0)
        lcd.setColor(CUSTOM_COLOR, COLORS.fg)
        lcd.drawCircle(hx, hy, math.floor(fontH(SMLSIZE) / 2) - sx(1), CUSTOM_COLOR)
      end
      drawRingText(cx, cy, tr, d.bearingToHome, "H", COLORS.fg)
    end
  else
    drawCompass(cx, cy, R, -(d.course or 0), nil, compact)
    drawArrow(cx, cy, r, d.rel, COLORS.fg)
  end
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
-- Units come from the config (read once with core), so the rows are fixed at
-- load. ALT and SPD are shown as the radio's sensors deliver them (the sensor
-- unit is set on the radio), so the setting only labels them; the distance is
-- computed from the coordinates in metres and is scaled to the display unit.
local IMPERIAL  = core and core.PARAMS.UNITS == "imperial"
local DIST_F    = IMPERIAL and 3.28084 or 1
local LIST_ROWS = {
  { key = "alt",  label = "ALT",  unit = IMPERIAL and "ft"  or "m",    ref = "9999"  },
  { key = "dist", label = "DIST", unit = IMPERIAL and "ft"  or "m",    ref = "9999"  },
  { key = "spd",  label = "SPD",  unit = IMPERIAL and "mph" or "km/h", ref = "999.9" },
}
local LABEL_GAP = sx(6)
-- Header band height plus the gap to the sats block (sx(1), anchored so the
-- distance stays constant on every zone). Measured per call: lcd.sizeText is
-- not valid before the first frame.
local function headerH() return fontH(SMLSIZE) + sx(1) end

-- Signal-style bars: five bars of rising height, filled from the sat count
-- (thresholds below), track colour when empty.
local SATS_BAR_MIN = { 4, 6, 10, 15, 20 }   -- sats needed for bar 1..5
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
  return d.gspd and string.format("%.1f", d.gspd) or "--"
end

-- Sats colour by bar stage: <= 1 bar or debounced fix loss red, 2 bars yellow,
-- 3+ bars green (palette accent). Count and bars share it.
local function satsColor(sats, fixLost)
  local n = satsBars(sats or 0)
  if fixLost or n <= 1 then return CRIT_COL end
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
  drawSatsBars(x0 + colW - BARS_W, base - smlH, smlH - sx(2), d.sats, col)
  return satsBlockH(bf)
end

-- Rows sit in equal bands stacked up from the bottom edge (`bottom` = tile
-- bottom, pad from the zone edge), each row's text centred in its band; spare
-- height opens up between the sats block and the list.
local function drawList(x0, bottom, colW, rows, rowH, d)
  local y = bottom - #rows * rowH + math.floor((rowH - fontH(LIST_FONT)) / 2)
  for _, r in ipairs(rows) do
    local v = listValue(r, d)
    dtext(x0, y, r.label, COLORS.muted, LIST_FONT)
    drawValueUnit(x0 + colW - valueUnitW(v, r.unit, LIST_FONT), y, v, r.unit, COLORS.fg, LIST_FONT)
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
    drawCompass(cx, rcy, R, NORTH_UP and 0 or -(d.course or 0), nil, compact)
    if house then drawHouse(cx, rcy, math.floor(R * 0.55), COLORS.fg) end
  else
    if textW(txt, SMLSIZE) > W then txt = short end
    local hr = math.floor(math.min(W, areaH) / 2 * 0.55)
    if house and hr >= sx(8) then drawHouse(cx, top + math.floor(areaH / 2), hr, COLORS.fg) end
  end
  dtext(x0 + math.floor((W - textW(txt, SMLSIZE)) / 2), top + boxH - smlH, txt, col, SMLSIZE)
end

local function drawDirection(x0, top, W, boxH, d, rCap, small)
  local cx = x0 + math.floor(W / 2)
  local cy = top + math.floor(boxH / 2)
  if d.status == "READY" then
    if d.noHome then
      drawRingStatus(x0, top, W, boxH, d, rCap, small, "NO HOME", "NO HOME", CRIT_COL)
    else
      drawRingStatus(x0, top, W, boxH, d, rCap, small, "READY TO FLY", "READY", COLORS.muted)
    end
    return
  end
  if d.atHome then
    drawRingStatus(x0, top, W, boxH, d, rCap, small, "AT HOME", "AT HOME", COLORS.muted, true)
    return
  end
  if d.courseValid and d.rel then
    local lbl  = relLabel(d.rel)
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
        local cap = "HOME"
        local cw, vw = textW(cap, SMLSIZE), textW(lbl, SMLSIZE)
        local lx  = x0 + math.floor((W - (cw + LABEL_GAP + vw)) / 2)
        local ly  = top + areaH + sx(2)
        dtext(lx, ly, cap, COLORS.muted, SMLSIZE)
        dtext(lx + cw + LABEL_GAP, ly, lbl, COLORS.fg, SMLSIZE)
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
      local avail, refW = W - 2 * r - GAP, textW("180 R", SMLSIZE)
      local lw = 0
      if lbl ~= "" and refW <= avail then
        if 2 * smlH + sx(1) <= 2 * r then
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
      dtext(x0 + math.floor((W - textW(lbl, SMLSIZE)) / 2), top + boxH - smlH, lbl, COLORS.fg, SMLSIZE)
    elseif lbl ~= "" and textW("180 R", SMLSIZE) <= side then
      -- Beside the arrow: muted "HOME" caption over the value when two lines
      -- fit the arrow height, else on one line, else the value alone.
      local lx, cw = cx + r + GAP, textW("HOME", SMLSIZE) + LABEL_GAP
      if 2 * smlH + sx(1) <= 2 * r then
        dtext(lx, cy - smlH - math.floor(sx(1) / 2), "HOME", COLORS.muted, SMLSIZE)
        dtext(lx, cy + math.ceil(sx(1) / 2), lbl, COLORS.fg, SMLSIZE)
      elseif cw + textW("180 R", SMLSIZE) <= side then
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
    elseif NORTH_UP and d.bearingToHome then
      -- Map style without a ring: course arrow, home as a dot on the rim.
      local dr = RING_W + sx(1)
      local hx, hy = rot(cx, cy, r - dr, d.bearingToHome, 0)
      lcd.drawFilledCircle(hx, hy, dr, COLORS.fg)
      drawArrow(cx, cy, r - 2 * dr - sx(1), d.course or 0, COLORS.fg)
    else
      drawArrow(cx, cy, r, d.rel, COLORS.fg)
    end
  else
    -- Course invalid: absolute home direction instead of the arrow (FR-10).
    -- Fonts sized from fixed references so nothing jumps with the value.
    local sec = d.sector or "?"
    local deg = math.floor((d.bearingToHome or 0) + 0.5)
    if small then
      local txt = string.format("%s %d", sec, deg)
      local f   = fitFont("SW 220", math.floor(W * 0.95), boxH, DBLSIZE)
      dtext(x0 + math.floor((W - textW(txt, f)) / 2),
            top + math.floor((boxH - fontH(f)) / 2), txt, COLORS.fg, f)
    else
      -- Sector big, "220 deg" in SMLSIZE below, both centred in the box.
      local sub  = string.format("%d deg", deg)
      local smlH = fontH(SMLSIZE)
      local f    = fitFont("SW", math.floor(W * 0.95), boxH - smlH - sx(2), DBLSIZE)
      local ty   = top + math.floor((boxH - (fontH(f) + sx(2) + smlH)) / 2)
      dtext(x0 + math.floor((W - textW(sec, f)) / 2), ty, sec, COLORS.fg, f)
      dtext(x0 + math.floor((W - textW(sub, SMLSIZE)) / 2), ty + fontH(f) + sx(2), sub, COLORS.fg, SMLSIZE)
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
  for i, r in ipairs(LIST_ROWS) do
    local y, v = rowY(i + 1), listValue(r, d)
    dtext(x0, y, r.label, COLORS.muted, LIST_FONT)
    drawValueUnit(x0 + colW - valueUnitW(v, r.unit, LIST_FONT), y, v, r.unit, COLORS.fg, LIST_FONT)
  end
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
    local altW  = (altH > 0) and (textW(altR.label, SMLSIZE) + LABEL_GAP + valueUnitW(altR.ref, altR.unit, LIST_FONT)) or 0
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

-- Angle smoothing (display only): each frame moves the drawn angle towards the
-- target by half the remaining way, capped at SMOOTH_MAX_STEP degrees, along the
-- shorter direction, so GPS jitter softens and a real turn follows within a few
-- frames. nil target (no course) forgets the value, the next one snaps.
-- The result is always -180..180 (rel's range, which relLabel relies on).
local SMOOTH_MAX_STEP = 40
local function smoothAngle(prev, target)
  if target == nil then return nil end
  if prev == nil then return target end
  local diff = ((target - prev + 540) % 360) - 180
  if math.abs(diff) < 0.5 then return target end
  local step = diff * 0.5
  if step >  SMOOTH_MAX_STEP then step =  SMOOTH_MAX_STEP end
  if step < -SMOOTH_MAX_STEP then step = -SMOOTH_MAX_STEP end
  return ((prev + step + 180) % 360) - 180
end

-- ---------------------------------------------------------------------------
-- Tile dispatch: map core's status to a screen (display derivation, Spec 3.1).
-- Stable errors win over volatile states (Spec 4.1 priority).
-- ---------------------------------------------------------------------------
local function drawTile(ctx, z, x0, y0, W, H)
  if not core then
    drawStatusTile(z, "Core missing", "Reinstall GPS Homer", true); return
  end
  if ctx.fatalError then
    drawStatusTile(z, "Widget error", "Re-add or restart", true); return
  end

  local r = ctx.result
  if not r then
    drawSplashTile(z, "Waiting for telemetry"); return
  end
  -- Sensor existence comes from getFieldInfo and never flickers on a missed
  -- frame, so it wins over the volatile link state (no waiting tile flashing
  -- over a real setup error).
  if r.snapshot and r.snapshot.sensorMissing then
    drawStatusTile(z, "No GPS sensor", "Check FC config", true); return
  end

  local st = r.status
  if st == "ACTIVE" or st == "READY" then
    -- READY = the same live view before home is set: no arrow/H, DIST "--",
    -- a status line instead of "HOME <rel>".
    ctx.smooth = ctx.smooth or {}
    ctx.smooth.rel    = smoothAngle(ctx.smooth.rel,    r.rel)
    ctx.smooth.course = smoothAngle(ctx.smooth.course, r.course)
    local d = {
      status = st, rel = ctx.smooth.rel, bearingToHome = r.bearingToHome, sector = r.sector,
      courseValid = r.courseValid, course = ctx.smooth.course, distanceM = r.distanceM, sats = r.sats,
      alt = r.alt, gspd = r.gspd, fixLost = r.fixLost, noHome = r.noHome, atHome = r.atHome,
    }
    drawActive(W, H, x0, y0, d)
    drawHeartbeat(ctx, z)
  elseif st == "ACQUIRING" then
    -- "4 Sats (min 6)": found so far, and the count home needs.
    drawSplashTile(z, "Searching satellites",
                   string.format("%d Sats (min %d)", r.sats or 0, core.PARAMS.HOME_MIN_SATS))
    drawHeartbeat(ctx, z)
  elseif st == "ENDED" then
    if r.lastLat and r.lastLon then
      drawStatusTile(z, "Flight ended", dms(r.lastLat, "N", "S"), false, dms(r.lastLon, "E", "W"))
    else
      drawStatusTile(z, "Flight ended", "--", false)
    end
  else -- NO_TELEM
    drawSplashTile(z, "Waiting for telemetry")
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
  if core then ctx.state = core.newState() end
  return ctx
end

local function update(ctx, opts)
  ctx.options = opts
end

-- One throttled, fault-tolerant data cycle (no lcd.*). background() only runs
-- off-screen, so refresh() must drive it too or the tile freezes. A repeated
-- failure streak trips the terminal error tile.
local function tick(ctx)
  if not core or ctx.fatalError then return end
  local now = getTime()
  if ctx.lastTick ~= 0 and (now - ctx.lastTick) < TICK_INTERVAL then return end
  ctx.lastTick = now
  local ok, res = pcall(core.update, ctx.state)
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

  -- Background per theme (Designguide 3): Dark paints its own panel; Light stays
  -- transparent with an optional milky overlay.
  if not COLORS.transparent then
    lcd.drawFilledRectangle(0, 0, z.w, z.h, COLORS.panel)
  else
    local trans = ctx.options.Transparency or 0
    if trans > 0 then
      lcd.drawFilledRectangle(0, 0, z.w, z.h, COLOR_THEME_PRIMARY2, 3 * trans)
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
    { "Transparency", VALUE,  2, 0, 5 },
    { "Accent",       CHOICE, 1, { "Default", "Theme", "Custom" } },
    { "AccentColor",  COLOR,  lcd.RGB(124, 210, 48) },
  },
  create     = create,
  update     = update,
  refresh    = refresh,
  background = background,
}
