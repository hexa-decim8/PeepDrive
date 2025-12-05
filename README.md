# PeepDrive
This is a tool to help identify hard drive information and order to assist in LVM rebuilds.

## Read-only LVM report

A small script `peepdrive.sh` is included to generate a read-only text report of 
volume groups (VGs), logical volumes (LVs), and the physical volumes (PVs) that 
comprise them. The script will never modify LVM or disk state — it only reads 
metadata and writes the report file.

By default the script shows sizes in GiB (Gibibytes, 1024^3 bytes) with two
decimal places and writes output to `peepdrive.txt`.

Usage:

```sh
./peepdrive.sh [--vg VGNAME] [--output FILE]
```

- `--vg VGNAME`  : Limit output to a single VG
- `--output FILE`: Write report to FILE (default `peepdrive.txt`)