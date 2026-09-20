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

-- Distance is always whole metres, also above 1 km (unit drawn separately).
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
local function drawHeader(x, y)
  local h  = fontH(SMLSIZE)
  local sq = sx(5)
  lcd.drawFilledRectangle(x, y + math.floor((h - sq) / 2), sq, sq, BRAND)
  dtext(x + sq + sx(3), y, "GPS-HOMER", BRAND, SMLSIZE)
  return sq + sx(3) + textW("GPS-HOMER", SMLSIZE)
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
local NORTH_UP = false
local function drawCompass(cx, cy, R, rotDeg, skipAng)
  drawRing(cx, cy, R)
  local tr = R + math.floor(fontH(SMLSIZE) / 2)   -- letters outside the ring
  if not NORTH_UP then skipAng = 0; drawNoseMark(cx, cy, tr) end
  local minSep = math.deg((textW("W", SMLSIZE) / 2 + fontH(SMLSIZE) / 2) / tr)
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
-- that would sit under the H is left out.
local function drawCompassArrow(cx, cy, R, d)
  local r = math.floor(R * 0.55)
  if NORTH_UP then
    local tr = drawCompass(cx, cy, R, 0, d.bearingToHome)
    drawArrow(cx, cy, r, d.course or 0, COLORS.fg)
    if d.bearingToHome then
      -- H in a thin circle so the marker reads as a badge, not a fifth letter.
      if lcd.drawCircle then
        local hx, hy = rot(cx, cy, tr, d.bearingToHome, 0)
        lcd.setColor(CUSTOM_COLOR, COLORS.fg)
        lcd.drawCircle(hx, hy, math.floor(fontH(SMLSIZE) / 2) - sx(1), CUSTOM_COLOR)
      end
      drawRingText(cx, cy, tr, d.bearingToHome, "H", COLORS.fg)
    end
  else
    drawCompass(cx, cy, R, -(d.course or 0))
    drawArrow(cx, cy, r, d.rel, COLORS.fg)
  end
end

-- ---------------------------------------------------------------------------
-- ACTIVE renderer (the only bespoke renderer)
-- ---------------------------------------------------------------------------

-- Layout is picked by measured fit against the real font metrics. TIER_TOL
-- keeps a one-pixel difference at a boundary from flipping the layout.
local TIER_TOL = sx(4)
local GAP      = sx(4)

