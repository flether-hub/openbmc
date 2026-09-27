CTOPAI OpenBMC Vendor Layer
============================

This is the top-level meta-ctopai vendor layer for ASPEED AST2600 based boards.
Board-specific layers are nested underneath:

* **meta-ceb-gnrd** – CEBSmart-GN-RD board (AST2600 EVB)

To build for a specific board:

    ./setup <board-name>          # auto-detects from meta-*/*/conf/machine/*.conf
    bitbake obmc-phosphor-image

Or set up manually:

    TEMPLATECONF=meta-ceb-gnrd/conf/templates/default \
        source oe-init-build-env build/<board-name>
