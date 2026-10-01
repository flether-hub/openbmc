#!/bin/sh

set -u

input_line=98
output_led=/sys/class/leds/cpu-power-button/brightness

log_sel_event() {
	for attempt in 1 2 3; do
		if busctl call xyz.openbmc_project.Logging.IPMI \
			/xyz/openbmc_project/Logging/IPMI \
			xyz.openbmc_project.Logging.IPMI IpmiSelAdd ssaybq \
			'Chassis Power Button Pressed' \
			'/xyz/openbmc_project/state/chassis0' \
			3 0x00 0xff 0xff true 0x0020; then
			return 0
		fi
		sleep 1
	done
	logger -t ceb-gnrd-power-button \
		'failed to record chassis power button press in IPMI SEL'
	return 1
}

if [ ! -w "$output_led" ]; then
	logger -t ceb-gnrd-power-button \
		"CPU power button LED GPIO is unavailable: $output_led"
	exit 1
fi

# The gpio-leds driver owns the active-low output and keeps it deasserted high.
printf '0\n' > "$output_led"

while :; do
	gpiomon --format='%e' --edges=both --chip=gpiochip0 "$input_line" 2>/dev/null |
	while IFS= read -r edge; do
		case "$edge" in
			2)
				printf '1\n' > "$output_led"
				log_sel_event &
				;;
			1)
				printf '0\n' > "$output_led"
				;;
		esac
	done
	logger -t ceb-gnrd-power-button \
		'GPIO edge monitor stopped; retrying'
	sleep 1
done
