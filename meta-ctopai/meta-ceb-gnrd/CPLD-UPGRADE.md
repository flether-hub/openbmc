# CEB-GNRD CPLD Web upgrade through SVF playback

## Current implementation (2026-10-12)

The Web CPLD form accepts a combined Anlogic `.svf` export, maximum **4 MiB**.
It waits for Host Off, then plays the uploaded file's SIR/SDR/RUNTEST commands
through `/dev/ceb-cpld-jtag`, the existing AST2600 dedicated JTAG Master-1
transport. There is no JTAG-selection GPIO operation.

The native `.bit` programming path and `vendor`/`direct`/`openfpgaloader`
Refresh modes have been retired. An existing `refresh_mode` key in `/etc`
configuration is ignored; Refresh order comes from the validated SVF.
`cpld_jtag.py` provides transport, Host checks, receipts and serial diagnostics.
Its pure bit parser/vector helpers are retained only for development-host audits;
it has no direct bitstream programming entry point.

## Reviewed input

Use TD 1.5 Device Chain export options: SVF for SPI, bg_mode, rf_mode, Verify,
Add Comments, 1 MHz, address 0, and the reviewed zero chain headers/trailers.
Both reviewed Length mode selections, `normal` and `short`, are accepted.
The normal reference is `INS_ZQ6_CPLD_V3_bg_verify_refresh.svf`, exported
2026-10-12 14:37, SHA256:

```text
137b2fd90b24821e304c9c2c6cd9a56680763a5906e9e6f59c702525edfe22ad
```

It programs EF3L90CG400B, IDCODE `0x00008C3B`, with 75 sector erases and
1199 write/readback pages. Flash bytes match the supplied V3 `.bit`
(`d837f017b99cd2409d9cb2d81c4179d6b2ae77c668f0499ec1144d17f39b98bd`).
There is one Refresh instruction, after every page comparison:

```text
FF -> 01 -> 20 TCK -> (FF -> 20 TCK) x4 -> FF -> 10000 TCK
   -> 20 / SDR 32 TDO 0 MASK 0 -> 80 / SDR 64 A5 -> 200 TCK
```

This is the new combined export's tail, not the earlier independent Refresh
file's 15/200000-clock tail or openFPGALoader's reset sequence.

The short reference is `INS_ZQ6_CPLD_V3_bg_verify_refresh_short.svf`, exported
2026-10-12 15:18, SHA256:

```text
8420dfc564d61e7b84038875c6bd19447433facc32df373094736730b96b906a
```

These are observed differences between the supplied exports, not assumptions
about other TD versions:

| Property | normal | short |
| --- | --- | --- |
| File size | 2626650 bytes | 3765331 bytes (below 4 MiB) |
| Parsed commands | 5064 | 38620 |
| Contiguous write/readback block | 256 bytes, 1199 blocks | 32 bytes, 9588 blocks |
| Write/readback SDR length | 2088 / 2089 bits | 296 / 297 bits |
| Wait after each write | 5000 TCK | 10000 TCK |
| Written bytes | 306944 | 306816 |
| Sector erases | 75 | 75 |
| Refresh tail | 10532 clocks | Identical 10532 clocks |

The shared 306816-byte prefix is identical. Normal adds 128 trailing FF bytes;
both exports erase the same sectors, including that trailing area. Each short
readback checks all 256 data bits under its MASK, at the same 41-bit response
offset. The initial background entry/QE commands and final Refresh are identical.
Short means shorter scans in these exports, not a smaller file or faster update:
it has more commands, write waits and serial log lines. It retains the original
600-second total deadline; board timing and automatic recovery still need
validation. Upload the original short SVF without converting it to normal.

## Whole-file validation before programming

`cpld_svf.py` parses and validates the whole upload before opening JTAG. It
accepts the reviewed single-device profile, not arbitrary SVF scripts:

- Explicit SIR/SDR TDI values and explicit TDO/MASK when comparing; no partial
  or sticky SMASK. Maximum scan data length is 4096 bits.
  Uploads remain at most 4 MiB, with at most 50000 parsed commands to cover
  the bounded Primary image's reviewed short mode.
- TRST OFF, ENDIR/ENDDR IDLE, STATE RESET/IDLE, FREQUENCY 1 MHz, and zero
  HIR/HDR/TIR/TDR. Unknown commands, scan fields or TAP end states are rejected.
- Exact reviewed background entry, QE setup, WREN/sector erase/page write,
  verification and final Refresh/cleanup order. Every file RUNTEST count is
  retained, including the two separate 50000-clock QE waits.
