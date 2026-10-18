# PATCH-NOTES.md — rtl88x2bu Linux 7.x port

Fork of [morrownr/88x2bu-20210702](https://github.com/morrownr/88x2bu-20210702)
(Realtek v5.13.1 base + community updates), ported to Linux 7.x with
working monitor mode and packet injection. Full upstream history is
preserved below the port commits.

## Why this exists

The in-kernel `rtw88_8822bu` driver throws a `WARN_ON` in
`rtw_get_channel_group()` on every 5 GHz channel hop (e.g. Kismet
hopping to channel 163) because its TX-power table has no entry for
that channel/bandwidth combo. This out-of-tree driver is the
alternative for wardriving / monitor-mode / injection use on
kernels where the in-kernel driver misbehaves — but upstream
stopped at 6.14 (+ 6.18.4 on Debian), and its 7.1 attempts were
reverted. This fork finishes the job.

## What changed (per commit, newest last)

1. **`Fix PPPoE NAT25 build on kernel 7.1+`** (`core/rtw_br_ext.c`)
   - Kernel 7.1 hid the flex-array members `pppoe_hdr::tag` and
     `pppoe_tag::tag_data` from `__KERNEL__` builds in
     `<linux/if_pppox.h>` (verified: no guards in 7.0, guards
     present in 7.1/7.2). Direct member access no longer compiles.
   - New `PPPOE_HDR_TAGS()` / `PPPOE_TAG_DATA()` helpers use
     pointer arithmetic (`(ph + 1)` / `(tag + 1)`) on 7.1+, which
     lands on the exact bytes the flex arrays described. Older
     kernels keep the original member accesses.
   - This is AP-bridge (NAT25) code, not the monitor path, but the
     module won't build without it.

2. **`Replace strncpy() for kernel 7.2+`** (10 files)
   - Kernel 7.2 removed `strncpy()` from the kernel string API
     (verified: declared in 7.0/7.1, gone in 7.2). Each call site
     was migrated to the semantically-correct replacement —
     deliberately NOT a blanket `#define strncpy strscpy`, which
     would silently corrupt several sites:
     - `strscpy()`: NUL-terminated string copies (netdev ifnames,
       crypt alg names, phydm fw-trace chunk, PHY config tokens
       with size+1 so no character is lost).
     - `memcpy()`: exact-byte copies where the old code relied on
       zero-initialized buffers, not NUL termination
       (ParseQualifiedString token extraction, debug string
       builder `p += len` pattern, MAC hex parse, cfgvendor ring
       names — `nla_data` may not be NUL-terminated so `strscpy`
       would over-read, fw-debug-trace append queue).
   - `strscpy()`/`memcpy()` exist on every kernel this driver
     supports (5.10+), so no version guards were needed.

3. **`Add rx_addr param to remain_on_channel for kernel 7.2+`**
   (`os_dep/linux/ioctl_cfg80211.c`)
   - 7.2 extended `cfg80211_ops::remain_on_channel` with
     `const u8 *rx_addr` (verified absent in 7.0/7.1). Accepted
     and ignored — this driver doesn't filter by rx address.

4. **`Drop WIPHY_FLAG_SUPPORTS_5_10_MHZ on kernel 7.2+`**
   (`os_dep/linux/ioctl_cfg80211.c`)
   - Flag removed in 7.2 (verified present in 7.0/7.1) with no
     replacement API. Still advertised on older kernels; on 7.2+
     the 5/10 MHz monitor-debug capability is simply not
     advertised.

5. **`Add .gitignore`** — kernel module build artifacts.

6. **README.md** — "Compatible Kernels" now lists 7.0–7.2; "Tested
   Compilers" notes the gcc 13.3 / 7.2 compile test.

Already in upstream history and kept: the 7.0 cfg80211
`net_device` → `wireless_dev` op conversion (commit 2f32248),
including `rtw_wdev` allocation, `cfg80211_new_sta`/`del_sta`
call sites, and the 6.17 link_id/radio_idx guards.

## Monitor mode + injection — verified intact

None of the port commits touch these paths; all were reviewed
against the 7.2 `cfg80211_ops` signatures:

- `NL80211_IFTYPE_MONITOR` advertised via `wiphy->interface_modes`
  (`CONFIG_WIFI_MONITOR=y`, the default).
- `cfg80211_rtw_change_iface` handles monitor transitions
  (signature unchanged in 7.2 — still takes `struct net_device *`).
- `cfg80211_rtw_set_monitor_channel` — the Kismet channel-hop
  path — signature matches 7.2, implementation untouched.
- `cfg80211_rtw_mgmt_tx` — the packet-injection path —
  implementation untouched.

## Supported kernels

- 5.10–5.11 (Realtek base), 5.12–6.14 (upstream community),
  6.18.4+ (upstream, Debian + gcc 15.2), **7.0–7.2 (this fork)**.
- 6.15–6.18.3 remain unsupported (upstream gap, unchanged).

## Build instructions

On the target machine (Ubuntu 26.10, kernel 7.3.0-9-generic):

```sh
sudo apt install dkms git build-essential linux-headers-$(uname -r)
git clone <your-repo-url> rtl88x2bu-7x
cd rtl88x2bu-7x
sudo ./install-driver.sh
```

Or manual/DKMS:

```sh
sudo ./dkms-make.sh        # DKMS build helper used by install-driver.sh
sudo sh remove-driver.sh   # clean removal
```

`edit-options.sh` exposes the driver's compile-time options
(monitor mode, AP mode, power saving, etc.) before installing.

If Secure Boot is enabled, the module must be signed or Secure
Boot disabled — see `FAQ.md`.

## Tested vs. untested — read this

- **Compile-tested: YES, against mainline Linux 7.2** (kernel.org
  7.2 tarball, x86-64 defconfig, gcc 13.3). All 175 objects build
  with zero errors. Module link (modpost) was validated modulo
  10 standard kernel-internal symbols (`__x86_indirect_thunk_*`,
  `__rcu_read_lock/unlock`, etc.) that only exist in a fully
  built kernel tree — the test tree was headers-only, so those
  are environment artifacts, not driver bugs. Every undefined
  symbol was verified present in the 7.2 source.
- **NOT tested:** 7.3 (not released on kernel.org at port time;
  the 7.2→7.3 cfg80211 delta is expected to be small, but it is
  unverified — build against John's `linux-headers-7.3.0-9-generic`
  and report back), 7.0/7.1 (code paths are version-guarded and
  match upstream's merged 7.x work, but no test build was done),
  6.x and older (guards preserved, not rebuilt here).
- **NOT tested:** loading the module, monitor mode, or injection
  on real hardware. No RTL8812BU/8822BU adapter was available in
  the build environment. First load should be done with
  `dmesg -w` running; if the 7.3 headers expose any API drift,
  the failure will be a compile error, not silent breakage.

## Version-guard boundaries used (all verified against kernel source)

| Change | Guard | Verified |
|---|---|---|
| PPPoE flex-array hiding | `>= 7.1` | 7.0: no guards; 7.1/7.2: guarded |
| `strncpy()` removal | none needed | declared 7.0/7.1, gone 7.2; replacements exist since 4.x |
| `remain_on_channel` `rx_addr` | `>= 7.2` | absent 7.0/7.1, present 7.2 |
| `WIPHY_FLAG_SUPPORTS_5_10_MHZ` | `< 7.2` | present 7.0/7.1, gone 7.2 |

## License

Unchanged — Realtek/GPLv2 attributions kept in every file.
See `LICENSE`.
