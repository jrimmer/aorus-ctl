# CLI reference

The menu-bar app is the main product. For power users and bring-up, the repo also ships a `aorusctl` CLI.

## Build

```bash
swift build            # requires Xcode + Command Line Tools
```

## Usage

```text
aorusctl list                 Discover monitor control device(s)
aorusctl set <prop> <value>   Set a property on the monitor
aorusctl get <prop>           Read brightness/contrast/volume/sharpness via cable-DDC
aorusctl props                List all known properties + ranges
aorusctl dump                 Dump the raw HID status report (hex) (⚠ experimental)
aorusctl --dry-run set p v    Print the exact report bytes without sending
```

Examples:

```bash
.build/debug/aorusctl list
.build/debug/aorusctl --dry-run set brightness 50   # show bytes, don't send
.build/debug/aorusctl set brightness 50             # actually apply
.build/debug/aorusctl get brightness                # read via cable-DDC
```

## Properties

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

## Concept: HID vs. DDC routing

Standard VCP controls (brightness, contrast, volume, sharpness) are written over the **video-cable DDC** channel. Vendor controls (KVM, PBP/PIP, picture modes, colour) go over the **USB HID** controller. See [protocol.md](protocol.md).