- Contiguous writes from address 0 using one consistent reviewed block size:
  normal 256 bytes or short 32 bytes. Mixed block sizes are rejected. Require
  exactly sufficient 4 KiB sector erases and one full 2048-bit (normal) or
  256-bit (short) data TDO/MASK comparison for each written block.
  Missing, reordered or weakened comparisons are rejected before any erase.
- Recognized Anlogic preamble, exact IDCODE vector and bounded Primary data.
- Running persist_bit confirmation remains required. The SVF encodes only
  the first 16 Flash feature bytes; these must uniquely match an approved
  complete 18-byte feature field in `cpld-update.json`. The final two ASCII
  feature bytes are not present in this export and are not claimed as read back.

The accepted format supports the same layout with a changed payload/page count,
subject to the same feature approval and Primary limit. Other TD versions,
export modes, extra devices or changed protocols require review and adaptation.

The service validates at Start; the worker revalidates after waiting for Host
Off and checks the original SVF SHA256 so the file cannot silently change.
It performs an independent exact IDCODE check before the first SVF register
write, then plays the file's own device check as well. The player takes all
scan values, masks and clock counts from parsed upload commands.

## Web JSON upload limit

The legacy D-Bus REST `Start(s)` request sends the original SVF as one Base64
string in `{"data":["..."]}`. bmcweb's normal JSON parser rejects bodies above
1 MiB, separately from the HTTP firmware body limit. Without the board patch,
both reviewed exports fail before reaching the updater with
`No JSON object could be decoded`; that message is not an SVF validation error.

`0010-ceb-gnrd-cpld-svf-json-upload-limit.patch` opts into a 5592472-byte JSON
limit only for object `/xyz/openbmc_project/software/cpld_update`, method
`Start`: 4 MiB raw SVF encoded as Base64 plus 64 bytes of JSON envelope. Oversize
CPLD requests receive HTTP 413. Other methods retain the 1 MiB JSON default;
content-type checks and the existing SAX depth/value limits remain in use.
The guarded service still enforces the actual 4 MiB decoded file limit and
validates the whole SVF before opening JTAG. Rebuild bmcweb as well as the
updater/image to obtain this fix; updating only Web assets is insufficient.

## Progress, activation and serial diagnostics

- The service requires three stable Off samples and checks the BMC updater
  before/after shutdown wait. Host-state query failure blocks programming.
- Periodic Host checks continue during playback; a fresh Off check precedes
  the first post-verification Refresh batch. Cancellation is available only
  while waiting for shutdown.
- The complete operation retains its original **600-second deadline**,
  including validation, shutdown wait, playback and BMC recovery. RUNTEST
  emits actual IDLE TCK clocks, not wall-clock sleeps or inferred SPI polls.
- Nonzero TDO masks are compared directly; mismatch, wrong IDCODE, Host On or
  timeout stops playback and blocks Refresh. The tail's `MASK=0` status read
  is explicitly unverified; it cannot confirm CPLD DONE or running version.
- Serial `CPLD-TRACE` logs include command index, original SVF line number,
  SIR opcode, SDR size, page/address and TDO/MASK MATCH/mismatch, plus RUNTEST
  counts. Large bit vectors are not dumped into the terminal.
- Logs go directly to inherited stderr/journal and a best-effort nonblocking
  `/dev/console` copy. JSON progress is a separate stdout channel. The service
  keeps `CEB_GNRD_CPLD_CONSOLE_DEBUG=1`; disable it via a drop-in after validation.
- After all pages pass, the worker writes an atomic verified receipt before
  the first post-verify FF. It records the SVF hash, reconstructed Flash hash,
  page count and original recovery deadline. Progress processing cannot
  overwrite this receipt with an earlier phase.
  For compatibility `verifiedPages` counts transfer blocks; `lengthMode`,
  `programmingChunkBytes` and `programmedBytes` record their actual size and
  byte total. Short progress/serial messages call the 32-byte units blocks.
- The **actual parsed SVF tail** is compiled into 10532 clocks, in bounded
  batches of 4096, 4096 and 2340. This preserves every scan and RUNTEST count
  while avoiding user-space logging/Host-query gaps across FF/01. `QUEUED`
  markers mean commands have not yet been sent. Command END markers appear
  only after the batch containing their final clocks returns. Loss of BMC
  supply/reset can still interrupt a batch; no IO latch is supplied.
- The final Host check runs after tail compilation/logging, immediately before
  the first clock batch. A bounded one-second diagnostic pause follows the
  queued-command markers before that check, giving external serial capture an
  observation window. It consumes the original deadline and does not guarantee
  UART drain. Normal D-Bus loss after activation is not Host On.

