# edgetx-gps-homer

![edgetx-gps-homer: EdgeTX Lua widget showing direction and distance to home](docs/banner.png)

A small EdgeTX project that shows you **where home is and how far away it is**, using nothing but the GPS telemetry your flight controller already sends. The direction is shown **relative to the nose of your model** (like the home arrow in the Betaflight OSD), so you can steer back without any mental arithmetic, and it works on models **without a magnetometer**.

[![License: GPL v2](https://img.shields.io/badge/License-GPL_v2-blue.svg)](LICENSE)
[![EdgeTX](https://img.shields.io/badge/EdgeTX-%E2%89%A5%202.11-brightgreen)](https://edgetx.org)
[![ExpressLRS](https://img.shields.io/badge/ExpressLRS-%E2%89%A5%203.0-orange)](https://www.expresslrs.org)
[![GitHub issues](https://img.shields.io/github/issues/Mariator-pro/edgetx-gps-homer)](../../issues)
[![GitHub last commit](https://img.shields.io/github/last-commit/Mariator-pro/edgetx-gps-homer)](../../commits/main)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20me%20a%20coffee-support-yellow?logo=buy-me-a-coffee&logoColor=white)](https://www.buymeacoffee.com/mariatorpro)

---

## 📑 Table of Contents

- [📋 Compatibility](#-compatibility)
- [🎯 What is it for?](#-what-is-it-for)
- [🧰 Requirements](#-requirements)
- [🧩 Script variants](#-script-variants)
- [📥 Installation](#-installation)
- [⚙️ Customizing](#️-customizing)
- [🛠️ Troubleshooting](#️-troubleshooting)
- [💡 Credits](#-credits)
- [🤝 Contributing](#-contributing)
- [⚠️ Disclaimer](#️-disclaimer)
- [📄 License](#-license)

---

## 📋 Compatibility

| Component | Minimum Version | Tested On | Test Hardware |
|-----------|-----------------|-----------|---------------|
| EdgeTX    | v2.11           | v2.12.0   | Radiomaster TX15, Radiomaster TX16S MK3 |
| ExpressLRS| v3.0            | v4.0.0    | Radiomaster RP1 V2, RP3 V2, RP4TD |

---

## 🎯 What is it for?

Once your model is far away or hard to see, it is easy to lose track of where "back home" is. The OSD in your goggles has a home arrow, but on the radio there is usually nothing.

<p align="center">
  <img src="docs/img/widget-active.png" width="300" alt="edgetx-gps-homer widget showing the home arrow, compass ring and values">
</p>

The widget reads the GPS values the flight controller sends over CRSF (position, satellites, ground speed, course, altitude) and shows:

- **A home arrow** that rotates continuously and points to the launch position, **relative to your flight direction**: arrow up means keep going straight, arrow down means turn around, left or right means turn that way. A compass ring around it shows where north currently lies.
- **The steering hint** in words (`ahead`, `behind`, `30 R`, ...) and the **distance** to home in metres.
- **Satellite count** with a signal-style bar graph and colour (red, yellow, green), plus altitude and ground speed.

Home is set automatically at the launch position as soon as the GPS fix has been stable for a few seconds. The widget speaks only on events (home set, GPS fix lost, GPS fix recovered); there are no continuous direction announcements.

When the model is standing still or hovering slowly, the GPS course is not usable as a heading, so the widget falls back to the **absolute** direction to home (compass sector and degrees). After the telemetry link is gone for good (landed out of range, crash), the widget freezes and shows the **last known GPS position** of the model to help you find it.

---

## 🧰 Requirements

- A radio running EdgeTX 2.11 or newer with a color display
- A Betaflight flight controller with a **GPS module**, and GPS telemetry enabled over CRSF
- An ExpressLRS receiver with telemetry enabled
- The following telemetry sensors must be discovered on the radio (they appear automatically after a telemetry discovery while the GPS has a fix):
  - **Mandatory:** `GPS`, `Sats`, `GSpd`, `Hdg`
  - **Optional (display only):** `Alt` or `GAlt` (altitude), `RQly` (link detection; the radio's RSSI is used when it is missing)
- No magnetometer is needed: the flight direction comes from the GPS course over ground, which is why the arrow needs the model to move (at least 6 km/h)

---

## 🧩 Script variants

The logic lives in a shared core module (`core.lua`). On top of it sit two wrappers, and you install **exactly one** of them:

<table>
  <thead>
    <tr>
      <th width="24%"></th>
      <th width="38%">Widget</th>
      <th width="38%">Function script</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td>Voice events (home set, GPS lost, GPS recovered) + haptic</td>
      <td>✅</td>
      <td>✅</td>
    </tr>
    <tr>
      <td>Home arrow, distance, last known position</td>
      <td>✅</td>
      <td>❌ (no display)</td>
    </tr>
    <tr>
      <td>Runs in the background</td>
      <td>✅ (keeps announcing even when the screen is not shown)</td>
      <td>✅ (Special Function)</td>
    </tr>
    <tr>
      <td>Supported radios</td>
      <td>color-display radios only</td>
      <td>all EdgeTX radios, including black-and-white ones</td>
    </tr>
  </tbody>
</table>

> ⚠️ **Don't install both at the same time**, or every event would be announced twice. The widget fully replaces the function script. For the same reason, place the widget on **one screen only**.

Both variants need `core.lua` on the SD card and share the same settings (see [Customizing](#️-customizing)).

---

## 📥 Installation

### 1. Copy the files to the SD card

Take the SD card out of the radio (or connect the radio via USB as mass storage) and copy everything below 1:1. It does no harm to have both variants on the card; you pick one later by **either** activating the widget **or** adding the function script to a Special Function (just not both, see [Script variants](#-script-variants)):

```
SCRIPTS/
├── GPSHOMER/
│   └── core.lua            ← shared logic (mandatory)
├── FUNCTIONS/
│   └── gpshom.lua          ← function-script variant (voice only)
└── TOOLS/
    └── GPSHOMER.lua        ← on-radio settings tool (optional)
WIDGETS/
└── GPSHOMER/
    └── main.lua            ← widget variant
SOUNDS/
└── en/
    └── scripts/
        └── GPSHOMER/
            ├── gpsfix.wav
            ├── gpslost.wav
            └── gpsrec.wav
```

All files are available in the matching folders of this repository, so just copy them to the same locations on the SD card. The WAV files always live under `/SOUNDS/en/scripts/GPSHOMER/` regardless of the radio's language setting; the script uses an absolute path to play them.

### 2a. Set up the widget

1. Put the SD card back into the radio and switch it on.
2. Open the model's **Telemetry / Display** (widget screens) configuration.
3. Add a widget to a free zone and pick **GPS Homer** from the list.
4. *(Optional)* Open the widget settings to adjust:
   - **Theme**: `Dark` / `Light`.
   - **Compass**: `NoseUp` (default) keeps the flight direction on top, the arrow is the steering hint to home and the compass ring turns with your course. `NorthUp` keeps north on top like a map, the arrow shows your course and an `H` on the ring marks the direction to home.
   - **Transparency**: milky-overlay transparency level (light theme only).
   - **Accent**: color of the heading / brand text: `Default` (the classic green), `Theme` (the focus color of your active EdgeTX theme), or `Custom` (pick any color via **AccentColor**).

> ⚠️ Place the widget on **one screen only**. A second instance would track its own home and play the voice events twice.

> 📐 **Recommended screen layouts:** EdgeTX names its widget-screen layouts `columns × rows` (e.g. `2×4` = 2 columns next to each other, 4 rows on top of each other → 8 zones). The widget is designed for a **half-width** zone, so it looks best in the layouts with **2 columns**:
>
> - **2×2**: half width, half height. This is the primary use case and shows the full layout with every value.
> - **2×3** and **2×4**: shorter zones. The widget drops the speed and altitude rows first and keeps the satellites, the distance and the arrow.
> - Very small zones show the arrow only.

### 2b. *(Alternative)* Set up the function script (Special Function)

For radios without a color display, or if you only want the voice events:

1. Put the SD card back into the radio and switch it on.
2. Open the **Model Settings** of the desired model and go to the **Special Functions** (also called "SF") page.
3. Pick a free slot and configure it as follows:
   - **Switch / Condition:** `On` (the script runs permanently in the background)
   - **Action:** `Lua Script`
   - **Value / Script:** `gpshom`
   - **Repeat:** `On`
   - **Enable:** `On`
4. Save the settings.

### 3. Test it

- Bind the model, let the GPS get a fix and verify that `GPS`, `Sats`, `GSpd` and `Hdg` show values on the radio.
- On the ground the widget shows `Acquiring GPS` with the satellite count. Once enough satellites are locked (6 by default) for a few seconds, home is set and the radio says so.
- Walk or fly away from the launch position: the distance grows and, as soon as the model moves faster than 6 km/h, the arrow appears and points back to the launch position relative to your direction of travel.
- Switch the model off: after a few seconds the widget shows `Flight ended` with the last known coordinates, then returns to `Waiting for telemetry` after one minute.
- With the function script you get the voice events only: `Home set` once the fix is stable, `GPS lost` / `GPS recovered` while flying.

---

## ⚙️ Customizing

To adjust the home-set threshold and pick custom sounds, use the bundled **settings tool**. Copy `/SCRIPTS/TOOLS/GPSHOMER.lua` to the SD card (see the file tree above) and open it on the radio via **SYS → Tools → "GPS Homer"**.

- **Settings**:
  - **Min sats**: the number of locked satellites required before home is set. **Editable 4-20** (default 6). Higher = a more reliable launch position, but home is set later.
  - **Sound home set / GPS lost / GPS recover**: pick `Off`, `Default`, or any `.wav` you dropped into `/SOUNDS/en/scripts/GPSHOMER/`, per event. Files can have **any name**, and every `.wav` in that folder shows up in the list automatically. `Off` silences **only that event**.
  - **Test**: plays the row's currently selected sound (and the haptic pulse, if enabled) so you can compare them on the spot.
  - **Haptic feedback**: `Off` (default) or `On`. When on, the radio vibrates alongside each event, independent of the sound (a muted event still buzzes). Home set and GPS recover give one pulse, GPS lost two.
  - **Haptic strength**: `Soft`, `Normal` or `Strong` pulse length (shown only while haptic feedback is on).
  - **Reset to defaults** restores the factory settings.
- **About**: version and the paths the project uses.

Press **Save** to write the settings. They land in `/SCRIPTS/GPSHOMER/config.lua`, which `core.lua` reads once when the script starts, so **both variants** (widget and function script) use them after the next model select (or reboot). The config file is **optional**: without it the hard-coded defaults stay in force.

Timing constants (course threshold, fix-loss debounce, how long the last position is shown) are deliberately not in the tool; they can be changed at the top of `core.lua`.

---

## 🛠️ Troubleshooting

- **Widget shows "Core missing / Reinstall GPS Homer":** `core.lua` is not where it should be. Make sure `/SCRIPTS/GPSHOMER/core.lua` exists on the SD card.
- **Widget shows "No GPS sensor / Check FC config":** One of the mandatory sensors (`GPS`, `Sats`, `GSpd`, `Hdg`) has never been discovered. Enable GPS telemetry in Betaflight, then run a telemetry discovery on the radio while the GPS has a fix.
- **Widget stays on "Acquiring GPS":** Not enough satellites yet, or the fix is not stable. Give the GPS a clear view of the sky; the widget waits until the count stays at or above the threshold for a few seconds.
- **No arrow, only a compass sector like "SW 220 deg":** The model is not moving faster than 6 km/h, so the GPS course cannot be used as a heading. The arrow appears as soon as you fly.
- **Altitude shows "--":** Neither `Alt` nor `GAlt` is discovered. It is optional; everything else keeps working.
- **No voice at all:** Make sure the WAV files really sit in `/SOUNDS/en/scripts/GPSHOMER/` (the `en/` folder is mandatory even if your radio is set to another language). The quickest check is the settings tool: press **Test** on an event to play its sound directly.
- **Script doesn't show up when picking it for the Special Function:** Check the file name. It must be exactly `gpshom.lua` (max. 6 characters, otherwise EdgeTX hides function scripts).
- **A change in `main.lua` or `core.lua` has no effect on the radio:** Delete the compiled `.luac` file next to it; EdgeTX keeps running the old bytecode otherwise.

---

## 💡 Credits

The reading of the home arrow follows the OSD home direction arrow in [Betaflight](https://betaflight.com), which is what most FPV pilots already know from their goggles.

---

## 🤝 Contributing

Found a bug or have an idea for an improvement? Please [open an issue](../../issues) on GitHub. Pull requests are welcome too.

---

## ⚠️ Disclaimer

This project is provided **as is** and is intended as an additional aid only. It does **not** replace careful flying within visual range, your own judgement, GPS rescue on the flight controller, or the safety mechanisms of your transmitter and receiver. Always be ready to react manually. Use at your own risk.

---

## 📄 License

Released under the [GNU General Public License v2.0](LICENSE).
