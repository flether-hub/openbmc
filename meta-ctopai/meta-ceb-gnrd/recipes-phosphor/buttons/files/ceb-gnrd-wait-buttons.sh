#!/bin/sh
# phosphor-button-handler looks up the button objects once, when it starts, and
# the buttons daemon takes its bus name before it has exported them.  Started
# together they race and the handler then ignores the UID button.  Wait here
# until the UID button object exists (up to 60 s; never fail the handler).
i=0
while [ "$i" -lt 60 ]; do
    if busctl --system tree xyz.openbmc_project.Chassis.Buttons --no-pager 2>/dev/null |
        grep -q '/Buttons/ID'; then
        exit 0
    fi
    i=$((i + 1))
    sleep 1
done
echo "UID button object did not appear within 60 s" >&2
exit 0
