# The FIT kernel (fitImage-obmc-phosphor-initramfs-ceb-gnrd-ceb-gnrd) is built
# and deployed by the linux-yocto-fitimage recipe, but image_types_phosphor only
# makes the static image tarball wait for virtual/kernel:do_deploy.  After an
# sstate cleanup the fitImage is missing from the deploy directory and
# do_generate_static_tar fails with "image-kernel: No such file or directory".
do_generate_static_tar[depends] += "linux-yocto-fitimage:do_deploy"
