# This recipe has no version suffix, so the bbappend file name must not use _%.
# Factory default of the power restore policy: AlwaysOn (the host powers on when
# AC power returns).  The user can change it to AlwaysOn / AlwaysOff / Restore in
# the web UI; the choice is persisted.
do_install:append:ceb-gnrd() {
    sed -i \
        's/Default: RestorePolicy::Policy::AlwaysOff/Default: RestorePolicy::Policy::AlwaysOn/g' \
        ${D}${settings_datadir}/defaults.yaml
}