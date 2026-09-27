# Host control is connected through OpenBMC target links and D-Bus activation.
# Avoid running systemctl enable in the rootfs postinst, which fails for the
# triggered/template units in a cross-built image.
SYSTEMD_AUTO_ENABLE:${PN}:ceb-gnrd = "disable"
