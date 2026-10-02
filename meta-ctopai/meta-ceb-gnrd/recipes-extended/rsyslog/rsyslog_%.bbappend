# phosphor-sel-logger writes every SEL record to the journal; rsyslog turns the
# journal fields (MESSAGE_ID, IPMI_SEL_*) into /var/log/ipmi_sel with the rule that
# phosphor-sel-logger installs in /etc/rsyslog.d.  The default imuxsock input only
# sees plain syslog text without these fields, so without imjournal the SEL stays
# empty.  meta-phosphor installs imjournal.conf when this option is set (the Intel
# reference platform enables it the same way).
PACKAGECONFIG:append:ceb-gnrd = " imjournal"