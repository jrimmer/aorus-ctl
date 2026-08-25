# Prior Art — everyone who has decoded this protocol

**Thank you** to the community reverse engineers whose public work made this
project possible — especially **kelvie** ([gbmonctl], the OSD Sidekick reversing
gist), **ayufan** ([gigabyte-m32u-ddcctl], the command table), and everyone who
ported the protocol to other languages or platforms. `aorus-ctl` is a native
macOS re-implementation of the protocol *they* decoded; none of it would exist
without them.

This project does not reinvent the wheel. Everything here builds on years of
community reverse engineering of Gigabyte's Realtek-HID monitor control. This
file catalogs the known projects, what each one **proved**, and how to use it.

Order matters: read `gbmonctl` + the reversing gist first, then the M32U table.
The rest are corroboration / alternative-language ports.

> **Scope / compatibility.** The projects below were tested across a spread of
> Gigabyte panels (M27Q / M32U / M32Q / M32QC / M28UC); the CO49DQ findings in
> §6 are this project's, verified on that one panel. The **controller**
> (`0x0bda:0x1100`) is what makes the *transport* portable; **opcodes and ranges
> vary per model**, so treat any row sourced only from another SKU as
> unverified on your panel until you spot-check it. See [README model
> compatibility](compatibility.md).

---

## 1. kelvie/gbmonctl — the primary reference (Go)

<https://github.com/kelvie/gbmonctl>

A Go CLI using `sstallion/go-hid` (a hidapi wrapper). This is the closest thing
to a canonical implementation:

- Opens `hid.OpenFirst(0x0bda, 0x1100)`.
- Builds a **193-byte** buffer (`buf[0] = 0` report id, 192-byte payload).
- **Writes only** — it never reads a value back (see TODOs about a future `get`).
- Tested on M32U / M32Q / M32QC / M28UC / M27Q.
- Its checksum function exists but is effectively unused because the monitor
  accepts frames without one (the project still fills it in to match Sidekick).

**Steal**: the frame layout, the checksum algorithm, the exact opcodes.
**Gotcha**: its 193-byte write works only through hidapi, which strips the
report-id byte. Direct IOKit callers must send the bare 192-byte payload —
see [`docs/protocol.md`](./protocol.md#4--the-report-size-trap-usb-pipe-stall).

### kelvie's OSD Sidekick reversing gist

<https://gist.github.com/kelvie/fa562c4643c4abc8d91bb192b325995b>

The original disassembly/pcap notes that established the `0x40 0xc6 ... 0x51`
frame shape and DDC/CI encapsulation. The seed for gbmonctl and everything after.

---

## 2. ayufan-research/gigabyte-m32u-ddcctl — the command table (C)

<https://github.com/ayufan-research/gigabyte-m32u-ddcctl>

A C tool + the **most complete vendor command table**. Also notable for its
platform patches:

- **`m1ddc` patch detection** — includes a patch for M1 Macs (a timing/IO fix
  community-observed on Apple Silicon).
- **`ddcctl` for Intel** Macs.

**Steal**: the `0x0e XX` vendor opcode table (brightness/contrast/volume,
black equalizer, colour temperature, per-channel RGB, gamma, vibrance,
overdrive, low blue light, FreeSync, super resolution, PBP/PIP, source, picture
modes, OSD settings, crosshair, game timer/counter, KVM 0x69–0x6c).

---

## 3. Community projects — corroboration & ports

| Project | Lang | Focus | Value to us |
| --- | --- | --- | --- |
| [wkhughes/gigabyte-kvm-switch](https://github.com/wkhughes/gigabyte-kvm-switch) | — | KVM switching | Confirms the KVM opcodes; useful for the KVM feature |
| [MarekPrzydanek/GigabyteMonitorController](https://github.com/MarekPrzydanek/GigabyteMonitorController) | .NET | KVM API / monitor control | KVM + control in managed code |
| [thilobillerbeck/gbmoncli](https://github.com/thilobillerbeck/gbmoncli) | Rust | CLI | Second-language confirmation of the frame |
| [WildFireFlum/gbmonitor](https://github.com/WildFireFlum/gbmonitor) | Python | Monitor control | Fast prototyping / PyUSB on M27Q |
| [SIMULATAN/aoruscontrol](https://github.com/SIMULATAN/aoruscontrol) | — | Linux (AUR) | Linux-side control; confirms USB HID path is OS-independent |
| [liquidctl issue #388](https://github.com/liquidctl/liquidctl/issues/388) | — | Feature request / research | Collective debugging thread about GB HID control |

---

## 4. What our project uniquely contributes

Even the reference projects leave two things open, and `aorus-ctl` documents
them for the first time:

1. **The report descriptor decode.** Nobody had published the full 28-byte HID
   descriptor (`UsagePage 0xFFDC`, two bare 192-byte reports, no report id).
   It's definitive proof of both the frame size and why a 193-byte transfer
   STALLs. → [`docs/protocol.md#2`](./protocol.md#2-the-report-descriptor)
2. **Direct-IOKit (zero-dependency) hardware access.** Most projects lean on
   hidapi and inherit its report-id shim. This project talks `IOHIDDevice`
   directly and therefore had to (and did) solve the bare-192-byte-write
   problem — which also bites any future native macOS/Swift implementation.

---

## 5. Tooling to continue the reversing

If you need to capture OSD Sidekick live (e.g. to confirm a different PID):

- **Windows**: USBPcap → Wireshark, capture the USB control **SET_REPORT**
  (0x21 0x09) into the vendor-usage interface.
- **macOS**: `ioreg -p IOUSB` / `ioreg -p IOUSBHostDevice` to enumerate;
  `swift` scratch scripts with IOKit for report-descriptor dumps (see
  `/tmp/report_diag.swift`, `/tmp/full_desc.swift`, `/tmp/write_variants.swift`
  used during development).
- **Python**: `hid` / `usb.core` (PyUSB) for quick one-off experiments against
  the live panel.

---

## 6. CO49DQ-specific findings (this project, on real hardware)

The CO49DQ controller is unlisted in every public tested-array. On-hand
findings that distinguish it:

- VID/PID confirmed `0x0bda:0x1100`, Product `HID Device`, Manufacturer
  `Realtek` (HID plane).
- 28-byte descriptor: one 192-byte Output + one 192-byte Input, no report id.
- 193-byte write ⇒ `kUSBHostReturnPipeStalled`; 192-byte write ⇒ OK.
- `set brightness 30/50/70` verified live. The write path is **confirmed on
  this specific panel**.
