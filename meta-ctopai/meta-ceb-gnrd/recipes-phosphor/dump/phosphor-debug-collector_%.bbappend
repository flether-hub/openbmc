# Persistent rwfs is 14 MiB; reserve space for settings and event logs.
EXTRA_OEMESON:append:ceb-gnrd = " -DBMC_DUMP_MAX_SIZE=200 -DBMC_DUMP_TOTAL_SIZE=512"
