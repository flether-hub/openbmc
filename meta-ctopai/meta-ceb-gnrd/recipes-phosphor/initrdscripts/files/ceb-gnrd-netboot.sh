#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Sourced by /init after optfile is initialized. No Flash writes in netboot.
ceb_gnrd_prepare_netboot() {
    ceb_gnrd_netboot=n
    ceb_url=$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^ceb-gnrd-netboot=//p')
    if ! tr ' ' '\n' < /proc/cmdline | grep -q '^ceb-gnrd-netboot='
    then
        return 0
    fi

    case "$ceb_url" in
        tftp://*) ;;
        *) debug_takeover "CEB-GNRD: unsupported network rootfs URL"; exit 1 ;;
    esac
    ceb_remote=${ceb_url#tftp://}
    ceb_server=${ceb_remote%%/*}
    ceb_file=${ceb_remote#*/}
    case "$ceb_server" in
        ''|*[!0-9.]*) debug_takeover "CEB-GNRD: rootfs server must be an IPv4 address"; exit 1 ;;
    esac
    if ! printf '%s\n' "$ceb_server" | awk -F. '
        NF != 4 { exit 1 }
        { for (i = 1; i <= 4; i++) if ($i == "" || $i < 0 || $i > 255) exit 1 }'
    then
        debug_takeover "CEB-GNRD: invalid rootfs server IPv4 address"
        exit 1
    fi
    case "$ceb_file" in
        ''|/*|*[!A-Za-z0-9_./-]*|..|../*|*/../*|*/..|.|./*|*/./*|*/.|*//*)
            debug_takeover "CEB-GNRD: invalid rootfs filename"; exit 1 ;;
    esac
    test "$ceb_remote" != "$ceb_file" || {
        debug_takeover "CEB-GNRD: missing rootfs filename"; exit 1
    }

    # Kernel ip=... sets up eth0 before PID 1; no DHCP or DNS is needed here.
    ceb_image=/run/ceb-gnrd-netboot/rootfs.squashfs
    mkdir -p /run/ceb-gnrd-netboot || exit 1
    echo "CEB-GNRD: downloading rootfs $ceb_url into RAM (timeout 180 seconds)"
    # ash ulimit -f uses 512-byte blocks: cap the file at the 40 MiB rofs budget.
    if ! (ulimit -f 81920 && timeout -s KILL 180 tftp -g -b 1468 \
            -r "$ceb_file" -l "$ceb_image" "$ceb_server")
    then
        rm -f "$ceb_image"
        debug_takeover "CEB-GNRD: rootfs TFTP download failed; Flash fallback disabled"
        exit 1
    fi
    ceb_size=$(stat -c %s "$ceb_image") || exit 1
    if test "$ceb_size" -le 0 || test "$ceb_size" -gt 41943040 ||
            test "$(blkid_fs_type "$ceb_image")" != squashfs
    then
        rm -f "$ceb_image"
        debug_takeover "CEB-GNRD: invalid/oversize network rootfs; Flash fallback disabled"
        exit 1
    fi

    ceb_gnrd_netboot=y
    rodev=$ceb_image
    roopts=ro,loop
    rwfst=none
    force_rwfst_jffs2=n
    consider_download_files=n
    # Ignore saved reset/update flags. Old Flash upper files must not hide the
    # downloaded Web and service files. The entire write overlay lives in RAM.
    printf '%s\n' overlay-filesystem-in-ram > "$optfile" || exit 1
    printf 'url=%s\nbytes=%s\noverlay=RAM\n' "$ceb_url" "$ceb_size" \
        > /run/ceb-gnrd-netboot/source || exit 1
    echo "CEB-GNRD: using TFTP rootfs, $ceb_size bytes; write overlay is RAM"
}

ceb_gnrd_prepare_netboot
