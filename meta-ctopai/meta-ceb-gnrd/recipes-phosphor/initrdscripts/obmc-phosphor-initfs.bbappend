FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Settings that must also survive a firmware update which cleans the rwfs:
# timezone, hostname, SSH host keys, web certificates and the CEB-GNRD fan
# settings.  A factory reset still erases everything (nothing is saved).
SRC_URI:append:ceb-gnrd = " file://ceb-gnrd-whitelist"

do_install:append:ceb-gnrd() {
    while read -r f
    do
        if test $(realpath -L -m ${UNPACKDIR}$f) != ${UNPACKDIR}$f
        then
            bberror "Bad whitelist entry ${f}."
        fi
        grep -qxF "$f" ${D}/whitelist || echo "$f" >> ${D}/whitelist
    done < ${UNPACKDIR}/ceb-gnrd-whitelist
}