The old BMC receives no software reboot command. Completion still requires a
verified receipt plus a new BMC boot within the original deadline. This does
not prove automatic power recovery or a running CPLD version: manual AC cycling
can also produce a new boot. If Flash is confirmed fully verified and the board
does not recover, an operator can disconnect **all** AC inputs and restore
power. Do not interrupt erase/write/verification with a power cycle.

## Comparison with the supplied Phytium update-cpld.sh

Reference: user-supplied script copied from OurBMC-25.01 at commit
`bdbb7a9dc02012ad0d76e7c1c93366c91dd1affc`.

| Step | Phytium script | CEB-GNRD implementation |
| --- | --- | --- |
| Host shutdown | Query chassis, reject text containing On | Require explicit stable Off; query errors block; continue checking during playback |
| JTAG selection | `gpioutil set $CPLD_GPIO 1`, restore 0 | No selection GPIO; dedicated AST2600 Master-1 |
| SVF execution | `loadsvf -d /dev/jtag0 -v -s jtag.svf` | Validated SVF player on existing custom AST2600 clock ABI |
| Progress | Parse a temporary text file into ActivationProgress | Structured worker events update the existing CPLD D-Bus Status/Web progress |
| Failure | Search text for fail/not; player exit status is not captured | Full prevalidation, nonzero TDO/MASK comparisons, process exit code and deadline |
| Logs | Redirect player output to /tmp/cpld_progress | Direct journal + serial command/batch traces, separate JSON progress |
| Completion | Treat text containing Done as completed | Flash verification, receipt before Refresh and observed new BMC boot; no DONE/version claim |
| Version | Compare software inventory strings | No trusted CPLD running-version register is available; show SVF hash/feature approval instead |
| Timeout/cleanup | No total timeout; monitor background process | Original 600-second limit, bounded worker, locks and RAM upload cleanup |

Both implement Host Off -> play SVF -> report progress/failure. The Phytium
driver and GPIO operations are platform-specific. CEB-GNRD uses its existing
driver ABI rather than renaming the device for an incompatible loadsvf binary.

TDO/MASK comparison follows the expected values and masks in the exported SVF:
`(actual & mask) == (expected & mask)`. The upstream
[loadsvf svf.c at 535bfe23](https://github.com/Nuvoton-Israel/loadsvf/blob/535bfe23/src/svf.c)
also implements this comparison in `svf_check_tdo`; it is not an additional
CPLD command. A zero mask requests no comparison.

The supplied Phytium shell does not capture the player's exit status. In the
reviewed upstream [main.c at 535bfe23](https://github.com/Nuvoton-Israel/loadsvf/blob/535bfe23/src/main.c),
`handle_svf_command`'s return value is ignored and `main` returns zero even on
failure. Phytium downstream changes to that entry point have not been checked.
CEB-GNRD explicitly returns a nonzero worker exit code on playback failure and
checks it in the service, in addition to recording the detailed error.

## Storage, integration and validation limits

The upload is one root-only RAM file, `/run/ceb-gnrd-cpld-update/image.svf`.
The receipt is `/var/lib/ceb-gnrd-cpld-update/result.json`, at most 8 KiB plus
one temporary file. Under normal Flash boot it lives in rwfs; TFTP boot uses
a RAM overlay, so the receipt and local logs disappear on reboot. Capture the
serial transcript outside BMC. For persistent recovery tracking, install the
firmware into Flash before end-to-end validation.

DS600_1.8 reserves Golden feature/address at `0x060000`, Golden bitstream at
`0x061000`. Primary data is limited to 384 KiB, with all erases strictly below
Golden. V3 normal writes end at `0x04AEFF`, short writes at `0x04AE7F`;
both erase coverage ends at `0x04AFFF`.
No Golden image is created/enabled/validated by the player. The reviewed file
also contains the vendor comment "Disable Dual boot loop"; its register map
is unavailable, so this is not proof that automatic fallback is enabled.

Web BMC/BIOS uploads and CPLD programming share existing firmware locks; the
transport remains exclusive-open/root-only. No GPIO mux/hold/reset instruction
is added. The recipe installs the player alongside the service and transport.
The firmware page keeps the BMC/BIOS upload control style for the CPLD SVF form.

The supplied SVF and synthetic fake-transport/service tests have been checked
offline. They never touch board Flash or GPIO. Full Yocto build and controlled
board validation of timing, TDO, power/reset recovery and CPLD function are
still required. The Golden v1 tag remains the earlier baseline.
