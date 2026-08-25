# DDC / Vendor Command Table

The opcodes AORUS/GB monitors accept are the same **DDC/CI capture** opcodes used
over the video cable, forwarded through the Realtek HID controller. Two families
exist: **standard DDC/CI VCP opcodes** (single byte, defined by the VESA DDC/CI
specification) and **vendor 2-byte opcodes** (prefix `0xe0` in the HID frame,
Gigabyte-specific).

`Protocol.swift` in `AorusCore` encodes the non-denormalized subset below. The
table itself is recovered from community RE — primarily
`ayufan-research/gigabyte-m32u-ddcctl` — and cross-checked against
`kelvie/gbmonctl` and the OSD Sidekick reversing gist (see
[docs/prior-art.md](./prior-art.md)).

> **Scope / compatibility.** The command encoding (`0xe0` vendor prefix, 2-byte
> value, no checksum) was **verified live on an AORUS CO49DQ**. The same Realtek
> HID controller (`0x0bda:0x1100`) drives a family of Gigabyte monitors (M27Q /
> M32U / M32Q / M32QC / M28UC), so the *transport* applies broadly — but
> **individual opcodes and their ranges are not guaranteed to be identical**
> across models. On a new panel, spot-check each control you care about
> (`aorusctl --dry-run` then apply) before relying on a row. Rows sourced only
> from other SKUs are marked below. See [model compatibility](compatibility.md).

---

## Standard DDC/CI (single command byte + value)

| Opcode | Control | `aorus-ctl` name | Range | Notes |
| --- | --- | --- | --- | --- |
| `0x10` | Brightness | `brightness` | 0–100 | VCP 0x10 |
| `0x12` | Contrast | `contrast` | 0–100 | VCP 0x12 |
| `0x62` | Volume (audio) | `volume` | 0–100 | VCP 0x62 (if panel has speakers) |
| `0x87` | Sharpness | `sharpness` | 0–10 | VCP 0x87 |

## Vendor commands (2-byte opcode, prefix `0xe0`)

Value meanings where impactful are listed; otherwise it is a normalized scale.

> **Encoding gotcha (verified on the CO49DQ):** in the HID frame the vendor
> command word is `0xe0` + subcode (`0xe0 0xXX`). The `0x0e` prefix that appears
> in some community tables (e.g. `ayufan-research/gigabyte-m32u-ddcctl`
> `vendor_ext 0x0e`) is the ddcutil/DDC *data* notation, NOT what the HID frame
> uses. Using `0x0e 0xXX` makes the monitor silently ignore the write. The value
> is sent as a **2-byte big-endian** uint16 and **no checksum byte** is appended
> (kelvie/gbmonctl leaves the trailing bytes zero).

