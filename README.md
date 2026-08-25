# Aorus

Control your **Gigabyte / AORUS monitor** from your Mac's menu bar.

Adjust brightness, contrast, volume, switch inputs, change picture modes and colours, switch KVM, and set up **PBP / PIP** — without the Windows-only OSD Sidekick. Native macOS, no drivers to install.

---

## What you need

- A **Gigabyte / AORUS monitor** — tested on the **AORUS CO49DQ**; built on the protocol shared by the wider Gigabyte family (see [which monitors work](#which-monitors-work)).
- A **Mac** on **macOS 13** or later (Apple Silicon).
- The monitor plugged into the Mac with its **USB cable** (the "upstream" port — on the CO49DQ that's USB-B or USB-C/Type-C), in addition to the video cable. That's how the app talks to the monitor.

## Download

Grab the latest **`.dmg`** from the **Releases** page:

<https://github.com/jrimmer/aorus-ctl/releases/latest>

## Install

1. **Open** the `.dmg` — a window shows **Aorus** and your **Applications** folder.
2. **Drag Aorus** onto the Applications folder.
3. **Open** Aorus. An icon appears in your **menu bar** (top-right of the screen).
4. Click the menu-bar icon to show the control panel.

> If macOS warns about an unidentified developer the first time you open it: right-click (or Control-click) the app, choose **Open**, and confirm. Signed + notarized builds open cleanly, so this should be rare.

**Signed & notarized:** every release is signed with a Developer ID certificate and **notarized by Apple**. You can run it straight from the DMG — no right-click-to-open, no security override, no extra steps needed on your Mac.

## Using it

- **Sliders** — brightness, contrast, volume, sharpness. Changes apply as you drag.
- **Picture mode** — Standard, FPS, Movie, sRGB, and more.
- **Colour** — pick a colour temperature, or fine-tune **R/G/B** when set to "user-defined".
- **Video Input / KVM** — choose which source the monitor shows, and which PC controls the USB devices.
- **PBP / PIP** — split the screen (side-by-side or picture-in-picture), pick each side's source, and **Switch** them. The **?** next to the title lists the shortcuts.
- **Keyboard shortcuts** (work anywhere): **⌘⇧P** cycle PBP/PIP · **⌘⇧X** switch PBP/PIP inputs · **⌘Q** quit Aorus.

**A note on reading values back:** Aorus can't read most settings from the monitor back into the app. If you change something with the monitor's own on-screen menu (the OSD), **the app won't know** — it may keep showing the old value until you drag its slider again. The app can still make changes, and it remembers the values you set **through the app**, restoring them the next time it opens. (Brightness, contrast, volume and sharpness can be read back over the video cable — click **Refresh**.)

## Uninstalling

Drag **Aorus** to the Trash. It doesn't install background services or login items.

---

## Which monitors work

Tested on the **AORUS CO49DQ**. It's built on the same communication protocol that a whole family of Gigabyte / AORUS monitors use, so it likely works on many of them — but not every model is guaranteed.

Read [compatibility](docs/compatibility.md) to see exactly which models are likely to work and how to check yours.

## Technical notes

For developers and anyone curious about how it works, the protocol is documented in [docs/protocol.md](docs/protocol.md), the vendor command table in [docs/ddc-vendor-commands.md](docs/ddc-vendor-commands.md), and the community work it builds on in [docs/prior-art.md](docs/prior-art.md). A `aorusctl` command-line tool is also included — see [docs/cli.md](docs/cli.md).

## Credits

The protocol was decoded by the open-source community long before this app; Aorus is a native Mac implementation that builds on [kelvie/gbmonctl](https://github.com/kelvie/gbmonctl), [ayufan's m32u-ddcctl](https://github.com/ayufan-research/gigabyte-m32u-ddcctl), and others, listed in [docs/prior-art.md](docs/prior-art.md).

## License

MIT.
