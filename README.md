# aorus-ctl

Native macOS control for **Gigabyte / AORUS monitors** over USB HID — a zero-dependency Swift replacement for the Windows-only Gigabyte **OSD Sidekick**.

## Model compatibility — what's tested vs. what's likely

**Tested on:** AORUS **CO49DQ** (49" QD-OLED). Every claim in this repo marked
"confirmed" or "live" refers to that one panel.

**Built on** the community-decoded protocol that's shared by a family of
Gigabyte monitors driven by the same **Realtek HID controller** (`VID 0x0bda`
/ `PID 0x1100`) — e.g. the M27Q / M32U / M32Q / M32QC / M28UC used by the prior-art
tools (kelvie/gbmonctl, ayufan m32u-ddcctl). So this is **not** a CO49DQ-only
tool; it's *likely* to work on any Gigabyte/AORUS panel using that controller.

**How to bound the universe of workable monitors** — there's no firmware-level
guarantee, so treat compatibility as a to-be-verified claim, narrowed by these
checks, in order of strength:

1. **The controller is the deciding factor, not the model name.** Walk back from
   "does it work on monitor X?" to "does monitor X expose `0x0bda:0x1100`?".
   `aorusctl list` answers that in one command. If the VID:PID matches, the
   transport and the command table are very likely applicable.
2. **Same controller ⇒ the frame format carries over** (fixed preamble, 192-byte
   report, 0xe0XX vendor prefix, no checksum byte). A different controller
   (“no device found”, or a different VID:PID) means the protocol is
   *probably* different and needs a fresh look — do **not** trust `set` on an
   unverified controller.
3. **Per-command variance:** even on a compatible controller, individual opcodes
   differ by panel. An opcode that's ignored on one SKU may do nothing on
   another. Treat the table as a starting point and spot-check each control you
   care about (`--dry-run` first, then apply) before relying on it.
4. **Different controller but curious?** The USB HID protocol is independent of
   the video output, and OSD Sidekick controls are interchangeable across the
   family, but a non-0x0bda:0x1100 controller *could* use a different report
   size or command layout. One OSD Sidekick re-sniff (USBPcap + Wireshark, see
   [docs/protocol.md §6]) resolves it with certainty.

**Bottom line:** expect it to work on Realtek-HID Gigabyte/AORUS panels; verify
it per-model and per-control. The on-hardware bring-up checklist below is the
practical way to do that on a new panel.

Deep-dive reverse-engineering notes:

- [docs/protocol.md](docs/protocol.md) — device, report descriptor, exact frame, the report-size STALL fix, and the status-read problem.
- [docs/ddc-vendor-commands.md](docs/ddc-vendor-commands.md) — the vendor command table.
- [docs/prior-art.md](docs/prior-art.md) — the community projects this builds on.

## Why this works

Gigabyte monitors in this family are driven by a **Realtek HID controller** (`VID 0x0bda / PID 0x1100`). The controller exposes a standard USB HID interface, so **macOS needs no driver** — any user-space app can open it via IOKit and send a 192-byte vendor report. That's the entire gap: OSD Sidekick is Windows-only, so nobody wrote the macOS equivalent. We did.

The vendor report effectively **encapsulates DDC/CI**, and the command opcodes are the same ones used over the HDMI/DP/Type-C cable.

## Credits & thanks

This project is possible **entirely because** of the public reverse-engineering work of the community. The protocol was decoded well before this repo existed; `aorus-ctl` is a native-macOS re-implementation that stands on their shoulders.

**Primary reference** — the tool this is byte-for-byte modeled on:

- **[kelvie/gbmonctl](https://github.com/kelvie/gbmonctl)** — the working Go driver that established the exact frame layout and vendor command encoding. GB = Gigabyte, "mon" = monitor, "ctl" = control. If you want the canonical implementation, read this first.
- **kelvie's [OSD Sidekick reversing gist](https://gist.github.com/kelvie/fa562c4643c4abc8d91bb192b325995b)** — the pcap/disassembly notes that cracked the `0x40 0xc6 … 0x51` frame shape and the DDC/CI encapsulation.
- **[ayufan-research/gigabyte-m32u-ddcctl](https://github.com/ayufan-research/gigabyte-m32u-ddcctl)** — the most complete vendor command table (brightness/contrast, colour, PBP/PIP, KVM, game modes).

**Corroborating ports** (independent confirmation the protocol is right):

- [wkhughes/gigabyte-kvm-switch](https://github.com/wkhughes/gigabyte-kvm-switch) · [MarekPrzydanek/GigabyteMonitorController](https://github.com/MarekPrzydanek/GigabyteMonitorController) · [thilobillerbeck/gbmoncli](https://github.com/thilobillerbeck/gbmoncli) · [WildFireFlum/gbmonitor](https://github.com/WildFireFlum/gbmonitor) · [SIMULATAN/aoruscontrol](https://github.com/SIMULATAN/aoruscontrol)

A full catalog with what each project proved is in [docs/prior-art.md](docs/prior-art.md).

Present-day monitors also borrow heavily from [MonitorControl](https://github.com/MonitorControl/MonitorControl)'s Apple Silicon DDC path (the `IOAVService` / `DCPAVServiceProxy` mechanism) for the cable-DDC `get` reads.

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
aorusctl get <prop>           Read brightness/contrast/volume/sharpness via cable-DDC
aorusctl props                List all known properties + ranges
aorusctl dump                 Dump the raw HID status report (hex) (⚠ experimental)
aorusctl --dry-run set p v    Print the exact report bytes without sending
```

Properties (ranges in parentheses):

| Property | Range | Notes |
| --- | --- | --- |
| `brightness` / `contrast` / `volume` | 0–100 | DDC/CI opcodes 0x10 / 0x12 / 0x62 |
| `sharpness` | 0–10 | opcode 0x87 |
| `black-equalizer` | 0–20 | vendor 0xe000 |
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

## On-hardware verification (confirmed on the CO49DQ)

All status below was verified on the **AORUS CO49DQ** specifically. These are not
claims about other models — see [Model compatibility](#model-compatibility--whats-tested-vs-whats-likely)
for how to bound what works on a different panel.

Status of the interfaces on the actual panel:

- **`aorusctl list`** — ✅ confirmed: finds `0x0bda:0x1100 HID Device [Realtek]`.
- **`aorusctl set <prop> <value>`** — ✅ **confirmed**: `set brightness 45` → `45` read-back and visibly applies on the CO49DQ. Standard VCP controls (brightness/contrast/volume/sharpness) are written over the **video-cable DDC** channel; vendor controls (KVM, PBP/PIP, picture modes, colour) go over the **USB HID** controller.
- **`aorusctl get <prop>`** — ✅ **confirmed**: reads the monitor's **real** current values over the video-cable **DDC** channel. On the CO49DQ: `get brightness` → `75 / 100`, `get contrast` → `50 / 100`, `get volume` → `30 / 100`, `get sharpness` → `5 / 10`. (The USB HID controller itself is write-only and cannot serve these; the DDC read is what powers this.)
- **`aorusctl dump`** — ⚠️ dump of the raw HID status blob still STALLs (the HID input report has no read-back). No longer needed for control; see [docs/protocol.md §5](docs/protocol.md).

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
  - command bytes: single byte for `0x10/0x12/0x87...`; two bytes `0xe0 XX` for vendor controls
  - value: **2-byte big-endian** (`0x0000`–`0xffff`)
  - **no checksum byte** — trailing bytes are zero (matches gbmonctl)

> **Encoding gotcha (verified on the CO49DQ):** the vendor prefix is `0xe0` in
> the HID frame, **not** the `0x0e` used in ddcutil-style community tables. Using
> `0x0e` makes the panel silently ignore the write. See
> [docs/protocol.md §3](docs/protocol.md#3-the-frame-what-to-actually-write).

### ⚠️ Report size — send 192 bytes, not 193

The report descriptor (**no report-ID item**, `MaxOutputReportSize = 192`) expects a **bare 192-byte** output report. Sending the conventional 193-byte frame (leading report-ID byte + 192 payload) makes the device STALL the pipe with `kUSBHostReturnPipeStalled` (`0xe0005000`). gbmonctl gets away with a 193-byte Go buffer only because hidapi peels the report-ID byte off; direct IOKit callers must transmit the 192-byte payload with `reportID 0`. See [docs/protocol.md §4](docs/protocol.md#4--the-report-size-trap-usb-pipe-stall).

Full prior-art catalog and credits: see the [Credits & thanks](#credits--thanks) section and [docs/prior-art.md](docs/prior-art.md).

## Roadmap

- [x] Protocol engine + frame builder (verified against gbmonctl's known-good bytes)
- [x] **HID transport over IOKit (write path verified live on the CO49DQ)**
- [x] CLI (`set` / `list` / `props` / dump / dry-run)
- [x] Deep-dive docs (`docs/`)
- [x] **SwiftUI menu-bar app** (`AorusApp`) — sliders, PBP/PIP, KVM, picture modes, colour
- [x] **Real reads over cable-DDC** (`DDCReader`) — brightness/contrast/volume/sharpness live values via `get` and in the app; verified live on the CO49DQ
- [ ] Decode the remaining 2-arg vendor DDC reads (picture mode, PBP/PIP) for a fuller read-back
- [ ] Handle alternate controller VID:PID if a different panel uses one

## Safety

This talks only to the HID **control** interface — it sends vendor settings, never firmware updates, so a bad value or protocol mismatch at worst gets ignored by the panel. It cannot brick the monitor.

## License

MIT.