| Opcode | Control | `aorus-ctl` name | Range | Notes |
| --- | --- | --- | --- | --- |
| `0xe0 0x00` | Black equalizer | `black-equalizer` | 0–20 | shadow detail lift |
| `0xe0 0x03` | Colour mode | `colour-mode` | 0–3 | 0 cool · 1 normal · 2 warm · 3 user-defined |
| `0xe0 0x04` | RGB red gain | `rgb-red` | 0–100 | only effective in colour-mode 3 |
| `0xe0 0x05` | RGB green gain | `rgb-green` | 0–100 | only effective in colour-mode 3 |
| `0xe0 0x06` | RGB blue gain | `rgb-blue` | 0–100 | only effective in colour-mode 3 |
| `0xe0 0x07` | Gamma | `gamma` | 0–5 | 0 off · 1=1.8 · 2=2.0 · 3=2.2 · 4=2.4 · 5=2.6 |
| `0xe0 0x08` | Vibrance | `vibrance` | 0–20 | colour saturation boost |
| `0xe0 0x09` | Overdrive / MPRT | `overdrive` | 0–2 | 0 quality · 1 balance · 2 speed |
| `0xe0 0x0b` | Low blue light | `low-blue-light` | 0–10 | blue-light filter |
| `0xe0 0x0c` | FreeSync | `free-sync` | 0–1 | toggles adaptive sync |
| `0xe0 0x0e` | PBP / PIP mode | `pbp-pip-mode` | 0–2 | 0 off · 1 PIP · 2 PBP |
| `0xe0 0x0f` | PBP / PIP source | `pbp-pip-source` | 0–3 | 0 HDMI1 · 1 HDMI2 · 2 DP · 3 Type-C |
| `0xe0 0x10` | PBP / PIP switch | `pbp-pip-switch` | 0–9 | use 1 |
| `0xe0 0x13` | PIP audio switch | `pip-audio-switch` | 0–9 | use 1 |
| `0xe0 0x14` | PIP size | `pip-size` | 0–2 | 0 large · 1 medium · 2 small |
| `0xe0 0x15` | PIP location | `pip-location` | 0–3 | 0 top-left · 1 top-right · 2 bottom-left · 3 bottom-right |
| `0xe0 0x2c` | Picture mode | `picture-mode` | 0–8 | 0 standard · 1 FPS · 2 RTS/RPG · 3 Movie · 4 Reader · 5 sRGB · 6–8 custom |
| `0xe0 0x2d` | Input / source | `source` | 0–3 | 0 HDMI1 · 1 HDMI2 · 2 DP · 3 Type-C |
| `0xe0 0x2e` | Audio input | `audio-input` | 0–2 | 0 main · 1 PIP/PBP · 2 auto |
| `0xe0 0x30` | OSD display time | `osd-display-time` | 0–5 | 0=5s … 5=30s |
| `0xe0 0x31` | LED indicator | `led-indicator` | 0–2 | 0 always on · 1 always off · 2 standby on |
| `0xe0 0x69` | KVM switch | `kvm-switch` | 0–1 | **0 = USB-B · 1 = Type-C** |

---

## KVM switching (the special one)

KVM is a pure vendor command, `0xe0 0x69`: value `0` routes USB to the **USB-B**
upstream, value `1` to the **Type-C** upstream. This is how a MacBook on a single
Type-C cable (video + USB + KVM) can flip which upstream devices the monitor's
USB hub serves.

> **Why both source and KVM exist:** `source` (0xe0 0x2d) selects the *video*
> input (which panel image is shown). `kvm-switch` (0xe0 0x69) selects which
> *host* owns the monitor's USB hub / keyboard / mouse. On a Type-C single-cable
> setup these can be set independently or together, depending on the panel.

---

## Conventions & caveats used to build the table

- Opcodes prefixed `0xe0` are the vendor namespace in the HID frame; the *first*
  command byte is `0xe0` and the *value* is a 2-byte big-endian field after the
  two-byte command word. (The `0x0e` prefix seen in ddcutil-style community tables
  is a different notation and must be remapped to `0xe0` for the HID frame.)
- Ranges are the community-documented ones. Some values are "use 1" placeholders
  where the panel only accepts 0/1 or a specific magic value.
- Not every opcode is present on every panel. `volume` (0x62) and `audio-input`
  (0xe0 0x2e) only matter on panels with speakers/audio routing; on a
  speakerless SKU a write is accepted but ignored (harmless).
- The **gaming extras deliberately omitted** from this project's scope (crosshair,
  game timer/counter, FPS overlay, dashboard, OLED-care assistant) have opcodes
  in the community tables but are not wired into `Protocol.swift`. They can be
  added later from the same references.

---

## Source mapping (which RE doc a row came from)

| Opcode block | Primary source |
| --- | --- |
| 0x10 / 0x12 / 0x62 / 0x87 | VESA DDC/CI (VCP) standard |
| 0x0e00–0x0e15 | ayufan-research/gigabyte-m32u-ddcctl vendor table |
| 0x0e2c–0x0e31 | ayufan-research/gigabyte-m32u-ddcctl vendor table |
| 0x0e69 (KVM) | kelvie/gbmonctl + gigabyte-kvm-switch |

New panels should be validated against the CO49DQ before trusting a row that
was only ever exercised on a different SKU.
