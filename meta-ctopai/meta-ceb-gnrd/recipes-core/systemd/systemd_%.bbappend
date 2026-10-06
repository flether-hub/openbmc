# Derive the ttyS4 instance from the installed upstream template so agetty,
# credentials, device binding and terminal handling follow systemd updates.
do_install:append:ceb-gnrd() {
    sed '/^Before=getty.target$/d' \
        ${D}${systemd_system_unitdir}/serial-getty@.service \
        > ${D}${systemd_system_unitdir}/serial-getty@ttyS4.service
    cat >> ${D}${systemd_system_unitdir}/serial-getty@ttyS4.service <<'EOF'

[Unit]
# Remove the template's explicit Before=getty.target above. Also disable
# implicit target ordering: getty.target must not wait for this late console
# before multi-user.target can be reached. Restore service boot/shutdown
# dependencies explicitly; only ttyS4 gets this ordering.
DefaultDependencies=no
Requires=sysinit.target
After=sysinit.target basic.target multi-user.target obmc-led-group-start@bmc_booted.service
Wants=multi-user.target obmc-led-group-start@bmc_booted.service
Conflicts=shutdown.target
Before=shutdown.target
EOF
    chmod 0644 ${D}${systemd_system_unitdir}/serial-getty@ttyS4.service
}
