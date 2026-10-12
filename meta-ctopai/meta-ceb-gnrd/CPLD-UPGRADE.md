# CEB-GNRD CPLD Web upgrade

## Supported hardware and format

- AST2600 dedicated JTAG Master-1, register base `0x1e6e4000`; reset 22.
  This is not the GPIOI / JTAG Master-2 group.
- Anlogic EF3L90CG400B, IDCODE `0x00008C3B`, internal 8 Mbit SPI Flash.
- Upload the TD `.bit` format used by the supplied `INS_ZQ6_CPLD_V3.bit`.
  Maximum upload: 1 MiB; decoded Primary Flash data: 384 KiB to preserve the
  reserved Golden region. No arbitrary SVF execution.
- The ASCII header must identify `ef3_9` / `EF3L90CG400B`. The complete
  Feature code is 18 bytes (36 hex characters). The reviewed TD SPI SVF writes
  its first 16 bytes followed by the decoded length-prefixed configuration
  blocks. The final two Feature code bytes are not added to Flash data.

The programming protocol was compared with these supplied TD 1.5 exports:

| Export | SHA256 |
| --- | --- |
| Background SPI + Verify, no Refresh | `495be9e6fe834049bdf7be25a542071fcc165e4654d7d30c123186a717adc22f` |
| Independent Refresh | `cf303350980139dc36f03c8a63f7fca64217a54f36134a688ae615bd8b75ad89` |

For the supplied V3 bitstream, 75 sector erase vectors and 1199 program /
readback page vectors match the background SVF. This is an offline comparison,
not evidence of electrical operation on the board.

## Required approval before enabling programming

As of 2026-10-12, the board owner confirmed `persist_bit=1` for the supplied
INS_ZQ6_CPLD_V3 design. The shipped configuration records this confirmation and
approves its complete Feature code. Apply this confirmation only to boards
running that confirmed design; other designs require their own confirmation.
The datasheet / SVF export does not establish that the design currently running
on the board has `persist_bit=1`. No documented EF3L90 feature-register bit
mapping is available to this implementation. It does not infer that bit from
IDCODE and does not attempt an erase to test whether background programming works.

Obtain confirmation from the CPLD project owner / Anlogic that:

1. The design **currently running** on the target board enables `persist_bit=1`.
2. Background internal SPI programming via JTAG instruction `0x39`, using the
   supplied TD sequence and unchanged chain, is supported by that design.
3. The target design's full Feature code and persistent configuration are
   approved; the next design must retain the required JTAG accessibility.
4. Refresh instruction `0x01` reloads that board's CPLD and resets the BMC as
   expected. Keep an external programmer available for first-board validation.

For an unconfirmed board/design, keep programming blocked as in this template:

```json
{
  "running_persist_bit_confirmed": false,
  "confirmation_reference": "",
  "approved_feature_codes": ["FFDD66BB22FFFFFFA2FFFFFFFFFFFFFF9368"]
}
```

Replace `confirmation_reference` with a real project revision / confirmation
reference and set the flag true only after confirmation. Feature codes must be
complete 36-character hexadecimal strings in a JSON list. Changing an upload's
Feature code requires a new explicit approval. This configuration is not proof
provided by the JTAG preflight; it is a deployment prerequisite.

## Upgrade behavior

The Firmware page exposes a separate CPLD upload section for administrators.
The service validates the image and prerequisites before opening JTAG.

1. Acquire the BIOS lock and exclusive CPLD update lock.
2. Wait for the user to shut down the host; require three consecutive Off
   samples. The service does not power off the host automatically.
3. Reject an active BMC image activation. Recheck Host Off before opening JTAG.
4. Check exact JTAG IDCODE, enter background SPI mode, then read the existing
   Flash header using the supplied SVF read protocol. An unrecognized / blank
   header blocks erase. Blank devices require an external initial programmer.
