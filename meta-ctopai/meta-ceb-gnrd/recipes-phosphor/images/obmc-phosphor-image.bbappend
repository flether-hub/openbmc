# The FIT kernel (fitImage-obmc-phosphor-initramfs-ceb-gnrd-ceb-gnrd) is built
# and deployed by the linux-yocto-fitimage recipe, but image_types_phosphor only
# makes the static image tarball wait for virtual/kernel:do_deploy.  After an
# sstate cleanup the fitImage is missing from the deploy directory and
# do_generate_static_tar fails with "image-kernel: No such file or directory".
do_generate_static_tar[depends] += "linux-yocto-fitimage:do_deploy"

# The machine no longer enables df-pldm, so the PMCI packagegroup does not
# pull in PLDM. Reject accidental dependencies instead of silently adding
# the unconfigured daemon, its libraries or diagnostic tool back to rootfs.
PACKAGE_EXCLUDE:append:ceb-gnrd = " pldm pldm-libs pldmtool"

# Modern SCP uses the retained SFTP server, not the legacy SCP executable.
PACKAGE_EXCLUDE:append:ceb-gnrd = " openssh-scp"

# Reject accidental reintroduction of the unused file synchronization tool.
PACKAGE_EXCLUDE:append:ceb-gnrd = " rsync"
