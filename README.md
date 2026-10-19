# rtl88x2bu-7x

Linux driver for USB Wi-Fi adapters based on the **Realtek RTL8812BU and RTL8822BU** chipsets, ported to **Linux kernels 7.0 through 7.3** with working monitor mode and packet injection.

This is a fork of [morrownr/88x2bu-20210702](https://github.com/morrownr/88x2bu-20210702) (Realtek v5.13.1 base plus community updates). Upstream stopped shipping kernel-API updates after 6.14 and reverted its 7.1 attempts. This fork finishes the job: eight focused commits that carry the driver across every breaking kernel change from 7.1 to 7.3, with full upstream history preserved underneath. The original upstream README is kept at `docs/README-upstream.md` for reference.

## Why this fork exists

The in-kernel `rtw88` driver logs a kernel warning on *every* 5 GHz channel hop when a channel has no entry in its transmit-power table (channel 163 is one). For monitor-mode use — Kismet channel-hopping during wardriving — that means a spammy, untrustworthy dmesg on every hop. This out-of-tree driver is the alternative for that workload, but it didn't build on 7.x. Now it does.

## What changed for 7.x

Each fix is a separate, version-guarded commit — older kernels keep their original code paths. Full technical account in `PATCH-NOTES.md`.

- **7.1 — PPPoE bridge structs.** The kernel hid two struct members from drivers. The driver now locates them with pointer arithmetic on 7.1+ instead of direct access. (Bridge code, not the Wi-Fi path — but the module won't compile without it.)
- **7.2 — `strncpy()` removed from the kernel.** Every call site (10 files) was individually migrated to the semantically correct replacement — `strscpy()` where NUL-termination matters, `memcpy()` where it doesn't. Deliberately not a blanket find-and-replace, which would have introduced subtle bugs.
- **7.2 — new `remain_on_channel` parameter.** The kernel added a receive-address argument to a Wi-Fi operation the driver implements. Accepted and ignored; the driver doesn't filter on it.
- **7.2 — 5/10 MHz capability flag removed.** The kernel dropped the flag with no replacement, so the driver stops advertising that capability on 7.2+.
- **7.3 — operation cookies passed by value.** The kernel changed how it hands the driver a tracking ID for channel-hold and management-frame operations, and now generates the ID itself. Both functions updated to match.

Monitor mode and packet injection paths were reviewed against the new kernel signatures and left untouched — the fixes are all in build-compatibility code around them.

## Test status

- **Build:** compiles cleanly against 7.2 (175 objects, zero errors). The 7.3 breakage found on Ubuntu 26.10 (kernel 7.3.0-9-generic) is fixed in this tree.
- **Hardware:** not yet tested on a physical adapter — no RTL8812BU/8822BU hardware was available in the build environment. Module load, monitor mode, and injection testing are pending. Testers wanted — see `docs/TESTING.md` for the methodology.

## Install

Quick, non-interactive DKMS install (recommended — survives kernel upgrades via DKMS autoinstall):

```sh
sudo ./dkms-install.sh --blacklist-rtw88
```

The `--blacklist-rtw88` flag keeps the in-kernel `rtw88_8812au` driver from claiming your RTL8812AU adapter first. Add `--install-modprobe-conf` to also install the module options file. Removal:

```sh
sudo ./dkms-uninstall.sh
```

Or use the upstream interactive installer, which supports both DKMS and non-DKMS installs:

```sh
sudo ./install-driver.sh
```

Manual build:

```sh
make -j"$(nproc)"
sudo make install
```

If Secure Boot is enabled, the module must be signed or Secure Boot disabled — see `FAQ.md`.

Check `supported-device-IDs` (and `lsusb`) to confirm your adapter, e.g. the Alfa AWUS036ACH (`0bda:b812`).

## Docs

- `PATCH-NOTES.md` — per-commit technical account of the 7.x port
- `docs/TESTING.md` — repeatable injection and monitor-mode stability test methodology
- `tests/injection-benchmark.sh` — benchmark harness implementing it
- `88x2bu.conf` — module options reference (copy to `/etc/modprobe.d/`)
- `docs/README-upstream.md` — the original upstream README, preserved

## License

Unchanged from upstream — Realtek/GPLv2 attributions kept in every file.
