# edgetx-gps-homer

![edgetx-gps-homer: EdgeTX Lua widget showing direction and distance to home](docs/banner.png)

GPS Homer puts a **home arrow on your radio**: a small EdgeTX widget that shows **which way home is and how far away it is**, using the GPS data your flight controller already sends. On top of that the radio tells you by voice when the GPS is ready, when home has been set, when the GPS signal is lost or back and, if you set a limit, when the model flies too high.

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
- [🤝 Contributing](#-contributing)
- [⚠️ Disclaimer](#️-disclaimer)
- [📄 License](#-license)

---

## 📋 Compatibility

> [!CAUTION]
> **Testing is not finished yet.** The project is in an early stage and has not been through all real-flight tests. Feedback on how the individual functions behave on your setup is very welcome, please [open an issue](../../issues).

| Component | Minimum Version | Tested On | Test Hardware |
|-----------|-----------------|-----------|---------------|
| EdgeTX    | v2.11           | v2.12.4   | Radiomaster TX15, Radiomaster TX16S MK3 |
| ExpressLRS| v3.0            | v4.1.0    | Radiomaster RP1 V2, RP3 V2, RP4TD |

> Flight controllers (Betaflight, INAV, ArduPilot), other RC links (TBS Crossfire, ImmersionRC Ghost, FrSky ACCESS) and the settings they need: see [`docs/compatibility.md`](docs/compatibility.md).
>
> 🙋 **Help wanted:** most of these combinations are checked in the source code only, not yet on real hardware. If you fly one of them, a test would help a lot. Any feedback, working or not, is welcome: please [open an issue](../../issues).

---

## 🎯 What is it for?

Which way is home? A model with GPS knows the answer at any moment, but the radio never shows it. GPS Homer brings the home arrow you know from the OSD in your goggles to the EdgeTX radio: one glance tells you where to turn and how far you have to go.

<p align="center">
  <img src="docs/img/widget-flight.png" width="300" alt="edgetx-gps-homer widget showing the home arrow, compass ring and values">
</p>

The widget shows:

- **A home arrow** relative to your flight direction: up means straight on, down means turn around, left or right means turn that way. A compass ring around it shows north.
- **The same hint in words** (`ahead`, `behind`, `30 R`, ...) and the **distance to home**.
- **The number of satellites** with a signal bar, plus altitude above home and ground speed.
- **GPS accuracy on the ground** (`PDOP 1.3`, with INAV and ArduPilot `HDOP`) on the preflight page.

Everything happens automatically:

- **Home is set on its own, like on the flight controller.** Once the GPS fix is stable the radio says "Ready to fly"; when you arm, home is stored and the radio says "Home set".
- **Voice only when it matters:** ready to fly, home set, GPS lost, GPS back and an optional maximum altitude warning. Each event can be muted or replaced with your own sound.
- **Standing still or hovering slowly?** The compass ring turns north up and an `H` on it marks the direction to home (`SW 220°`), since there is no flight direction yet.
- **Hovering after a fast straight line:** the arrow stays and turns with the nose (`HOME ~30 R`), for up to 60 s.
- **Lost the link?** The widget keeps showing the **last known GPS position** of the model to help you find it.

Besides the flight view above, the widget shows a page for each other phase of a flight:

<table>
  <tr>
    <td align="center"><img src="docs/img/widget-waiting.png" width="260" alt="Waiting page: no telemetry yet"></td>
    <td align="center"><img src="docs/img/widget-preflight.png" width="260" alt="Preflight page with satellites, GPS accuracy and fix status"></td>
    <td align="center"><img src="docs/img/widget-end.png" width="260" alt="End page with the flight's maximum distance, altitude, speed and last position"></td>
  </tr>
  <tr>
    <td align="center"><b>Waiting</b><br>no telemetry yet</td>
    <td align="center"><b>Preflight</b><br>GPS check before take-off</td>
    <td align="center"><b>End</b><br>the flight's maxima and last position</td>
  </tr>
</table>

---

## 🧰 Requirements

- A radio running **EdgeTX 2.11 or newer**. For the widget the radio needs a color display; for voice announcements only, any EdgeTX radio will do (see [Script variants](#-script-variants)).
- A **Betaflight, INAV or ArduPilot flight controller with a GPS module**, with GPS telemetry enabled. INAV and ArduPilot support is derived from their source code and not flight-tested yet; ArduPilot needs one extra setting, see [`docs/compatibility.md`](docs/compatibility.md#setup).
- An **ExpressLRS receiver (3.0 or newer)** with telemetry enabled. For other RC links see [`docs/compatibility.md`](docs/compatibility.md).
- The GPS data must be known to the radio as telemetry sensors. They appear on their own when you run a **telemetry discovery** (Model Settings → Telemetry → "Discover new sensors") while the GPS has a fix:
  - **Required:** `GPS` (position), `Sats` (satellite count), `GSpd` (ground speed), `Hdg` (course over ground). A lost link is detected by the radio itself, no sensor needed.
  - **Optional:**
    - `FM` (flight mode): sets home at arming; without it, home is set at the first stable fix
    - `GAlt` or `Alt` (GAlt preferred): altitude above home, for the display, the flight's maximum on the end page and the Max altitude warning

---

## 🧩 Script variants

GPS Homer comes in two variants. Both use the same logic and the same settings; you install **one** of them:

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
      <td>Voice announcements and vibration</td>
      <td>✅</td>
      <td>✅</td>
    </tr>
    <tr>
      <td>Home arrow, distance, satellites, last known position</td>
      <td>✅</td>
      <td>❌ (no display)</td>
    </tr>
    <tr>
      <td>Runs in the background</td>
      <td>✅</td>
      <td>✅</td>
    </tr>
    <tr>
      <td>Supported radios</td>
      <td>color-display radios only</td>
      <td>all EdgeTX radios, including black-and-white ones</td>
    </tr>
  </tbody>
</table>

> ⚠️ **Never run both at the same time**, otherwise every event is announced twice. The widget already includes everything the function script does. For the same reason, place the widget on **one screen only**.

---

## 📥 Installation

### 1. Copy the files to the SD card

Copy the folders below 1:1 into the root of the SD card. Copying everything is fine even if you only use one variant; you choose the variant in step 2.

```
SCRIPTS/
├── GPSHOMER/
│   ├── core.lua            ← shared logic
│   ├── compass.lua         ← compass drawing
│   ├── manifest.lua        ← Flight Bag settings
│   └── qr.lua              ← QR code in Flight Bag
├── FUNCTIONS/
│   └── gpshom.lua          ← function script
├── FLIGHTBAG/              ← Flight Bag pages
└── TOOLS/
    └── FLIGHTBAG.lua       ← Tools menu entry
WIDGETS/
└── GPSHOMER/
    └── main.lua            ← widget
SOUNDS/
└── en/
    └── SCRIPTS/
        └── GPSHOMER/       ← all .wav files
```

All files sit in the same folders in this repository. The sound files always live under `/SOUNDS/en/SCRIPTS/GPSHOMER/`, no matter which language your radio is set to.

Two more files show up in `/SCRIPTS/GPSHOMER/` later, written by the radio itself and nothing you copy: `config.lua` holds your settings once you save them in the tool, and `flights.lua` holds the last known position of the last three flights.

### 2a. Set up the widget

1. Open the model's **Telemetry / Display** setup (the page where you arrange the widget screens).
2. Pick a free zone, add a widget and choose **GPS Homer** from the list.
3. *(Optional)* Open the widget settings to adjust the look:
   - **Theme**: `Dark` or `Light`.
   - **Compass**: `NoseUp` (default): flight direction on top, the arrow points home. `NorthUp`: north on top like a map, an `H` on the ring marks home.
   - **Transparency**: how much of the radio theme shows through the milky background (light theme only): `0%` opaque, `100%` no overlay.
   - **Accent**: color of the heading text: `Default` (green), `Theme` (the focus color of your EdgeTX theme) or `Custom` (pick any color under **AccentColor**).

> 📐 **Which screen layout?** EdgeTX names its layouts `columns × rows`, so `2×4` means 2 zones side by side and 4 on top of each other. The widget is designed for a **half-width** zone and looks best in the layouts with **2 columns**:
>
> - **2×2**: half width, half height. This is the intended size and shows every value.
> - **2×3** and **2×4**: shorter zones. Speed and altitude are dropped first; satellites, distance and the arrow stay.
> - Very small zones show the arrow only.

### 2b. *(Alternative)* Set up the function script

For radios without a color display, or if you only want the voice announcements:

1. Open the **Model Settings** and go to the **Special Functions** page (also called "SF").
2. Pick a free slot and set it up like this:
   - **Switch / Condition:** `On` (the script runs permanently in the background)
   - **Action:** `Lua Script`
   - **Value / Script:** `gpshom`
   - **Repeat:** `On`
   - **Enable:** `On`
3. Leave the page; the settings are saved automatically.

### 3. Try it out

- Power the model and wait for the GPS fix. The radio's telemetry page should show values for `GPS`, `Sats`, `GSpd` and `Hdg`.
- The widget shows the preflight page: satellites, GPS accuracy (PDOP or HDOP) and fix with `NO FIX` / `FIX SETTLING`. Once the fix is stable, the radio says "Ready to fly" and the page shows `GPS READY`; a bar at the bottom right counts down 15 s to the live view (arming switches at once).
- Arm the model: the radio says "Home set". Fly away: the distance grows and the arrow points back home.
- Switch the model off: the widget shows the end page with the flight's highest distance, altitude and speed and its last position for 30 s. The coordinates stay in the flight log, see **Last flights** in Flight Bag.
- With the function script you only hear the announcements.

---

## ⚙️ Customizing

Settings are made in **Flight Bag**, a settings tool shared by several EdgeTX scripts. Copy its files (see the file tree above) and open **SYS → Tools → Flight Bag**. After **Save**, changes apply within a few seconds for both variants, no restart needed.

GPS Homer's rows sit under the heading **GPS Homer**:

- **Warnings**
  - **Home min sats**: how many satellites must be locked before home is set. **4-20** (default 6). Higher gives a more accurate home but sets it a little later.
  - **Max altitude**: `Off` (default) or **10-500** in steps of 10, in the unit of your altitude sensor. Above this height over home the radio says "Warning, maximum altitude" once, and again only after the model has dropped 10 below the limit. With the default ELRS telemetry ratio the altitude arrives only every few seconds, so the warning can come a little late.
- **Alerts**
  - **Sounds**, **Vibration**, **Strength**: shared by all Flight Bag scripts. `Sounds Off` silences every GPS Homer announcement. Vibration (off by default) gives two pulses for GPS lost and Max altitude and one for every other event, independent of the sound. These two warnings also switch a dimmed display back on.
  - **Ready to fly**, **Home set**, **GPS lost**, **GPS recover**, **Max altitude**: the sound per event: `Off`, `Default` or any `.wav` you put into `/SOUNDS/en/SCRIPTS/GPSHOMER/`. **Play** previews it.
- **Last flights**: where the model was when the telemetry ended, for the last three flights, with date, time, model name, coordinates and a **QR code**. Scan it with a phone and the map app opens on that spot.

Units follow the radio's own setting (**SYS → Radio setup → Units**: metric gives m and km/h, imperial ft and mph). Set the units of the altitude and speed sensors on the radio to match.

Tap the **GPS Homer** icon for **Reset settings** (the flight list stays), **Clear flights**, **Factory reset** (both) and the version. A warning sign on the icon means something needs attention (for example no settings file yet); the popup says what to do.

---

## 🛠️ Troubleshooting

- **Widget shows "Configuration error / Please check Tool Flight Bag":** One of the required sensors (`GPS`, `Sats`, `GSpd`, `Hdg`) has never been discovered. Open **Tools → Flight Bag** and tap the GPS Homer icon (it carries a warning sign): the popup names the sensor. Enable GPS telemetry on the flight controller, then run a telemetry discovery on the radio while the GPS has a fix.
- **Preflight page stays on `NO FIX` or `FIX SETTLING`:** Not enough satellites yet, or the fix keeps dropping. Give the GPS a clear view of the sky, away from buildings and the car.
- **Widget shows `NO HOME` after arming, no "Home set" was spoken:** You armed before the GPS had enough satellites, so there is no home point for this flight. Land, disarm, wait for "Ready to fly" and arm again.
- **"Ready to fly" and "Home set" always come together, before arming:** The radio does not know when the model is armed because the `FM` sensor is missing. Run a telemetry discovery to add it; until then home is stored at the first stable fix, and the model must not move before that. Some flight controllers need an extra setting for this, see [`docs/compatibility.md`](docs/compatibility.md#setup).
- **No arrow, only a direction like "SW 220°":** The model is moving slower than 6 km/h, so the GPS cannot tell the flight direction yet. The arrow appears as soon as you fly. After 2 s straight at 25 km/h or more it also stays while hovering, for up to 60 s.
- **No voice at all:** Check that the `.wav` files really are in `/SOUNDS/en/SCRIPTS/GPSHOMER/` (the `en` folder is required even if your radio uses another language). The quickest check is Flight Bag: on the **Alerts** page dive into an event and press **Play**.
- **A screen reports a missing file:** Copy the folders from this repository again, the file tree above lists everything that belongs on the card.

---

## 🤝 Contributing

Found a bug or have an idea for an improvement? Please [open an issue](../../issues) on GitHub. Pull requests are welcome too.

---

## ⚠️ Disclaimer

This project is provided **as is** and is meant as an additional aid only. It does **not** replace careful flying within visual range, your own judgement, GPS rescue on the flight controller, or the safety mechanisms of your transmitter and receiver. Always be ready to react manually. Use at your own risk.

---

## 📄 License

Released under the [GNU General Public License v2.0](LICENSE).
