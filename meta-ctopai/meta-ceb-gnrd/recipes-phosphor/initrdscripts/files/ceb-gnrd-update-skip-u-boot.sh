# CEB-GNRD: inserted before the generic updater builds its image list.
# Selection is staged with this package by the software manager. A full-flash
# image cannot honor partition selection, even when U-Boot was confirmed.
plan=/run/initramfs/bmc-partitions.txt
if test -e /run/initramfs/ceb-gnrd-update-incomplete
then
	echoerr "BMC partition staging was interrupted; refusing partial update."
	exit 1
fi
if test -e "${image}bmc"
then
	echoerr "Full-flash BMC updates are disabled; use .static.mtd.tar."
	exit 1
fi

selected=" kernel rofs rwfs "
if test -e "$plan"
then
	if test ! -f "$plan" || test -L "$plan" || test "$(stat -c %s "$plan")" -gt 128
	then
		echoerr "Invalid BMC partition plan."
		exit 1
	fi
	selected=" "
	{
		read -r version
		if test "$version" != "version=1"
		then
			echoerr "Unsupported BMC partition plan."
			exit 1
		fi
		while IFS= read -r partition
		do
			case "$partition" in
			kernel|rofs|rwfs|u-boot|u-boot-env) ;;
			*) echoerr "Unknown BMC partition in plan: $partition"; exit 1 ;;
			esac
			case "$selected" in
			*" $partition "*) echoerr "Duplicate BMC partition: $partition"; exit 1 ;;
			esac
			if test ! -f "${image}${partition}" || test -L "${image}${partition}"
			then
				echoerr "Missing staged BMC partition: $partition"
				exit 1
			fi
			# An empty JFFS2 rwfs is valid and is skipped by the generic updater.
			if test "$partition" != rwfs && test ! -s "${image}${partition}"
			then
				echoerr "Empty staged BMC partition: $partition"
				exit 1
			fi
			selected="$selected$partition "
		done
	} < "$plan"
	case "$selected" in *" kernel "*) ;; *) echoerr "kernel must be selected"; exit 1 ;; esac
	case "$selected" in *" rofs "*) ;; *) echoerr "rofs must be selected"; exit 1 ;; esac
fi

for partition in kernel rofs rwfs u-boot u-boot-env
do
	case "$selected" in
	*" $partition "*)
		if test "$partition" = u-boot-env && test "$(stat -c %s "${image}${partition}")" != 131072
		then
			echoerr "Invalid U-Boot environment reset image size."
			exit 1
		fi
		echo "BMC update selected: $partition"
		;;
	*)
		echo "BMC update preserved: $partition"
		rm -f "${image}${partition}"
		;;
	esac
done
# The legacy opt-in alone no longer permits overwriting protected partitions.
rm -f /run/initramfs/update-u-boot
