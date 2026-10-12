# AMI Aptio V POST code interpretation

Updated from the supplied `ami-aptio-v-post-codes.md` dated 2026-10-12.
Web POST logs and the Boot_Progress service use the shared catalog
`recipes-phosphor/state/files/ami-aptio-v-post-codes.json`.

## Reference scope

- AMI Aptio V generic checkpoint meanings follow Supermicro Rev 1.0b,
  adapted from Aptio 5.x Status Codes Rev 2.04.
- The supplied Chinese explanations cover SEC, PEI, DXE/BDS, S3 resume,
  Recovery and ACPI/ASL. Undefined/reserved DE-DF entries are included.
- 05/0A are OEM SEC checkpoints, not a known board-specific operation.
- 5C has conflicting failure/reserved entries in the reference. Its description
  explicitly requests platform confirmation; it does not advance boot progress.
- OEM, reserved, unknown and unsupported multi-byte values retain the
  "No matching POST code description" message. No low-byte truncation is used.

## Sequence context and Intel reuse

The generic AMI table cannot unambiguously decode Intel platform codes.
[Oracle's published Intel alternatives](https://docs.oracle.com/cd/E56388_01/html/E56396/gnwjq.html)
for B0-BC/BF are provided as **possible meanings, unconfirmed for GNR-D**.
BD/BE have no matched Intel-specific definition. The Intel
[S2600WFT E8 example](https://www.intel.com/content/www/us/en/support/articles/000055207/server-products/server-boards.html)
is labeled as an example for that board, not a confirmed GNR-D memory error.

POST log interpretation groups rows by bootCount and processes their API
receive index from oldest to newest. It does so before search, date filtering,
pagination or display sorting. No context carries into another boot cycle.
Rows without reliable cycle/index metadata retain generic alternatives.

Shared context rules:

1. Pre-memory PEI 10-2F before handoff establishes a pre-memory hint.
2. B0-BF encountered while that hint is active show a possible Intel memory
   initialization meaning. They do not publish OSStart, reset progress for B3,
   or otherwise claim that a GNR-D-specific stage completed.
3. Recognized post-memory 31-4F or later DXE/BDS 60-AF clears the pre-memory
   hint. Only recognized later progress/runtime codes establish later context;
   an OEM/reserved code alone does not do so.
4. Without pre-memory or later context, B0-BF retain both generic/Intel meanings
   and do not change coarse Boot_Progress. Missing early snoop data cannot be
   treated as proof of BDS or OS handoff.
5. E0-E3 supplies an S3 hint. E8-EF during pre-memory initialization instead
   shows a possible platform memory error, with its GNR-D-specific meaning
   explicitly unmatched. Other cases retain S3/Intel alternatives.
6. After handoff, reused ACPI sleep/wake values do not regress boot progress.
   Their text retains both documented meanings because missing reset records
   can leave the phase ambiguous. AA/AC are ACPI transitions, not POST failures.

The live service exports `BootPostCodeContext` with the current code. The
Boot_Progress Web row uses it so it follows the same sequence hints as the
backend. Power-off or POST-complete deassertion clears live context; a new
POST-complete signal can still publish OSStart unless the last code is an error.
No POST code alone proves the operating system is running.

The page explains that a progress code is a reached checkpoint. A frozen code
does not alone prove that checkpoint failed; inspect subsequent steps and
hardware state. No changes to LPC/eSPI snoop wiring, raw code collection or
beep decoding are made by this interpretation update.