5. Enable QE using the supplied sequence; erase the needed 4 KiB sectors,
   program 256-byte pages, and verify every page through TDO. Readback uses the
   supplier's one-bit delay and full 2048-bit data comparison.
6. Recheck Host Off, persist the verified receipt, then issue the configured
   JTAG Refresh sequence. Vendor mode also repeats IDCODE before Refresh.
   No GPIO reset is used.
7. Wait for BMC recovery. Only a verified receipt, a different BMC boot ID, and
   recovery within the original deadline are reported as completed.

The **total timeout is 600 seconds**, including waiting for shutdown, programming,
verification and recovery. Worker and browser timers preserve the remaining
budget rather than restarting it. Cross-boot receipt expiry uses the BMC clock;
clock rollback / late recovery does not declare completion.

During programming the worker checks Host Off at least every 0.5 seconds between
bounded clock batches. A Host On transition, D-Bus error, timeout or TDO mismatch
stops programming and blocks automatic Refresh. This cannot undo sectors already
erased. Do not power on the host or remove board power during the update.
Cancellation is available only while waiting for shutdown.

After Refresh, loss of BMC services is expected and is not treated as a Host-state
failure. The browser retains its job across navigation / reconnects. If the Web
session expires during reboot, log in again to inspect the retained job.

Completion means **Flash readback verified and a new BMC boot observed**. It does
not read a CPLD running-version register or prove all CPLD functions. An unrelated
BMC reset after the receipt was armed cannot be distinguished from CPLD-triggered
reset using boot ID alone. Confirm CPLD function / version during board validation.

### Refresh and power recovery observed on 2026-10-12

The board lost power/serial access during an update with AC still connected and
recovered only after the operator cycled AC. Its receipt confirmed full Flash
verification and a new BMC boot; this does not confirm automatic power recovery.

The DS600_1.8 datasheet specifies that EF3L90 does not support StateHold IO
(section 2.9.16, printed page 70). Reconfiguration changes user IO to weak
pull-ups or high impedance (sections 2.9.13-14, pages 67-68). Review CPLD/BMC
power enables, reset feedback, PROGRAMN, INITN/DONE, VCCAUX and VCCIO0 during
reload. MSPI loads from internal Flash using its internal oscillator (section
2.9.3, page 58); loss of external TCK alone is not proof that loading stopped.

The supplied Refresh script still has clocks and cleanup after instruction
0x01. The worker records `refreshSequenceCompleted=false` before that instruction
and true only after all remaining commands return. A missing/false flag means
sequence completion was not recorded; it is not a FPGA DONE or version check.
The Web page reports disconnected progress as the last received state and
distinguishes it from the expected reconnect after Refresh. Hardware signal
captures are needed before declaring this board's automatic recovery reliable.

### Temporary serial diagnostics

The service temporarily enables `CEB_GNRD_CPLD_CONSOLE_DEBUG=1`. The worker
prints timestamped `CPLD-TRACE` BEGIN/END markers directly to its inherited
stderr (the service journal) and `/dev/console`, independently of Web polling.
Each erase sector, write/readback batches of 16 pages, the last 16 pages,
every post-verification / Refresh command and receipt write are reported.
The console copy is nonblocking and best effort; missing/full consoles do not
abort programming. No per-step diagnostic files are written to rwfs.

Capture the serial terminal transcript before starting an update. In particular,
`ALL FLASH PAGES VERIFIED` confirms readback; `BEGIN Refresh SIR 01` marks
the attempt to issue reload; its END marks return from that scan, not DONE.
A missing END identifies the last observed operation but cannot distinguish
an interrupted operation from loss of the serial path or buffered output.
While console diagnostics are enabled, the worker also adds a one-second
observation window before post-verify status SDR 32 (vendor mode), the final
Host Off check, the pre-Refresh receipt write and IR 01. `DEBUG PAUSE` means
the named operation has not started; `DEBUG PAUSE END` precedes its call.
This gives the UART time to transmit queued markers but does not guarantee
drain. These pauses consume the original 600-second budget; an insufficient
budget or expired deadline blocks the next operation. No pause is added when
diagnostics are disabled. JTAG instruction order and clock counts are unchanged.
The board routes its serial connection through CPLD logic; a blank terminal
alone does not prove BMC power loss. Use `journalctl -fu
ceb-gnrd-cpld-update.service -o short-monotonic` for a separate live view.

