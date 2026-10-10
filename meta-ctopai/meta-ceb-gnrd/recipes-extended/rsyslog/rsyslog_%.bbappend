FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# phosphor-sel-logger writes every SEL record to the journal; rsyslog turns the
# journal fields (MESSAGE_ID, IPMI_SEL_*) into /var/log/ipmi_sel with the rule that
# phosphor-sel-logger installs in /etc/rsyslog.d.  The default imuxsock input only
# sees plain syslog text without these fields, so without imjournal the SEL stays
# empty.  meta-phosphor installs imjournal.conf when this option is set (the Intel
# reference platform enables it the same way).
PACKAGECONFIG:append:ceb-gnrd = " imjournal"

# The Redfish event log (web "Event logs") is /var/log/redfish, written from
# journal entries that carry a REDFISH_MESSAGE_ID.
SRC_URI:append:ceb-gnrd = " file://ceb-gnrd-redfish.conf file://ceb-gnrd-system-errors.conf file://rsyslog-override.conf file://ceb-gnrd-rotate-log.sh"
FILES:${PN}:append:ceb-gnrd = " \
    ${libexecdir}/ceb-gnrd-rotate-log \
    ${sysconfdir}/rsyslog.d/ceb-gnrd-redfish.conf \
    ${sysconfdir}/rsyslog.d/ceb-gnrd-system-errors.conf \
    ${systemd_system_unitdir}/rsyslog.service.d/rsyslog-override.conf \
    "

do_install:append:ceb-gnrd() {
    install -Dm0755 ${UNPACKDIR}/ceb-gnrd-rotate-log.sh ${D}${libexecdir}/ceb-gnrd-rotate-log
    install -D -m 0644 ${UNPACKDIR}/ceb-gnrd-redfish.conf \
        ${D}${sysconfdir}/rsyslog.d/ceb-gnrd-redfish.conf
    install -D -m 0644 ${UNPACKDIR}/ceb-gnrd-system-errors.conf \
        ${D}${sysconfdir}/rsyslog.d/ceb-gnrd-system-errors.conf
    install -D -m 0644 ${UNPACKDIR}/rsyslog-override.conf \
        ${D}${systemd_system_unitdir}/rsyslog.service.d/rsyslog-override.conf
}
