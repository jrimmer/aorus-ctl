# Realtek HID Monitor Control Protocol — Deep Dive

Reverse-engineering notes for controlling **Gigabyte / AORUS monitors** over USB
HID. This is the technical writeup behind `aorus-ctl`. It documents the device,
the report descriptor, the exact frame that must be sent, the command table,
and the hard-won on-hardware findings (report size, the USB STALL, and the
status-report question).

Companion files:

- [`docs/ddc-vendor-commands.md`](./ddc-vendor-commands.md) — the vendor command
  table (opcodes, ranges, meanings) recovered from community RE.
- [`docs/prior-art.md`](./prior-art.md) — every known project that talks this
  protocol, with what each proved, so future work doesn't re-discover it.
- [`README.md`](../README.md) — user-facing quickstart.

---

## 1. The device

Gigabyte monitors in the AORUS family are driven by a **Realtek HID
controller** exposed over USB as a standard human-interface device.

| Property | Value | Meaning |
| --- | --- | --- |
| VID / PID | `0x0bda : 0x1100` | Realtek VendorID / ProductID — also written `3034 : 4352` |
| Manufacturer | `Realtek` | USB string descriptor |
| Product | `HID Device` | USB string descriptor |
| Primary Usage Page | `0xFFDC` | vendor-defined |
| Primary Usage | `0xDA` | vendor-defined |
| Max Input Report Size | **192** bytes | status / read-back |
| Max Output Report Size | **192** bytes | control / write |
| Max Feature Report Size | `0` | no feature report |

The controller only appears when the monitor's **USB upstream** is plugged
into the host. On the CO49DQ that is either the **USB-B** upstream port (the
OSD Sidekick cable) or the **USB-C / Type-C** upstream port (which simultaneously
carries video + USB + KVM). Because it is a plain **HID class device**, macOS
binds it to the generic hid driver with **no vendor kernel driver required** —
user-space IOKit access is sufficient. That is the entire gap OSD Sidekick
exploits and no macOS equivalent shipped for years.

### 1.1 Which nodes carry which keys

MAC note: on macOS there are **two planes** that enumerate this hardware, and
they use *different property names* — a subtle trap that broke naive matching:

- **`IOUSBHostDevice` plane**: keys `idVendor` / `idProduct` (lowercase).
- **HID device plane** (`kIOHIDDeviceKey`): keys **`VendorID` / `ProductID`**
  (capitalized), bridging as `NSNumber`.

When matching in IOKit you must read `VendorID`/`ProductID` (capitalized)
from the HID-plane dictionary. Reading `idVendor`/`idProduct` there returns
`nil` and silently matches nothing. See `HIDTransport.findMonitorDevices`.
This is how the first attempt "found nothing" (`No Realtek 0bda:1100 HID
device found.`) even though `ioreg -p IOUSB` showed the node plainly.

### 1.2 UniqueID is unreliable

`UniqueID` is often absent on these nodes. When absent, do **not** fall back to
the raw registry-entry address — that value changes every session and breaks
round-tripping a discovered device into a fresh open. Treat `UniqueID` as
optional and match on `(VendorID, ProductID)` alone when it's missing.

---

## 2. The report descriptor

Full 28-byte HID report descriptor (decoded):

```
06 da ff   Usage Page (0xFFDA)              vendor
09 da      Usage (0xDA)                     vendor
a1 01      Collection (Application)
15 80      Logical Minimum (-128)
25 7f      Logical Maximum (127)
75 08      Report Size 8 (bits)
95 c0      Report Count 192       →  192 bytes
09 d1      Usage (0xD1)
91 02      Output (Data, Absolute)   ── 192-byte OUTPUT report (commands)
75 08      Report Size 8
95 c0      Report Count 192
09 d2      Usage (0xD2)
81 02      Input (Data, Absolute)    ── 192-byte INPUT report (status)
c0         End Collection
```

Critical facts:

- **No report-ID item** (`0x85 xx`) anywhere. The device is a single fixed-size
  report on each direction.
- **Exactly two reports: one 192-byte Output (commands, usage `0xD1`) and one
  192-byte Input (status, usage `0xD2`)**.
- Usage page `0xFFDC` is vendor-defined — Windows OSD Sidekick and the open-source
  reverse-engineered tools all speak through it.

---

## 3. The frame (what to actually write)

A control command is a **192-byte output report**. Sending the frame is *write-only*:
you do **not** read anything back for a set (see §5).

Byte layout within the 192-byte payload (offsets into the report):

