# Compatibility — which monitors work

## The short version

**Tested on:** the **AORUS CO49DQ** (49" QD-OLED) specifically. Every "confirmed" / "live" claim in this project refers to that one panel.

The tool is **built on** a protocol shared by a family of Gigabyte / AORUS monitors driven by the same **Realtek HID controller** (`VID 0x0bda` / `PID 0x1100`) — e.g. the M27Q / M32U / M32Q / M32QC / M28UC used by prior-art tools (kelvie/gbmonctl, ayufan m32u-ddcctl). So it will *likely* work on any Gigabyte / AORUS panel using that controller, but **not every model is guaranteed**.

## How to tell if yours works

There's no firmware-level guarantee, so treat compatibility as a to-be-verified claim. In order of strength:

1. **The controller is the deciding factor, not the model name.** Ask "does my monitor expose `0x0bda:0x1100`?" instead of "does it work on my monitor?". `aorusctl list` answers that in one command.
2. **Same controller ⇒ the frame format carries over** — fixed preamble, 192-byte report, `0xe0XX` vendor prefix, no checksum byte. A different controller (different VID:PID, or "no device found") means the protocol is *probably* different — do **not** trust `set` on it.
3. **Per-command variance:** even on a compatible controller, individual opcodes differ by panel. Treat the command table as a starting point and spot-check each control (`--dry-run` first) before relying on it.
4. **Different controller but curious?** The USB HID protocol is independent of the video output. One OSD Sidekick re-sniff (USBPcap + Wireshark, see [protocol.md](protocol.md)) resolves it with certainty.

**Bottom line:** expect it to work on Realtek-HID Gigabyte / AORUS panels; verify per-model and per-control. The [bring-up checklist](../README.md) is the practical way to do that on a new panel.

## The catch that makes it a "driver" problem

Gigabyte's own OSD Sidekick is Windows-only, so no Mac equivalent existed before this project. The monitor exposes a standard USB HID interface, which is why macOS needs no driver — the app talks to it directly over USB. The protocol effectively encapsulates DDC/CI, so the command opcodes are the same ones used over the HDMI / DP / Type-C video cable.
