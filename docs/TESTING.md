# Testing methodology: packet injection & monitor-mode stability

Short version: yes, injection stability can be tested and repeated reliably
enough to compare driver versions — but only if you lock down the
environment, run each metric multiple times, and report variance instead of
single-run numbers. This document is the recipe. It is written so that a
future formal write-up can cite the method and reproduce the numbers.

## What we are actually measuring

"Injection works" is really four separate claims:

1. **Injection success rate** — of N injected frames, how many the target
   acknowledges / the driver reports as transmitted.
2. **Monitor-mode stability** — the adapter stays up for hours of capture
   without disconnects, re-enumeration, or kernel warnings.
3. **Throughput sanity** — managed-mode performance did not regress while
   fixing monitor/injection.
4. **Channel behavior** — channel set/hop works across the regulatory
   channels you care about (regression check for the TX-power WARNING seen
   on channel 163 during Kismet channel hops).

Test all four. A driver can inject fine and still be unusable if it falls
over after 20 minutes of hopping.

## Locking down the environment (the part that makes it repeatable)

RF tests are noisy by nature. Control what you can, record the rest:

- **Same physical adapter, same USB port.** USB2 vs USB3 matters for this
  driver (`rtw_switch_usb_mode`). Record `lsusb -v` and which port/hub.
- **Same host and kernel for every run in a comparison set.** The kernel is
  the biggest confounder — see "the comparator problem" below.
- **Fixed target AP at a fixed distance.** Record the AP model, channel,
  and the RSSI seen by the test adapter at start of each run.
- **Fixed channel, fixed TX power.** `iw dev <mon> set channel <ch>` and
  `iw dev <mon> set txpower fixed <mBm>`. Record the regulatory domain
  (`iw reg get`).
- **Kill the interferers.** NetworkManager, wpa_supplicant, and any other
  managed interface on the test host must be stopped. No other radios
  transmitting near the target if you can help it.
- **Record ambient conditions** in one line per session: time, rough
  temperature is overkill, but note anything unusual (microwave ovens,
  neighbors running speed tests — you will see it in the variance).
- **Driver build provenance.** Record the exact commit (`git rev-parse HEAD`),
  kernel version, gcc version, and module parameters
  (`grep . /sys/module/88x2bu/parameters/*`).

## The metric suite

Run the suite in this order. Each test is scripted in
`tests/injection-benchmark.sh`; the commands below are what it runs.

### 1. Quick injection check (smoke test)

```
airmon-ng check kill
ip link set <wlan> down
iw dev <wlan> set type monitor
ip link set <wlan> up
aireplay-ng --test <mon>
```

Record the reported success percentage. This is coarse but it is the
industry-standard first number, so keep it for comparability.

### 2. Sustained injection benchmark (the real number)

Loop `aireplay-ng -9`-style injection: send N=1000 frames (deauth or ARP
replay against your own test AP — never anyone else's), count TX
completions and driver-reported failures per run. Repeat **5 runs**,
re-setting the channel and re-creating the monitor interface between runs.

Report: mean success rate ± standard deviation across the 5 runs. One run
proves nothing; five runs with tight variance is a claim.

### 3. Monitor-mode soak (stability)

- 12–24h capture with `airodump-ng` or Kismet on a fixed hop list.
- During the soak, snapshot `dmesg` every hour. Count: kernel WARNINGs,
  USB disconnect/re-enumeration events, and silent capture gaps (compare
  expected vs observed beacon counts from your known AP set).
- Pass criteria: zero oops/WARNINGs, zero re-enumerations, beacon drift
  under 5%.

This is the test that catches the class of bug the 7.x port fixed —
cfg80211 API misuse that only shows up under sustained use.

### 4. Throughput sanity (managed mode)

`iperf3` against a wired server, 60 seconds, 3 runs, adapter in managed
mode associated to the test AP. Catches regressions the injection tests
miss (power management, AMPDU, rate control).

### 5. Channel sweep regression

Kismet (or a scripted `iw` hop) across the full 2.4 + 5 GHz hop list for
30 minutes. Watch `dmesg` specifically for TX-power warnings — the
in-kernel rtw88 threw a WARNING on every hop past channel 163 on the
7.3 test box, which is why it got blacklisted. The port must hop the
full list clean.

### 6. Suspend/resume + USB reset recovery

Three suspend/resume cycles with the adapter plugged in, plus one
`usbreset` of the device mid-capture. The adapter must come back and
resume capture without a module reload. (Relevant on Fedora, where USB
autosuspend is aggressive — see the udev rule notes.)

## The comparator problem (read this before claiming "better")

The honest difficulty: old driver versions do not build on 7.x kernels,
so "v5.13.1-upstream vs this port on kernel 7.3" is not an available
comparison — the kernel changed too. Your options, in order of rigor:

1. **Same kernel, different driver commits.** Rebuild this port at each
   patch commit (or `git stash` individual fixes) on the same 7.x kernel
   and re-run the suite. This isolates *your* patches. Slow but clean.
2. **Same kernel, in-kernel rtw88 as reference.** Where rtw88 loads and
   binds the adapter, run the suite against it as the control. Note its
   known limitations (the channel-163 WARNING) as findings, not noise.
3. **Different kernels, same port.** Run the suite on 6.x (upstream
   driver, unpatched) and 7.x (this port). Report both; explicitly label
   the kernel as a confounder and do not claim the delta is all driver.

Never compare one run of A against one run of B on different days and
call it a result.

## Repeatability harness

`tests/injection-benchmark.sh` implements tests 1–2 and the dmesg
snapshot discipline. Results go in:

```
results/<driver-commit>/<kernel-version>/<YYYY-MM-DD-HHMM>/
  run-1.csv ... run-5.csv
  dmesg-before.log  dmesg-after.log
  env.txt            # commit, kernel, lsusb, iw reg get, module params
  summary.txt        # mean ± stdev, computed by the script
```

Commit the `summary.txt` and `env.txt` files with the release notes for a
version. Raw per-run CSVs go in the repo too — they are small and they
are the evidence.

## Structure of the future formal write-up

When this becomes a real report, it writes itself from the above:

1. Summary (the numbers, one paragraph)
2. Environment (hardware, kernel, AP, channel, TX power, reg domain)
3. Method (this document, cited)
4. Results (one table per metric: version × mean ± stdev)
5. Regression notes (channel-163 class issues, dmesg findings)
6. Raw data (link to results/)

## Honest caveats

- RF variance is real: ±2–3% on injection rate between sessions is
  environment, not driver. That is why we report stdev.
- `aireplay-ng --test` percentage depends partly on the *target's*
  behavior. Same target, same distance, every time.
- A 24h soak on your desk is not a deployment. It is still the best
  proxy available without a chamber.