-- Sats block (top of the list, the primary value): the count in MIDSIZE
-- (default font when the height is short), "SATS" caption and the signal bars
-- beside it on its baseline. Below it the value list in SMLSIZE: one row per
-- metric, label left (muted), value+unit right-aligned so the numbers line up.
-- Rows in display order; `drop` is the order they give way when the zone is
-- too low (SPD first).
local LIST_ROWS = {
  { key = "alt",  label = "ALT",  unit = "m",    ref = "9999",  drop = 2 },
  { key = "dist", label = "DIST", unit = "m",    ref = "9999",  drop = 3 },
  { key = "spd",  label = "SPD",  unit = "km/h", ref = "999.9", drop = 1 },
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
-- Tight pitch (fit check and fallback).
local function listRowH() return fontH(LIST_FONT) - sx(2) end
-- Row pitch actually drawn: 20 % of the height under the header (rows spread
-- over the tile like the sibling widgets' info rows), unless that would cost a
-- row that the tight pitch keeps.
local function listPitch(bf, H)
  local wide = math.max(listRowH(), math.floor(H * 0.20))
  if math.floor((H - satsBlockH(bf)) / wide) < math.min(#LIST_ROWS, math.floor((H - satsBlockH(bf)) / listRowH())) then
    return listRowH()
  end
  return wide
end

-- Sats font: MIDSIZE; default font when the block plus one row would not fit
-- the height or the column would take more than half the width.
local function satsFont(W, H)
  if listColW(MIDSIZE) > W * 0.5 or satsBlockH(MIDSIZE) + listRowH() > H then return 0 end
  return MIDSIZE
end

-- Rows that fit under the sats block, dropped by priority, in display order.
local function listRowsFor(bf, H)
  local n = math.min(#LIST_ROWS, math.floor((H - satsBlockH(bf)) / listRowH()))
  local rows = {}
  for _, r in ipairs(LIST_ROWS) do
    if r.drop > #LIST_ROWS - n then rows[#rows + 1] = r end
  end
  return rows
end

local function listValue(r, d)
  if r.key == "dist" then return fmtDist(d.distanceM) end
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

-- Sats block: count, caption right behind it (moves with the digit count),
-- bars right-aligned with the value column.
local function drawSatsBlock(x0, y, colW, bf, d)
  local col  = satsColor(d.sats, d.fixLost)
  local base = y + fontH(bf)
  local smlH = fontH(SMLSIZE)
  local txt  = d.sats and tostring(d.sats) or "--"
  dtext(x0, y, txt, col, bf)
  dtext(x0 + textW(txt, bf) + sx(3), base - smlH, "SATS", COLORS.muted, SMLSIZE)
  drawSatsBars(x0 + colW - BARS_W, base - smlH, smlH - sx(2), d.sats, col)
  return satsBlockH(bf)
end

-- Rows are anchored to the bottom edge (`bottom` = tile bottom, pad from the
-- zone edge) so the last value always sits flush with the edge inset; spare
-- height opens up between the sats block and the list.
local function drawList(x0, bottom, colW, rows, rowH, d)
  local y    = bottom - fontH(LIST_FONT) - (#rows - 1) * rowH
  for _, r in ipairs(rows) do
    local v = listValue(r, d)
    dtext(x0, y, r.label, COLORS.muted, LIST_FONT)
    drawValueUnit(x0 + colW - valueUnitW(v, r.unit, LIST_FONT), y, v, r.unit, COLORS.fg, LIST_FONT)
    y = y + rowH
  end
end

-- The list layout fits when the arrow box beside the list keeps a usable
-- diameter (sx(40)) and the sats block plus one row fit under the header.
-- Returns the verdict plus the values drawActive needs, so both use the same numbers.
local function activeFitsList(W, H)
  local Hl   = H - headerH()
  local bf   = satsFont(W, Hl)
  local boxW = W - listColW(bf) - GAP
  local ok   = boxW >= sx(40) - TIER_TOL and Hl >= satsBlockH(bf) + listRowH() - TIER_TOL
  return ok, bf, Hl
end

-- Direction box: the arrow (or the absolute home direction when the course is
-- invalid) centred in x0..x0+W / top..top+boxH. Arrow radius = what fits the box,
-- capped at rCap. The degree label sits right of the arrow, vertically centred,
-- with the largest font that fits; if even SMLSIZE does not fit beside it, the
-- arrow shrinks and the label goes below (never in SMALL, which has no label).
-- Ring without arrow or H plus a status line where "HOME <rel>" normally sits:
-- READY ("READY TO FLY" / "NO HOME") and standing on the home point ("AT HOME").
-- SMALL has no room for the ring: the short word alone, as large as fits.
local function drawRingStatus(x0, top, W, boxH, d, rCap, small, txt, short, col, house)
  local cx    = x0 + math.floor(W / 2)
  local smlH  = fontH(SMLSIZE)
  local areaH = boxH - smlH - sx(2)
  local R     = math.min(math.floor(math.min(W, areaH) / 2) - ringMargin(), rCap)
  if not small and R >= sx(12) then
    local rcy = top + math.floor(areaH / 2)
    drawCompass(cx, rcy, R, NORTH_UP and 0 or -(d.course or 0))
    if house then drawHouse(cx, rcy, math.floor(R * 0.55), COLORS.fg) end
    dtext(x0 + math.floor((W - textW(txt, SMLSIZE)) / 2), top + areaH + sx(2), txt, col, SMLSIZE)
  else
    local f = fitFont("NO HOME", math.floor(W * 0.95), boxH, DBLSIZE)
    dtext(x0 + math.floor((W - textW(short, f)) / 2), top + math.floor((boxH - fontH(f)) / 2), short, col, f)
  end
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
    -- bottom. Letters need ringMargin() around the ring.
    local lm    = ringMargin()
    local areaH = (lbl ~= "") and (boxH - smlH - sx(2)) or boxH
    local R     = math.min(math.floor(math.min(W, areaH) / 2) - lm, rCap)
    if not small and R >= sx(12) then
      local rcy = top + math.floor(areaH / 2)
      drawCompassArrow(cx, rcy, R, d)
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
    -- No room for the ring: arrow only, label below (or beside in SMALL).
    local r = math.min(math.floor(math.min(boxH, W) / 2), rCap)
    if r < sx(8) then r = sx(8) end
    local side = x0 + W - (cx + r) - GAP
    if lbl ~= "" and not small and boxH - smlH - sx(2) >= 2 * sx(8) then
      -- Label below the arrow (list layout); the arrow gives up the label height.
      r  = math.min(r, math.floor((boxH - smlH - sx(2)) / 2))
      cy = top + math.floor((boxH - smlH - sx(2)) / 2)
      dtext(x0 + math.floor((W - textW(lbl, SMLSIZE)) / 2), cy + r + sx(2), lbl, COLORS.fg, SMLSIZE)
    elseif lbl ~= "" and textW("180 R", SMLSIZE) <= side then
      local f = fitFont("180 R", side, 2 * r)
      dtext(cx + r + GAP, cy - math.floor(fontH(f) / 2), lbl, COLORS.fg, f)
    end
    drawArrow(cx, cy, r, d.rel, COLORS.fg)
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

-- The whole ACTIVE tile: header, value list left, arrow right. When the list
-- cannot sit beside a usable arrow, only the arrow remains (SMALL). Fit check
-- and draw share activeFitsList so the constants can never drift.
local function drawActive(W, H, x0, y0, d)
  local ok, bf, Hl = activeFitsList(W, H)
  if ok then
    drawHeader(x0, y0)
    local top  = y0 + headerH()
    local colW = listColW(bf)
    drawSatsBlock(x0, top, colW, bf, d)
    drawList(x0, y0 + H, colW, listRowsFor(bf, Hl), listPitch(bf, Hl), d)
    local bx = x0 + colW + GAP
    drawDirection(bx, top, x0 + W - bx, Hl, d, sx(60), false)
  else
    drawDirection(x0, y0, W, H, d, math.floor(math.min(W, H) / 2), true)
  end
end

-- Angle smoothing (display only): each frame moves the drawn angle towards the
-- target by half the remaining way, capped at SMOOTH_MAX_STEP degrees, along the
-- shorter direction, so GPS jitter softens and a real turn follows within a few
-- frames. nil target (no course) forgets the value, the next one snaps.
local SMOOTH_MAX_STEP = 40
local function smoothAngle(prev, target)
  if target == nil then return nil end
  if prev == nil then return target end
  local diff = ((target - prev + 540) % 360) - 180
  if math.abs(diff) < 0.5 then return target end
  local step = diff * 0.5
  if step >  SMOOTH_MAX_STEP then step =  SMOOTH_MAX_STEP end
  if step < -SMOOTH_MAX_STEP then step = -SMOOTH_MAX_STEP end
  return (prev + step) % 360
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
    drawSplashTile(z, "Acquiring GPS", tostring(r.sats or 0) .. " Sats")
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
