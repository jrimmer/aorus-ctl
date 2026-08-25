# aorus-ctl

Native macOS control for **Gigabyte / AORUS monitors** over USB HID — a zero-dependency Swift replacement for the Windows-only Gigabyte **OSD Sidekick**.

Tested target: **AORUS CO49DQ** (49" QD-OLED). Built on the community-decoded protocol shared across Gigabyte's Realtek-HID monitors (M27Q / M32U / M32Q / M32QC / M28UC).

## Why this works

Gigabyte monitors in this family are driven by a **Realtek HID controller** (`VID 0x0bda / PID 0x1100`). The controller exposes a standard USB HID interface, so **macOS needs no driver** — any user-space app can open it via IOKit and send a 192-byte vendor report. That's the entire gap: OSD Sidekick is Windows-only, so nobody wrote the macOS equivalent. We did.

The vendor report effectively **encapsulates DDC/CI**, and the command opcodes are the same ones used over the HDMI/DP/Type-C cable.

## Build & run

```bash
swift build            # requires Xcode + Command Line Tools (macOS, Apple Silicon or Intel)
.build/debug/aorusctl list
.build/debug/aorusctl --dry-run set brightness 50   # show bytes, don't send
.build/debug/aorusctl set brightness 50             # actually apply
```

> **Hardware precondition:** the monitor's **USB upstream** must be connected to the Mac. For the CO49DQ this is either the **USB-B** upstream port (the OSD Sidekick cable) or the **USB-C / Type-C** upstream port (which also carries KVM).

## CLI reference

```
aorusctl list                 Discover monitor control device(s)
aorusctl set <prop> <value>   Set a property on the monitor
aorusctl get <prop>           Read status (raw report)
aorusctl props                List all known properties + ranges
aorusctl dump                 Dump the raw 193-byte status report (hex)
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

## On-hardware verification (4 steps)

Because no CO49DQ-specific unit exists in public tests yet, verify on your actual panel before trusting it for anything important:

1. **`aorusctl list`** — confirms USB enumeration.
   - If you see `0bda:1100 ... Realtek ... HID Device`, protocol match is confirmed.
   - If you see a *different* VID:PID, note it — the protocol may still match, but a different controller means we should re-sniff OSD Sidekick once (USBPcap + Wireshark) to confirm the frame layout before trusting `set`.
   - If nothing shows, ensure upstream USB is plugged in, then `aorusctl list`.

2. **`aorusctl dump`** — captures the 193-byte status report; sanity-check it's non-zero.

3. **`aorusctl set brightness 50`** — the display should visibly dim.

4. **`aorusctl set pbp-pip-mode 2`** (PBP) and `set pbp-pip-source 1` — verify PBP engages.

Each command prints the exact bytes it sent with `--dry-run` first, so you can confirm before committing anything.

## Protocol notes

The frame is 193 bytes: a leading report id `0x00` plus a 192-byte payload.

- Payload preamble: `40 c6 ... 20 00 6e 00 80` (fixed)
- Command block at payload offset `0x40`:
  - `0x51` — message marker
  - `0x81 + len(msg)` — message length (write)
  - `0x03` — write opcode
  - command bytes: single byte for `0x10/0x12/0x87...`; two bytes `0x0e XX` for vendor controls
  - value byte
  - checksum byte

Checksum (matches gbmonctl exactly):

```
low  nibble = XOR of every message byte's low nibble, seeded with 0x6
high nibble = (last message byte XOR 0xc0) & 0xf0
```

Prior art this is built on: [kelvie/gbmonctl](https://github.com/kelvie/gbmonctl), [kelvie's OSD-sidekick reversing gist](https://gist.github.com/kelvie/fa562c4643c4abc8d91bb192b325995b), [ayufan-research/gigabyte-m32u-ddcctl](https://github.com/ayufan-research/gigabyte-m32u-ddcctl).

## Roadmap

- [x] Protocol engine + checksum (verified against gbmonctl's known-good bytes)
- [x] HID transport over IOKit (discovery, write, read)
- [x] CLI (`set` / `list` / `props` / `dump` / dry-run)
- [ ] On-hardware verification on the CO49DQ
- [ ] Decode the status report for true `get <prop>` reads
- [ ] **SwiftUI menu-bar app** wrapping AorusCore (sliders, PBP/PIP toggles, KVM switch)
- [ ] Handle alternate controller VID:PID if the CO49DQ differs from 0bda:1100

## Safety

This talks only to the HID **control** interface — it sends vendor settings, never firmware updates, so a bad value or protocol mismatch at worst gets ignored by the panel. It cannot brick the monitor.

## License

MIT.
