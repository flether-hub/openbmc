# Standard OpenBMC recovery of a failed critical service: units mark themselves
# failed with OnFailure=obmc-bmc-service-quiesce@0.target (see ceb-gnrd-health);
# phosphor-state-manager then moves the BMC to Quiesced, and with this option it
# also reboots the BMC.  Upstream has no limit on these reboots, so ceb-gnrd-health
# adds an ExecCondition to phosphor-bmc-quiesce-reboot.service that allows at most
# 1 reboot (the count is cleared 15 minutes after a boot, so a later,\n# independent fault gets its reboot again); after that the
# BMC stays in Quiesced.
PACKAGECONFIG:append:ceb-gnrd = " auto-reboot-on-bmc-quiesce"