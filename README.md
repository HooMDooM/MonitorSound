# MonitorSound

Tiny macOS menu bar app that makes the **keyboard volume keys work for external monitors** connected over HDMI / DisplayPort / USB‑C.

When a Mac sends audio to a monitor's built‑in speakers (or its headphone jack), macOS has no volume control for that output — the volume keys show a greyed‑out slider and do nothing. MonitorSound intercepts the volume keys and changes the volume **inside the monitor itself** using DDC/CI, the same channel the monitor's on‑screen menu uses.

- 🔊 Volume Up / Down / Mute keys work again when audio goes to a monitor
- Each key press changes the volume by 5 (out of the monitor's 0–100); ⌥⇧ + volume keys for 1‑unit fine steps
- On‑screen volume indicator — hover it to keep it open, then click/drag the bar or scroll to adjust
- Menu bar icon with a volume slider and mute toggle
- Starts automatically at login
- Zero added latency — audio is not re‑routed or processed, only the monitor's own volume is changed
- If the current audio output is not a DDC‑capable monitor (e.g. headphones, AirPods, built‑in speakers), the keys are passed through to macOS untouched

## Requirements

- Mac with **Apple Silicon** (M1 or newer)
- macOS 13 Ventura or newer
- A monitor that supports **DDC/CI** volume control (make sure DDC/CI is enabled in the monitor's OSD menu)
- Xcode or the Xcode Command Line Tools (`xcode-select --install`) to build

> Some docks, adapters and KVM switches do not pass DDC/CI through. If the monitor doesn't respond, try connecting it directly.

## Installation

```bash
git clone https://github.com/HooMDooM/MonitorSound.git
cd MonitorSound
./build.sh --install
```

This builds `MonitorSound.app`, copies it to `/Applications` and launches it.

Then, one time:

1. macOS will ask to grant **Accessibility** access — open *System Settings → Privacy & Security → Accessibility* and turn on **MonitorSound**. This is required to intercept the volume keys. The app picks the permission up automatically within a couple of seconds.
2. Make sure the monitor is selected as the sound output (*System Settings → Sound → Output*).
3. Press the volume keys. 🎉

The app registers itself as a login item on first launch. You can toggle it via the menu bar icon → **Launch at login** (also visible in *System Settings → General → Login Items*).

### Updating

```bash
git pull
./build.sh --install
```

The app is ad‑hoc signed, so after every rebuild macOS treats it as a new binary and the Accessibility toggle stops applying. If the keys stop working after an update, reset the permission and grant it again:

```bash
tccutil reset Accessibility local.monitorsound
```

### Uninstall

```bash
pkill -x MonitorSound
rm -rf /Applications/MonitorSound.app
tccutil reset Accessibility local.monitorsound
```

## Checking DDC support

A small CLI tool is included to test whether your monitor answers DDC volume commands:

```bash
mkdir -p build
swiftc -O -o build/ddctest Sources/DDC.swift Tools/main.swift -framework IOKit
./build/ddctest        # prints current volume of every external monitor
./build/ddctest 30     # sets volume to 30 on every DDC-capable monitor
```

Monitors that print `no DDC reply` don't support DDC over the current connection.

## How it works

- `Sources/DDC.swift` — talks DDC/CI (VCP code `0x62`, audio volume) over I²C using the `IOAVService` API available on Apple Silicon. Displays are discovered in the IORegistry and matched by product name.
- `Sources/main.swift` — the app: a `CGEventTap` catches the media keys, CoreAudio tells which device is the current default output, and if its name matches a DDC‑capable display the volume change is sent to the monitor instead of macOS.

## Limitations

- The macOS Control Center / menu bar **Sound** slider stays greyed out. macOS only enables it for audio devices that have software volume, and adding one would require a virtual audio driver that re‑routes audio (adding latency). Use the volume keys or the MonitorSound menu bar slider instead.
- If you change the volume with the monitor's own buttons, MonitorSound re‑reads it the next time you open its menu.
- Intel Macs are not supported (they use a different DDC API).

## License

MIT