| Offset | Size | Value | Meaning |
| --- | --- | --- | --- |
| `0x00` | 2 | `40 c6` | fixed preamble |
| `0x06` | 5 | `20 00 6e 00 80` | fixed header |
| `0x40` | 1 | `51` | message marker |
| `0x41` | 1 | `0x81 + msgLen` | message length (see below) |
| `0x42` | 1 | `03` | write opcode |
| `0x43` | 1–2 | command bytes | `0x10` / `0x12` / `0x87`… (single) or `0x0e XX` (vendor) |
| … | 1 | value | single value byte (`0x00`–`0xff`) |
| … | 1 | checksum | nibble-wise XOR (below) |

The **message length byte** at `0x41` encodes `0x81 + (command bytes + value byte)`
for writes. Decode carefully:

```text
msgLen = lenByte - 0x81
```

e.g. brightness (single command byte + 1 value) ⇒ `0x81 + 2 = 0x83`;
a vendor command (`0x0e XX` = 2 bytes + 1 value) ⇒ `0x81 + 3 = 0x84`.

### 3.1 Checksum algorithm

Matches gbmonctl exactly:

```text
low  nibble = XOR of every message byte's low nibble, seeded with 0x6
high nibble = (last message byte XOR 0xc0) & 0xf0
checksum    = low + high
```

`msg` is the region from the first command byte (`0x43`) through the value byte
(not the checksum byte). The checksum is the byte immediately after the value.

### 3.2 Worked example — brightness 50

```text
51 83 03 10 32 f4
└──┘ └─┘ └─┘ └─┘ └─┘
marker len op cmd val cksum
```

`0x10` = DDC brightness command, `0x32` = 50, `0xf4` = checksum. This specific
frame was verified byte-for-byte against gbmonctl's known-good output.

---

## 4. ⚠️ The report-size trap (USB pipe STALL) — hard-won

**Symptom:** the very first hardware write (and read) failed with

```text
ERROR: Failed to write HID report (IOKit status -536850432)
```

`-536850432` (signed) = `0xE0005000` (unsigned) =
**`kUSBHostReturnPipeStalled`** — "Pipe has issued a STALL handshake. Use
clearStall." Every `IOHIDDeviceSetReport` / `GetReport` call returned this.

**Root cause — one byte too many.** Following the gbmonctl convention, the
initial transport wrote a **193-byte** buffer: report-ID byte `0x00` + 192-byte
payload, passing `reportSize = 193`. But this device's descriptor has **no
report-ID item** — it exposes a bare 192-byte report. A 193-byte transfer does
not match the device's report size, so the device **STALLs** the control pipe.
The extra leading report-ID byte must **not** be transmitted.

**Proof (live diagnostic, `/tmp/write_variants.swift`):**

| Variant | Buffer size | reportID | Result |
| --- | --- | --- | --- |
| A | 193 bytes | 0 | `0xE0005000` STALL |
| B | **192 bytes** | 0 | **SUCCESS** |
| C | 192 bytes | 1 | SUCCESS |
| D | 193 bytes | 1 | `0xE0005000` STALL |

The device accepts **exactly 192 bytes**, regardless of report-ID value (which
is irrelevant for a report-layout with no ID item).

**Why gbmonctl gets away with 193 bytes:** gbmonctl uses **hidapi**, whose
macOS `hid_write` partitions the buffer you pass into `[reportID][data]` and
transmits only the data portion at the correct size; the leading report-ID byte
in the 193-byte Go buffer is peeled off by the library. Calling
`IOHIDDeviceSetReport` **directly** (as `aorus-ctl` does, zero dependencies) has
no such shim — you must send the bare 192-byte payload yourself.

**Fix:** slice off the leading report-ID byte and pass `reportSize = 192`,
`reportID = 0`:

```swift
let payload = Array(report[1...])          // the 192-byte vendor payload
IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, /*reportID*/0,
                     payload, /*count*/ payload.count)
```

Verified live on the CO49DQ: `set brightness 50 / 30 / 70` all apply.

---

## 5. Reads / `get` — now working, via cable-DDC

**Short version: `get` now works.** Real current-value reads are delivered by
the **video-cable DDC** channel, not the USB HID controller (which is
write-only). The app and CLI use `DDCReader`
(`Sources/AorusCore/DDCReader.swift`) to fetch live brightness/contrast/etc.

### 5.1 Why the HID path can never read

The Realtek HID controller (0x0bda:0x1100) is **write-only over USB HID.**
The reference tool gbmonctl never implements a read either (only a TODO):

```go
// TODO: read a value if "v" not specified, I think the value is in the byte 0xa
```

We tested this exhaustively (`/tmp/read_sweep.swift`):

- Sending the DDC/CI Get VCP request over HID (opcode `0x01`)
  `51 82 01 10` **succeeds** at the USB level, every variant — but **zero async
  input reports** are ever pushed, and a synchronous `IOHIDDeviceGetReport`
  **STALLs** (`0xE0005000`) even after a successful get write.
- Conclusion: the HID input report has no read-back. Vendor features (PBP/PIP,
  KVM, picture modes) therefore have **no read over HID either**.

