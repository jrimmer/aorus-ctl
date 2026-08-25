# aorus-ctl

Native macOS control for **Gigabyte / AORUS monitors** over USB HID — a zero-dependency Swift replacement for the Windows-only Gigabyte **OSD Sidekick**.

Tested target: **AORUS CO49DQ** (49" QD-OLED). Built on the community-decoded protocol shared across Gigabyte's Realtek-HID monitors (M27Q / M32U / M32Q / M32QC / M28UC).

Deep-dive reverse-engineering notes:

- [docs/protocol.md](docs/protocol.md) — device, report descriptor, exact frame, the report-size STALL fix, and the status-read problem.
- [docs/ddc-vendor-commands.md](docs/ddc-vendor-commands.md) — the vendor command table.
- [docs/prior-art.md](docs/prior-art.md) — the community projects this builds on.

## Why this works

Gigabyte monitors in this family are driven by a **Realtek HID controller** (`VID 0x0bda / PID 0x1100`). The controller exposes a standard USB HID interface, so **macOS needs no driver** — any user-space app can open it via IOKit and send a 192-byte vendor report. That's the entire gap: OSD Sidekick is Windows-only, so nobody wrote the macOS equivalent. We did.

The vendor report effectively **encapsulates DDC/CI**, and the command opcodes are the same ones used over the HDMI/DP/Type-C cable.

## Build & run

CLI:

```bash
swift build            # requires Xcode + Command Line Tools (macOS, Apple Silicon or Intel)
.build/debug/aorusctl list
.build/debug/aorusctl --dry-run set brightness 50   # show bytes, don't send
.build/debug/aorusctl set brightness 50             # actually apply
```

Menu-bar app:

```bash
swift run AorusApp       # launches a menu-bar icon → control panel
```

> **Hardware precondition:** the monitor's **USB upstream** must be connected to the Mac. For the CO49DQ this is either the **USB-B** upstream port (the OSD Sidekick cable) or the **USB-C / Type-C** upstream port (which also carries KVM).

## CLI reference

```
aorusctl list                 Discover monitor control device(s)
aorusctl set <prop> <value>   Set a property on the monitor
aorusctl get <prop>           Read a property from the monitor (⚠ experimental)
aorusctl props                List all known properties + ranges
aorusctl dump                 Dump the raw status report (hex) (⚠ experimental)
aorusctl --dry-run set p v    Print the exact report bytes without sending
```

Properties (ranges in parentheses):

| Property | Range | Notes |
| --- | --- | --- |
| `brightness` / `contrast` / `volume` | 0–100 | DDC/CI opcodes 0x10 / 0x12 / 0x62 |
| `sharpness` | 0–10 | opcode 0x87 |
| `black-equalizer` | 0–20 | vendor 0x0e00 |
| `colour-mode` | 0–3 | 0 cool, 1 normal, 2 warm, 3 user-defined |
| `rgb-red` / `rgb-green` / `rgb-blue` | 0–100 | only effective when colour-mode = 3 |
| `gamma` | 0–5 | 0 off, 1=1.8 … 5=2.6 |
| `vibrance` | 0–20 | |
| `overdrive` | 0–2 | 0 quality, 1 balance, 2 speed |
| `low-blue-light` | 0–10 | |
| `free-sync` | 0–1 | |
| `pbp-pip-mode` | 0–2 | 0 off, 1 PIP, 2 PBP |
| `pbp-pip-source` | 0–3 | 0 HDMI1, 1 HDMI2, 2 DP, 3 Type-C |
| `pbp-pip-switch` / `pip-audio-switch` | 0–9 | use 1 |
| `pip-size` | 0–2 | 0 large, 1 medium, 2 small |
| `pip-location` | 0–3 | 0 TL, 1 TR, 2 BL, 3 BR |
| `picture-mode` | 0–8 | 0 standard, 1 FPS, 2 RTS/RPG, 3 Movie, 4 Reader, 5 sRGB, 6–8 custom |
| `source` | 0–3 | 0 HDMI1, 1 HDMI2, 2 DP, 3 Type-C |
| `audio-input` | 0–2 | 0 main, 1 PIP/PBP, 2 auto |
| `osd-display-time` | 0–5 | 0=5s … 5=30s |
| `led-indicator` | 0–2 | 0 always on, 1 always off, 2 standby on |
| `kvm-switch` | 0–1 | **0 = USB-B, 1 = Type-C** |

## On-hardware verification (confirmed on CO49DQ)

Status of the write path on the actual panel:

- **`aorusctl list`** — ✅ confirmed: finds `0x0bda:0x1100 HID Device [Realtek]`.
- **`aorusctl set <prop> <value>`** — ✅ **confirmed**: e.g. `set brightness 50` / `30` / `70` visibly apply on the CO49DQ. The write path is verified on real hardware.
- **`aorusctl dump` / `get`** — ⚠️ **not yet working.** Reading current status back is an open problem (the reference gbmonctl never reads either). See [docs/protocol.md §5](docs/protocol.md).*

For first-time bring-up on a *different* panel:

1. `aorusctl list` — confirms USB enumeration. If the VID:PID is **not** `0bda:1100`, note it; the protocol may still match but a different controller warrants one OSD Sidekick re-sniff (USBPcap + Wireshark) before trusting `set`.
2. `aorusctl --dry-run set brightness 50` — print the exact bytes before applying.
3. `aorusctl set brightness 50` — the display should visibly dim.
4. `aorusctl set pbp-pip-mode 2` (PBP) and `set pbp-pip-source 1` — verify PBP engages.

## Protocol notes

The frame is 192 bytes: a bare vendor report (see the important note below — it is **not** 193 bytes on the wire).

- Payload preamble: `40 c6 ... 20 00 6e 00 80` (fixed)
- Command block at payload offset `0x40`:
  - `0x51` — message marker
  - `0x81 + len(msg)` — message length (write)
  - `0x03` — write opcode
  - command bytes: single byte for `0x10/0x12/0x87...`; two bytes `0x0e XX` for vendor controls
  - value byte
  - checksum byte

### ⚠️ Report size — send 192 bytes, not 193

The report descriptor (**no report-ID item**, `MaxOutputReportSize = 192`) expects a **bare 192-byte** output report. Sending the conventional 193-byte frame (leading report-ID byte + 192 payload) makes the device STALL the pipe with `kUSBHostReturnPipeStalled` (`0xe0005000`). gbmonctl gets away with a 193-byte Go buffer only because hidapi peels the report-ID byte off; direct IOKit callers must transmit the 192-byte payload with `reportID 0`. See [docs/protocol.md §4](docs/protocol.md#4--the-report-size-trap-usb-pipe-stall).

Checksum (matches gbmonctl exactly):

```
low  nibble = XOR of every message byte's low nibble, seeded with 0x6
high nibble = (last message byte XOR 0xc0) & 0xf0
```

Prior art this is built on: [kelvie/gbmonctl](https://github.com/kelvie/gbmonctl), [kelvie's OSD-sidekick reversing gist](https://gist.github.com/kelvie/fa562c4643c4abc8d91bb192b325995b), [ayufan-research/gigabyte-m32u-ddcctl](https://github.com/ayufan-research/gigabyte-m32u-ddcctl).

## Roadmap

- [x] Protocol engine + checksum (verified against gbmonctl's known-good bytes)
- [x] **HID transport over IOKit (write path verified live on the CO49DQ)**
- [x] CLI (`set` / `list` / `props` / dump / dry-run)
- [x] Deep-dive docs (`docs/`)
- [x] **SwiftUI menu-bar app** (`AorusApp`) — sliders, PBP/PIP, KVM, picture modes, colour
- [ ] True `get <prop>` reads — **blocked by hardware**: the CO49DQ HID controller is write-only; reads need cable-DDC (see docs/protocol.md §5)
- [ ] Handle alternate controller VID:PID if a different panel uses one

## Safety

This talks only to the HID **control** interface — it sends vendor settings, never firmware updates, so a bad value or protocol mismatch at worst gets ignored by the panel. It cannot brick the monitor.

## License

MIT.
