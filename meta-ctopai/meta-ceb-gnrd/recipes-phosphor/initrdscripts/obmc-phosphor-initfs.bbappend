FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Settings that must also survive a firmware update which cleans the rwfs:
# timezone, hostname, SSH host keys, web certificates, the CEB-GNRD fan settings
# and the bmcweb data (web login sessions, Redfish service UUID), so the web page
# stays logged in across a BMC update.  A factory reset still erases everything.
SRC_URI:append:ceb-gnrd = " file://ceb-gnrd-whitelist file://ceb-gnrd-update-skip-u-boot.sh file://ceb-gnrd-netboot.sh file://0001-ceb-gnrd-tftp-rootfs-for-network-boot.patch"

do_install:append:ceb-gnrd() {
    install -Dm0644 ${UNPACKDIR}/ceb-gnrd-netboot.sh ${D}/ceb-gnrd-netboot.sh
    # Check the package-local selection before constructing the flash list.
    awk -v snippet=${UNPACKDIR}/ceb-gnrd-update-skip-u-boot.sh '
        !done && index($0, "imglist=$(echo $image*)") == 1 {
            while ((getline line < snippet) > 0) print line
            print ""
            done = 1
        }
        index($0, "flashcp -v") && index($0, "&& rm") {
            print "\t\tif ! flashcp -v \"$f\" \"/dev/$m\"; then"
            print "\t\t\techoerr \"Flash write failed: $f; stopping update\""
            print "\t\t\texit 1"
            print "\t\tfi"
            print "\t\trm \"$f\""
            stop_on_error = 1
            next
        }
        { print }
        END { if (!done || !stop_on_error) exit 1 }' ${D}/update > ${B}/update.ceb-gnrd || \
        bbfatal "obmc-update.sh: selection or flash write hook not found"
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

FILES:${PN}:append:ceb-gnrd = " /ceb-gnrd-netboot.sh"
