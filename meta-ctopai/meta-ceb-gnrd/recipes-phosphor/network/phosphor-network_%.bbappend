# MAC addresses are provisioned in U-Boot, not persisted in Linux .network files.
# This also rejects MAC writes through the network D-Bus API instead of creating
# a second, conflicting persistent source of addresses.
PACKAGECONFIG:remove:ceb-gnrd = "persist-mac sync-mac"
