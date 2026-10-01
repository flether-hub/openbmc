#!/usr/bin/env python3
"""Generate Master Write-Read filters for PCIe I2C buses only."""

import json
import sys


filters = []
for bus_id in range(6):
    filters.append(
        {
            "Description": f"Allow read-only access on PCIe bus {bus_id}",
            "busId": f"0x{bus_id:02X}",
            "slaveAddr": "0x00",
            "slaveAddrMask": "0x7F",
            "command": "",
            "commandMask": "",
        }
    )

    # The upstream filter matches the complete write payload. Emit one
    # wildcard rule per valid write length so register data remains usable.
    for length in range(1, 65):
        filters.append(
            {
                "Description": (
                    f"Allow {length}-byte write-read payload on PCIe bus {bus_id}"
                ),
                "busId": f"0x{bus_id:02X}",
                "slaveAddr": "0x00",
                "slaveAddrMask": "0x7F",
                "command": " ".join(["0x00"] * length),
                "commandMask": " ".join(["0xFF"] * length),
            }
        )

with open(sys.argv[1], "w", encoding="ascii") as allowlist:
    json.dump({"filters": filters}, allowlist, indent=2)
    allowlist.write("\n")
