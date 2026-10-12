# CEB-GNRD CPLD Web upgrade

## Supported hardware and format

- AST2600 dedicated JTAG Master-1, register base `0x1e6e4000`; reset 22.
  This is not the GPIOI / JTAG Master-2 group.
- Anlogic EF3L90CG400B, IDCODE `0x00008C3B`, internal 8 Mbit SPI Flash.
- Upload the TD `.bit` format used by the supplied `INS_ZQ6_CPLD_V3.bit`.
  Maximum upload and decoded Flash data: 1 MiB. No arbitrary SVF execution.
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
6. Recheck IDCODE and Host Off, persist the verified receipt, then issue the
   independent JTAG Refresh sequence. No GPIO reset is used.
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

## Network boot and CPLD recovery

`run bootnet` loads the TFTP kernel and rootfs with a fresh RAM write overlay.
This is a temporary firmware run: configuration changes and CPLD receipts in
that overlay are lost at reboot. Default reboot still uses Flash (`bootspi`).
For end-to-end CPLD Refresh / BMC reboot validation, first install this firmware
into Flash so the update service and its persistent receipt survive the reset.
