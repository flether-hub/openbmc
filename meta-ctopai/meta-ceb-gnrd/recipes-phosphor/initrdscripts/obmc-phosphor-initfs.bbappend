FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Settings that must also survive a firmware update which cleans the rwfs:
# timezone, hostname, SSH host keys, web certificates and the CEB-GNRD fan
# settings.  A factory reset still erases everything (nothing is saved).
SRC_URI:append:ceb-gnrd = " file://ceb-gnrd-whitelist file://ceb-gnrd-update-skip-u-boot.sh"

do_install:append:ceb-gnrd() {
    # A BMC update does not rewrite U-Boot (see ceb-gnrd-update-skip-u-boot.sh):
    # insert the check into the update script just before it lists the images.
    awk -v snippet=${UNPACKDIR}/ceb-gnrd-update-skip-u-boot.sh '
        !done && index($0, "imglist=$(echo $image*)") == 1 {
            while ((getline line < snippet) > 0) print line
            print ""
            done = 1
        }
        { print }
        END { if (!done) exit 1 }' ${D}/update > ${B}/update.ceb-gnrd || \
        bbfatal "obmc-update.sh: image list line not found, cannot skip U-Boot"
    cat ${B}/update.ceb-gnrd > ${D}/update


    while read -r f
    do
        if test $(realpath -L -m ${UNPACKDIR}$f) != ${UNPACKDIR}$f
        then
            bberror "Bad whitelist entry ${f}."
        fi
        grep -qxF "$f" ${D}/whitelist || echo "$f" >> ${D}/whitelist
    done < ${UNPACKDIR}/ceb-gnrd-whitelist
}