CTOPAI OpenBMC Vendor Layer
============================

This is the top-level meta-ctopai vendor layer for ASPEED AST2600 based boards.
Board-specific layers are nested underneath:

* **meta-ceb-gnrd** – CEBSmart-GN-RD board (AST2600 EVB)

To build for a specific board:

    ./setup <board-name>          # auto-detects from meta-*/*/conf/machine/*.conf
    bitbake obmc-phosphor-image

Or set up manually:

    TEMPLATECONF=meta-ctopai/meta-ceb-gnrd/conf/templates/default \
        source oe-init-build-env build/<board-name>

Documentation:

* `quick-start.md` – how to build the ceb-gnrd image, run it in QEMU, develop with
  devtool, verify each feature, and (last chapter) the implementation notes of
  the meta-ceb-gnrd layer.
* `port_guide.xlsx` – signal-by-signal port guide of the ceb-gnrd board.