There is no software latch for CPLD outputs controlling BMC power/reset.
`persist_bit=1` permits background programming; it does not provide IO hold
during Refresh. DS600 states EF3L90 does not support its StateHold IO feature;
this does not establish the availability of a separate JTAG-assisted hold
procedure. The official catalog lists APUG065_Anlogic StateHoldIO_JTAG and
its reference package, but this implementation has not obtained/validated
that procedure for EF3L90. No undocumented IO-hold instruction is emitted.
The earlier logging change
does not alter JTAG instructions, clock counts, power enables or reset outputs.

To disable the temporary console copy and detailed markers after validation,
set `Environment=CEB_GNRD_CPLD_CONSOLE_DEBUG=0` in a service drop-in and
restart the service while no upgrade is active. Normal phase logs remain.

## Concurrency and storage

- Redfish Web BMC/BIOS upload paths acquire a shared CPLD lock; the CPLD service
  acquires it exclusively. The BIOS programming script checks the same lock.
- The service also checks BMC activation via D-Bus before programming. Direct
  manual Flash writes, other external JTAG masters and direct D-Bus activation
  are not serialized by Web upload locks; do not use them during a CPLD job.
- Uploads occupy one bounded file in `/run/ceb-gnrd-cpld-update`, not rwfs.
- Persistent state is one last-job JSON receipt, maximum 8 KiB, plus at most
  one 8 KiB temporary file during atomic replacement. Progress updates are not
  written per page. A failed receipt write prevents Refresh.
- The root-only `/dev/ceb-cpld-jtag` accepts bounded clock batches, a maximum
  1 MHz clock and no user-selected MMIO addresses. It is exclusive-open.
  Probe does not drive JTAG signals. Open enables output; close disables output
  without sending a CPLD reset instruction.

## Integration and review limits

The board recipe adds the built-in driver, service, D-Bus policy and Web patch.
Existing BMC boot / SPI Flash paths are not changed by the JTAG driver.

Offline vector comparisons, Python / JSON / XML syntax review and patch
applicability can be performed without a board. A complete Yocto build, board
IDCODE/TDO validation, persist-bit confirmation, and controlled programming /
Refresh validation are still needed before deploying enabled programming.
The Golden v1 tag remains the earlier baseline.

## Experimental direct Refresh (2026-10-12)

At the board owner's request, `"refresh_mode": "direct"` was initially
selected for a diagnostic trial;
the latest template selects `openfpgaloader` as described below. Direct is not the complete
vendor Refresh SVF and has not been validated on the board. Configurations
without this key keep the original `vendor` sequence; other values are rejected
before programming. Select `vendor` to restore the complete supplied sequence.

Both modes require the initial exact IDCODE, approved persist-bit design,
Host Off, all-page readback comparison and a saved receipt before IR 01.
Direct mode goes from the last verified SPI read in TAP IDLE to the final
Host Off check and receipt, then emits only `SIR 01` and `RUNTEST 15 TCK`.
It skips the post-verify read_status, mode-exit register writes, repeated
IDCODE sequence, post-Refresh BYPASS, 200000 clocks and register cleanup.
It does not assert that those skipped vendor operations are unnecessary.
The total deadline stays 600 seconds; returning from these commands is not
success. The service still waits for BMC recovery and does not reboot BMC itself.

The receipt records `refreshMode`; `refreshSequenceCompleted` means the
selected sequence returned, not that the full vendor SVF ran or CPLD DONE rose.
Keep the serial terminal transcript outside BMC when trying direct mode.
Existing `/etc` overlay configuration can override the new shipped JSON;
check `/etc/ceb-gnrd/cpld-update.json` before starting the trial.

