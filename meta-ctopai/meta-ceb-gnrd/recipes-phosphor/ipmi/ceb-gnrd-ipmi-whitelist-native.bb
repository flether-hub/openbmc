SUMMARY = "CEB-GNRD IPMI command whitelist additions"
DESCRIPTION = "Allow the Admin-only IPMI Master Write-Read command."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
WHITELIST = "ceb-gnrd-ipmi-whitelist.conf"

inherit phosphor-ipmi-host-whitelist
inherit native