### 5.2 The working cable-DDC read (Apple Silicon)

On Apple Silicon the framebuffer I2C API (`IOFBGetI2CInterfaceCount` /
`IOFBCopyI2CInterfaceForBus` / `IOI2CSendRequest`) exposes **no services**
(verified live). The working path is the private `IOAVService` API:

1. Iterate the I/O Registry for a service named `DCPAVServiceProxy` whose
   `Location` is `External`, and create a `IOAVService` handle
   (`IOAVServiceCreateWithService`).
2. A Get VCP **read** request is a **single byte** — the VCP code. The `0x01`
   Get opcode is implied by the 1-byte form (`Arm64DDC.read` sends `[command]`;
   sending `[0x01, vcp]` makes the device return garbage/echo).
3. I2C write payload:
   `[0x80 | (send.count+1), send.count] + send + [checksum]`, checksum seeded
   with `addr<<1` (0x6E) for the 1-byte form.
4. Reply (11 bytes): `6e 88 02 00 <vcp> 00 00 maxHi maxLo curHi curLo ck`.
   `max = reply[6]*256+reply[7]`, `current = reply[8]*256+reply[9]`.
5. Retry until the reply checksum (seed `0x50`) validates, `reply[2]==0x02`
   and `reply[3]==0x00`. Early reads are frequently stale; the clean valid
   response usually appears within a few rounds.

### 5.3 Verified readable VCP codes on the CO49DQ

| VCP | Name | Read | Max | Notes |
|-----|------|------|-----|-------|
| 0x10 | Luminance | 75 | 100 | real brightness |
| 0x12 | Contrast | 50 | 100 | real contrast |
| 0x62 | Speaker Volume | 30 | 100 | |
| 0x87 | Sharpness | 5 | 10 | |
| 0x60 | Input Source | 16 | 3 | 16 = 0x10 Type-C |
| 0x14 | Color Preset | 2 | 11 | |
| 0xCA | OSD | 1 | 2 | |
| 0xCC | OSD Language | 2 | 13 | index |
| 0xD6 | Power Mode | 1 | 5 | 1 = on |
| 0xB6 | Display Technology | 3 | 5 | |
| 0xDF | VCP Version | 514 | – | 0x0202 = DDC/CI 2.2 |
| 0xC9 | Firmware Level | 1 | – | |
| 0xC8 | Controller ID | 9 | – | |

Reads are stable across repeated calls (verified 3×: luminance 75/75/75,
contrast 50/50/50, volume 30/30/30, sharpness 5/5/5). Unsupported via the
single-byte form: Gamma 0x72, Hue 0x90, Color Saturation 0x8A, backlight
variants, geometry sizes, LUT ops.

For the menu-bar app: it seeds sliders from these real values and treats
further writes as authoritative (no live polling between edits).

---

## 6. macOS access model

No kernel driver needed. Everything is user-space IOKit + `IOHIDDevice`:

```text
IOServiceMatching(kIOHIDDeviceKey)
  → IORegistryEntryCreateCFProperties → read VendorID/ProductID ("capitalized")
  → find 0x0bda:0x1100
  → IOHIDDeviceCreate(service)
  → IOHIDDeviceOpen(device, 0)
  → IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, payload, 192)
  → IOHIDDeviceClose(device, 0)
```

`kIOHIDReportTypeOutput` on this device maps to a USB control **SET_REPORT**
(`0x21/0x09`) into the vendor-usage interface `0xFFDC` — the same transfer
Windows OSD Sidekick issues.

### 6.1 Tooling

- `hid` / `hidapi` via Homebrew works on darwin for a quick Python or Go scratch
  (as used in prior community tests on an M27Q).
- `aorus-ctl` deliberately depends on **nothing** — only IOKit — so it builds
  with a stock `swift build`.
- For sniffing Windows OSD Sidekick on a PC: **USBPcap + Wireshark** to capture
  the SET_REPORT payloads (this is how unknowns like a different PID can be
  re-derived; see the CO49DQ contingency in the README).

---

## 7. Verification matrix (this project)

| Claim | How verified | Status |
| --- | --- | --- |
| Controller is 0x0bda:0x1100 | `ioreg -p IOUSB` + HID-plane enumeration | ✅ |
| Report is 192 bytes, no report ID | Full 28-byte descriptor decode | ✅ |
| 193 bytes ⇒ STALL; 192 bytes ⇒ OK | `write_variants.swift` live test | ✅ |
| brightness write applies on hardware | `set brightness 50/30/70` on CO49DQ | ✅ |
| Frame bytes match gbmonctl | byte-for-byte dry-run comparison | ✅ |
| Status read-back works | `DDCReader` reads real luminance/contrast/volume over cable-DDC | ✅ |

```
