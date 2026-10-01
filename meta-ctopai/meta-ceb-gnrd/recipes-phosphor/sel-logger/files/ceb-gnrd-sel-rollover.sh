#!/bin/sh
# SEL rollover: when the SEL is full, the oldest records are overwritten.
#
# phosphor-sel-logger appends one line per record to /var/log/ipmi_sel (written
# by rsyslog) and numbers new records from the last line, so removing the oldest
# lines never reuses a record ID.  The file is trimmed in place (rsyslog keeps it
# open in append mode), with some slack so it is not rewritten for every record.

SEL=/var/log/ipmi_sel
MAX_ENTRIES=2000
SLACK=100
INTERVAL=30

log() {
    echo "$*"
    logger -t ceb-gnrd-sel-rollover "$*" 2>/dev/null || true
}

log "SEL rollover enabled: keep the newest $MAX_ENTRIES records of $SEL"
while :
do
    if [ -f "$SEL" ]
    then
        count=$(wc -l < "$SEL")
        if [ "$count" -gt $((MAX_ENTRIES + SLACK)) ]
        then
            tmp="$SEL.rollover"
            if tail -n "$MAX_ENTRIES" "$SEL" > "$tmp"
            then
                cat "$tmp" > "$SEL"
                log "SEL full ($count records): removed the oldest $((count - MAX_ENTRIES))"
            fi
            rm -f "$tmp"
        fi
    fi
    sleep "$INTERVAL"
done
