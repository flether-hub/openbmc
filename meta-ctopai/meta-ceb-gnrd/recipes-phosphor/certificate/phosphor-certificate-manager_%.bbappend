
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append:ceb-gnrd = " file://0001-ceb-gnrd-bound-certificate-storage.patch"
SRC_URI:append:ceb-gnrd = " file://0002-ceb-gnrd-transactional-authority-replacement.patch"
SRC_URI:append:ceb-gnrd = " file://0003-ceb-gnrd-use-individual-authorities-as-persistent-store.patch"