## openFPGALoader compatibility mode (2026-10-12)

The board owner authorized the assumption that EF3 and EF2 are compatible
for this trial. The new shipped configuration selects
`"refresh_mode": "openfpgaloader"`. Existing configurations are not silently
migrated: missing mode remains `vendor`, and an explicit `direct` keeps that
diagnostic path. The service records the selected mode at Start and passes it
to the worker so editing configuration during shutdown wait cannot switch
the job's algorithm. Persist-bit/image approval is checked again by the worker.

The reference is openFPGALoader commit
`bf2b52916e7b6216ba1cc0b30933827d7735b05d`:

- [Anlogic::reset / SPI wrapper](https://github.com/trabucayre/openFPGALoader/blob/bf2b52916e7b6216ba1cc0b30933827d7735b05d/src/anlogic.cpp)
- [SPI write-enable / completion checks](https://github.com/trabucayre/openFPGALoader/blob/bf2b52916e7b6216ba1cc0b30933827d7735b05d/src/spiFlash.cpp)
- [JTAG state and default idle clock values](https://github.com/trabucayre/openFPGALoader/blob/bf2b52916e7b6216ba1cc0b30933827d7735b05d/src/jtag.hpp)

Implementation differences and retained guarantees:

1. Keep the supplier-verified EF3 background entry and A5 SPI tunnel, image
   parser, erase/program address vectors and full readback comparison. Upstream
   normal flash access starts with Refresh and uses a different SPI wrapper;
   those parts are not copied onto a board where reload affects BMC supply.
2. Assuming SPI status compatibility, use opcode `05` for WIP bit 0 and WEL
   bit 1. Probe idle before QE/erase, require idle+WEL after every WREN, and
   poll WIP after QE, each erase and page write rather than fixed clock waits.
   WEL wait is bounded to 1 second, QE/program to 2 seconds, sector erase to
   10 seconds; all are clipped by the original total deadline. An all-FF status,
   missing WEL, busy timeout, Host On or readback mismatch blocks Refresh.
   This is SPI Flash RDSR under IR 39, not CPLD JTAG read_status IR 20.
3. After verified receipt + final Host Off checks, emit the upstream reset
   sequence: `SIR FF -> SIR 01 -> 15 TCK -> SIR FF -> 200000 TCK`.
   It skips IR 20 and the undocumented EF3 control-register cleanup/re-entry.
4. The three IR scans and 15 clocks plus the first 4039 idle clocks are sent
   in one 4096-clock ioctl. This removes user-space/logging gaps across the
   short reset sequence without changing TAP IDLE transitions or clock counts.
   Remaining 195961 idle clocks use bounded batches. No new kernel ABI is used;
   actual BMC power loss can still interrupt any batch.
5. Recheck Host Off after the pre-Refresh diagnostic pause, immediately before
   disruptive clocks. Pre-Refresh receipt still precedes every IR 01, the total
   timeout remains 600 seconds, and no BMC software reboot is issued.

This mode does not lock IO, verify DONE/running version, enable Golden fallback
or prove EF3/EF2 compatibility. Its receipt records the compatibility assumption.
Board validation must establish SPI status validity, JTAG waveform and CPLD/BMC
power/reset recovery; a successful offline test is not proof of those properties.

## SVF reference audit and scan batching (2026-10-12)

The offline tool `tools/audit-cpld-svf.py` compares TD exports against the
reviewed single-device EF3L90 profile. It uses the worker's bit parser and SPI
vector constructors, checks command order, erase/write/read addresses, all
TDO data/MASK values, IDCODE, ENDIR/ENDDR IDLE, zero chain headers/trailers,
1 MHz and RUNTEST counts. It also checks the independent vendor Refresh
export, including its preparation and cleanup. Consecutive IDLE RUNTEST
counts are summed (TD emits two 50000-clock waits for QE).

Run this on the development/compile host with Python 3, using matching exports:

```sh
python3 meta-ctopai/meta-ceb-gnrd/tools/audit-cpld-svf.py \
  --bit INS_ZQ6_CPLD_V3.bit \
  --program-svf INS_ZQ6_CPLD_V3_bg_verify_norefresh.svf \
  --refresh-svf INS_ZQ6_CPLD_V3_refresh.svf
python3 meta-ctopai/meta-ceb-gnrd/tools/tests/test_cpld_svf_audit.py
```

The audit never opens JTAG, invokes busctl or runs SVF. Unknown syntax,
nonzero chain headers, partial/sticky scan fields and changed profiles are
rejected. A FAIL calls for review of the new export; it does not authorize
guessing vendor instructions. The supported profile is not a full SVF parser.
It does not change the Web upload format or approve a new feature code.
Runtime status polling and selected Refresh modes deliberately differ from
the complete vendor export as documented above.

The worker now sends scan entry, data and UPDATE/IDLE in one ioctl when the
complete scan fits 4096 clocks. An 8-bit IR needs 14 clocks; the 2089-bit
readback needs 2094. This avoids user-space Host checks between SHIFT and
UPDATE for the current profile, retains the same TMS/TDI waveform and samples
TDO only for data clocks. The generic 4096-data-bit boundary still uses two
bounded batches. RUNTEST emits actual IDLE clocks; it is not replaced by a
wall-clock sleep. Host checks and the original deadline precede each batch.
This adopts the explicit scan/state handling principle from
[openFPGALoader JTAG](https://github.com/trabucayre/openFPGALoader/blob/bf2b52916e7b6216ba1cc0b30933827d7735b05d/src/jtag.cpp)
with the board's existing AST2600 ABI.

An SVF interpreter or an additional model/IDCODE entry alone cannot guarantee
that CPLD reload restores BMC power. No new IO-hold or GPIO operation is
introduced here; that still requires the EF3 vendor procedure and board validation.

## Dual Boot and reserved Golden region

DS600_1.8 section 2.9.11 (printed pages 65-66) specifies an 8 Mbit internal
SPI Flash and MSPI Dual Boot support. For EF3L90CG400, Primary feature data
starts at `0x000000`, Golden feature/address data at `0x060000`, and Golden
bitstream at `0x061000`. This is a layout within Flash, not proof of two
independent Flash devices or of a populated, enabled backup on this board.
The datasheet describes fallback when Primary configuration loading fails;
it does not establish fallback for a successfully loaded design whose logic
fails to restore BMC power or reset outputs.

The updater rejects decoded Primary data larger than 384 KiB (`0x060000`),
before opening JTAG, so all erase/program addresses stay below Golden data.
For the supplied V3, 1199 pages occupy `0x000000..0x04AEFF`; 75 erase sectors
cover `0x000000..0x04AFFF`. Neither reaches `0x060000`. No Golden image is
created, validated or enabled by this updater; automatic recovery is unconfirmed.
The supplier background/Refresh SVFs also contain a command commented
"Disable Dual boot loop". Its register bit map is unavailable; this command
must not be treated as evidence that fallback remains enabled during a trial.

## Network boot and CPLD recovery

`run bootnet` loads the TFTP kernel and rootfs with a fresh RAM write overlay.
This is a temporary firmware run: configuration changes and CPLD receipts in
that overlay are lost at reboot. Default reboot still uses Flash (`bootspi`).
For end-to-end CPLD Refresh / BMC reboot validation, first install this firmware
into Flash so the update service and its persistent receipt survive the reset.

`/var/lib/ceb-gnrd-cpld-update/result.json` is one bounded file in the root
overlay, not in CPLD Flash. Normal Flash boot places it in the rwfs upper layer
(typically `/run/initramfs/rw/cow/var/lib/ceb-gnrd-cpld-update/result.json`).
TFTP boot places it in the RAM upper layer; it disappears on reboot/power loss,
even though programming the CPLD's internal Flash remains nonvolatile.
