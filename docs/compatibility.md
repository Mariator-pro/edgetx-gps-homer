# Compatibility

This page shows which GPS Homer features work with which flight controller firmware. The GPS data has to reach the radio over ExpressLRS (CRSF telemetry).

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

## Legend

- ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> Tested on the radio and in the simulator.
- ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> Checked in the source code (flight controller, ExpressLRS and EdgeTX), not tested on hardware yet.
- ⚙️ Works only after setup, see below. A badge next to ⚙️ means the same as next to ✅.

A ✅ means the feature works without extra setup, apart from GPS telemetry being enabled on the flight controller and the sensors being discovered on the radio.

Home, the armed state and the status line under the compass come from the flight mode text (`FM`) the flight controller sends. Without `FM` home is set at the first stable fix instead of on arming, and there is no status line.

ArduPilot has no failsafe text: a failsafe only switches the flight mode, so the line shows RETURN TO HOME or LANDING for that mode (or nothing, e.g. for Brake), never FAILSAFE.

## Setup

What has to be set so the features work.

| Firmware | Flight controller | Radio |
|---|---|---|
| **Betaflight** | GPS enabled and GPS telemetry not disabled. | Nothing to change. |
| **INAV** | `feature GPS`, `feature TELEMETRY` (off by default on some boards) and the receiver set up as CRSF (`serialrx_provider = CRSF`). | Nothing to change. |
| **ArduPilot** | Receiver on a serial port with `SERIALx_PROTOCOL = 23` (RCIN), which RC control over CRSF needs anyway. `RC_OPTIONS` option "CRSF flight mode disarm star" (without it `FM` has no disarmed marker, so home is never set; not needed in MAVLink mode). | Nothing to change. |

If the receiver runs in MAVLink mode instead of CRSF, the ExpressLRS TX module builds the telemetry from ArduPilot's MAVLink messages. Copter then sends no GPS data by default: set the extended status stream rate `MAVn_EXT_STAT` of the MAVLink channel the receiver is on to at least 1 Hz (parameter name as of ArduPilot master, September 2026).
