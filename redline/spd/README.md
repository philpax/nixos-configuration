# DDR4 SPD backups

Byte-for-byte dumps of the SPD EEPROMs on redline's eight DIMMs, taken before
any SMBus writes were made to the modules' RGB controllers (see
`../services/no-rgb-service.nix`). Each file is the full 512 bytes as exposed by
the kernel's `ee1004` driver at `/sys/bus/i2c/devices/0-00XX/eeprom`, named for
its SMBus address.

The RGB controllers live at `0x58`–`0x5F`, eight above the SPD addresses on the
same bus. A malformed write in that neighbourhood is the one plausible way to
corrupt SPD, and a DIMM with corrupt SPD will not POST — hence keeping these.

## What's in them

`0x50/52/54/56` are the `CMW128GX4M4Z3200C16` kit, `0x51/53/55/57` the
`CMW128GX4M4E3200C16` kit. Within each kit the dumps are identical, so there are
only two distinct images. Corsair leaves the serial number and manufacture date
fields unprogrammed (all zeroes), so nothing here is machine-specific.

## Re-dumping

    for d in /sys/bus/i2c/devices/0-005*/eeprom; do
      a=$(basename "$(dirname "$d")")
      cp "$d" "dimm-0x${a#0-00}.bin"
    done

## Restoring

`ee1004` is read-only by construction, so it has to be unbound first and the
write done through `i2c-dev`. DDR4 SPD is split into two 256-byte pages selected
by writing to SPA0 (`0x36`) and SPA1 (`0x37`); page selection is global to the
bus and sticky, so leave it on page 0 when finished.

    echo 0-0050 > /sys/bus/i2c/drivers/ee1004/unbind
    i2cset -y 0 0x36 0x00          # page 0
    i2cset -y 0 0x50 $offset $byte # one byte at a time, >= 4ms between writes
    i2cset -y 0 0x37 0x00          # page 1 for offsets 256-511
    ...
    i2cset -y 0 0x36 0x00          # leave the bus on page 0

Write protection (SWP) would block this, but setting it requires 7-10V on the
A0 pin, so it can't have been enabled in software and these modules ship
unprotected. If a module is too far gone to enumerate on the bus at all, an
external programmer clipped to the DIMM edge connector is the fallback.
