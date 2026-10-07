# Compatibility

This page shows which GPS Homer features work with which flight controller firmware and which RC link. Each table looks at one side of the chain and assumes the other side delivers its data.

## Flight controller firmware

| Feature | Betaflight | INAV | ArduPilot |
|---|:-:|:-:|:-:|
| Link detection | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> |
| Home set on arming | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> | ⚙️&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> |
| Direction to home (arrow) | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> | ⚙️&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> |
| Distance to home | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> | ⚙️&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> |
| RETURN TO HOME / FAILSAFE / LANDING line | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> | ⚙️&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> |
| Voice announcements | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> | ⚙️&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> |
| Last position (flight log) | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> | ⚙️&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> |
| Altitude above home, Max altitude warning | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> | ⚙️&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> |
| GPS accuracy (DOP) on the ground | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> | ⚙️&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> |
| Arrow while hovering | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> | ⚙️&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> |

- **Altitude:** all three send it in the GPS frame (Betaflight and ArduPilot the GPS altitude, INAV its estimated altitude); the widget shows it relative to home. Without an altitude there is no Max altitude warning.
- **GPS accuracy:** the widget asks Betaflight and INAV over MSP; Betaflight answers with PDOP, INAV with HDOP. ArduPilot does not answer MSP, but sends the HDOP on its own in its passthrough telemetry: always in ExpressLRS MAVLink mode, over CRSF only with `RC_OPTIONS` option "CRSF custom telemetry" (see Setup).
- **Arrow while hovering:** all three send their attitude (yaw and roll) over CRSF; ArduPilot in MAVLink mode too (the ExpressLRS TX module converts it). With the `RC_OPTIONS` option "CRSF custom telemetry" ArduPilot sends it only once per second (0.33 Hz on slow links, instead of 8 Hz), so the arrow follows a yaw on the spot with a delay.

## RC link

| Feature | ExpressLRS | TBS Crossfire | ImmersionRC Ghost | FrSky ACCESS |
|---|:-:|:-:|:-:|:-:|
| Link detection | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> |
| Home set on arming | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ❌&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ❌&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> |
| Direction to home (arrow) | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ❌&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ❌&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> |
| Distance to home | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ❌&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> |
| RETURN TO HOME / FAILSAFE / LANDING line | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ❌&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ❌&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> |
| Voice announcements | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ❌&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> |
| Last position (flight log) | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ❌&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> |
| Altitude above home, Max altitude warning | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ❌&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> |
| GPS accuracy (DOP) on the ground | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ❌&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ❌&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> |
| Arrow while hovering | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ❌&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ❌&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> |

- **ImmersionRC Ghost:** EdgeTX decodes the GPS course 1000 times too small (reported as [EdgeTX #7841](https://github.com/EdgeTX/edgetx/issues/7841)), so the arrow points the wrong way. Betaflight sends no flight mode over Ghost, so home is set at the first stable fix instead of on arming, and there is no status line. Checked with Betaflight only; INAV and ArduPilot over Ghost were not checked.
- **GPS accuracy over Ghost:** the widget sends its MSP request over CRSF only, so it is not available with Ghost.
- **Arrow while hovering over Ghost:** EdgeTX decodes no attitude from Ghost.
- **FrSky ACCESS:** no flight controller sends the satellite count as its own sensor, so GPS Homer always shows "Configuration error" (Flight Bag names the missing `Sats` sensor).

## Legend

- ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> Tested on the radio and in the simulator.
- ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> Checked in the source code (flight controller, ExpressLRS and EdgeTX), not tested on hardware yet.
- ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> Radio side checked in the source code; the firmware of the RC link itself is closed source, so that part could not be checked.
- ⚙️ Works only after setup, see below. A badge next to ⚙️ means the same as next to ✅.
- ❌ Does not work, see the notes under the table. A badge next to ❌ says how far it was checked.

A ✅ means the feature works without extra setup, apart from GPS telemetry being enabled on the flight controller and the sensors being discovered on the radio.

Home, the armed state and the status line under the compass come from the flight mode text (`FM`) the flight controller sends. Without `FM` home is set at the first stable fix instead of on arming, and there is no status line.

ArduPilot has no failsafe text: a failsafe only switches the flight mode, so the line shows RETURN TO HOME or LANDING for that mode (or nothing, e.g. for Brake), never FAILSAFE.

## Setup

What has to be set so the features work.

### Flight controller (with ExpressLRS or TBS Crossfire)

| Firmware | Flight controller | Radio |
|---|---|---|
| **Betaflight** | GPS enabled and GPS telemetry not disabled. | Nothing to change. |
| **INAV** | `feature GPS`, `feature TELEMETRY` (off by default on some boards) and the receiver set up as CRSF (`serialrx_provider = CRSF`). | Nothing to change. |
| **ArduPilot** | Receiver on a serial port with `SERIALx_PROTOCOL = 23` (RCIN), which RC control over CRSF needs anyway. `RC_OPTIONS` option "CRSF flight mode disarm star" (recommended: without it `FM` has no disarmed marker, so home is set at the first stable GPS fix instead of on arming; not needed in MAVLink mode). | Nothing to change. |

If the receiver runs in MAVLink mode instead of CRSF, the ExpressLRS TX module builds the telemetry from ArduPilot's MAVLink messages. Copter then sends no GPS data by default: set the extended status stream rate `MAVn_EXT_STAT` of the MAVLink channel the receiver is on to at least 1 Hz (parameter name as of ArduPilot master, September 2026).

GPS accuracy with ArduPilot over CRSF needs the `RC_OPTIONS` option "CRSF custom telemetry" (bit 8, value 256). It also slows down the flight mode (0.5 Hz) and GPS (1 to 2 Hz) telemetry, so only set it if you want the value. In MAVLink mode the value comes without it.

### RC link

| Link | Flight controller | Radio |
|---|---|---|
| **ExpressLRS**, **TBS Crossfire** | Nothing extra. | Nothing to change. |
| **ImmersionRC Ghost** | Nothing extra. Betaflight only sends the GPS frames with GPS enabled and GPS telemetry not disabled. | Nothing to change. |
| **FrSky ACCESS** | Not supported. | |
