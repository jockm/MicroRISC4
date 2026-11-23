#!/usr/bin/env python3
"""
mksdimg.py - Build a FAT32 SD card image from a host directory for MiniRISC4.

Usage:
    python3 tools/mksdimg.py <source_dir> -o <output.img> [--size-mb 16] [--spc 1]
"""

import argparse
import os
import struct
import sys
from pathlib import Path
from typing import Dict, List, Tuple

SECTOR_SIZE = 512
EOC_32 = 0x0FFFFFFF


def to_83_name(filename: str) -> bytes:
    """Convert a filename into an 11-byte FAT 8.3 directory entry name."""
    name = filename.upper().strip()
    if name == ".":
        return b".          "
    if name == "..":
        return b"..         "

    if "." in name:
        stem, ext = name.rsplit(".", 1)
    else:
        stem, ext = name, ""

    # Strip invalid FAT 8.3 characters
    valid_chars = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'()-@^_`{}~")
    stem_clean = "".join(ch for ch in stem if ch in valid_chars)[:8].ljust(8, " ")
    ext_clean = "".join(ch for ch in ext if ch in valid_chars)[:3].ljust(3, " ")
    return (stem_clean + ext_clean).encode("ascii")


def build_fat32_image(
    src_dir: Path,
    out_path: Path,
    size_mb: int = 16,
    sec_per_clus: int = 1,
    part_lba: int = 2048,
    rsvd_secs: int = 32,
    num_fats: int = 2,
    volume_label: str = "MR4_FAT32  ",
) -> None:
    if sec_per_clus <= 0 or (sec_per_clus & (sec_per_clus - 1)) != 0:
        raise ValueError("sec_per_clus must be a positive power of 2")

    total_sectors = (size_mb * 1024 * 1024) // SECTOR_SIZE
    if total_sectors <= part_lba + rsvd_secs + 64:
        raise ValueError("Image size too small for partition and FAT32 structures")

    part_sectors = total_sectors - part_lba

    # Compute FAT32 size in sectors iteratively so FAT covers all clusters
    fat_size_32 = 1
    while True:
        data_sectors = part_sectors - rsvd_secs - (num_fats * fat_size_32)
        total_clusters = data_sectors // sec_per_clus
        needed_fat_bytes = (total_clusters + 2) * 4
        new_fat_size = (needed_fat_bytes + SECTOR_SIZE - 1) // SECTOR_SIZE
        if new_fat_size == fat_size_32:
            break
        fat_size_32 = new_fat_size

    img = bytearray(total_sectors * SECTOR_SIZE)

    def write_sector(lba: int, data: bytes) -> None:
        assert len(data) == SECTOR_SIZE
        start = lba * SECTOR_SIZE
        img[start : start + SECTOR_SIZE] = data

    # --- 1. MBR at LBA 0 ---
    mbr = bytearray(SECTOR_SIZE)
    # Partition 1 entry at offset 446 (16 bytes): type 0x0C (FAT32 LBA)
    struct.pack_into(
        "<8BII",
        mbr,
        446,
        0x00,          # status / bootable flag
        0x00, 0x00, 0x00,  # CHS start (unused for LBA)
        0x0C,          # FAT32 LBA partition type
        0x00, 0x00, 0x00,  # CHS end (unused for LBA)
        part_lba,      # starting LBA
        part_sectors,  # number of sectors in partition
    )
    mbr[510] = 0x55
    mbr[511] = 0xAA
    write_sector(0, bytes(mbr))

    # --- 2. FAT32 Volume Boot Record (BPB) at LBA part_lba ---
    bpb = bytearray(SECTOR_SIZE)
    bpb[0:3] = b"\xEB\x58\x90"
    bpb[3:11] = b"MR4MKFS "
    struct.pack_into("<HBHBHHBHHHII", bpb, 11,
        SECTOR_SIZE,     # 11: bytes per sector (512)
        sec_per_clus,    # 13: sectors per cluster
        rsvd_secs,       # 14: reserved sectors
        num_fats,        # 16: number of FATs
        0,               # 17: root ent cnt (0 for FAT32)
        0,               # 19: tot sec 16 (0 for FAT32)
        0xF8,            # 21: media descriptor (fixed/SD)
        0,               # 22: fsz 16 (0 for FAT32)
        63,              # 24: sec per track
        255,             # 26: num heads
        part_lba,        # 28: hidden sectors (partition start LBA)
        part_sectors,    # 32: tot sec 32
    )
    root_clus = 2
    fsinfo_sec = 1
    backup_boot_sec = 6
    struct.pack_into("<IHHIHH12sBBBI11s8s", bpb, 36,
        fat_size_32,     # 36: sectors per FAT (32-bit)
        0,               # 40: ext flags
        0,               # 42: fs version
        root_clus,       # 44: root cluster (2)
        fsinfo_sec,      # 48: FSInfo sector relative to part_lba
        backup_boot_sec, # 50: backup boot sector relative to part_lba
        b"\x00" * 12,    # 52: reserved
        0x80,            # 64: drive number
        0,               # 65: reserved1
        0x29,            # 66: boot signature
        0x12345678,      # 67: volume serial
        volume_label.encode("ascii")[:11].ljust(11, b" "),  # 71: label
        b"FAT32   ",     # 82: fs type string
    )
    bpb[510] = 0x55
    bpb[511] = 0xAA
    write_sector(part_lba, bytes(bpb))
    if backup_boot_sec < rsvd_secs:
        write_sector(part_lba + backup_boot_sec, bytes(bpb))

    # --- 3. FSInfo sector ---
    fsinfo = bytearray(SECTOR_SIZE)
    struct.pack_into("<I480sI4s", fsinfo, 0,
        0x41615252,
        b"\x00" * 480,
        0x61417272,
        b"\x00\x00\x00\x00",
    )
    struct.pack_into("<II", fsinfo, 488, 0xFFFFFFFF, 0xFFFFFFFF)
    struct.pack_into("<I", fsinfo, 508, 0xAA550000)
    write_sector(part_lba + fsinfo_sec, bytes(fsinfo))

    # --- 4. Allocate clusters for files and root directory ---
    fat_entries: Dict[int, int] = {
        0: 0x0FFFFFF8,
        1: EOC_32,
        root_clus: EOC_32,
    }
    cluster_data: Dict[int, bytearray] = {
        root_clus: bytearray(sec_per_clus * SECTOR_SIZE),
    }
    next_clus = root_clus + 1
    cluster_bytes = sec_per_clus * SECTOR_SIZE

    dir_entries: List[bytes] = []

    # Volume label entry
    vol_entry = bytearray(32)
    vol_entry[0:11] = volume_label.encode("ascii")[:11].ljust(11, b" ")
    vol_entry[11] = 0x08  # ATTR_VOLUME_ID
    dir_entries.append(bytes(vol_entry))

    files = sorted(
        [p for p in src_dir.iterdir() if p.is_file() and not p.name.startswith(".")],
        key=lambda p: p.name.upper(),
    )

    for file_path in files:
        data = file_path.read_bytes()
        file_size = len(data)
        num_clus = max(1, (file_size + cluster_bytes - 1) // cluster_bytes)

        first_clus = next_clus
        for idx in range(num_clus):
            c = next_clus
            next_clus += 1
            if c >= total_clusters + 2:
                raise RuntimeError(f"Out of FAT32 clusters while adding {file_path.name}")

            chunk = data[idx * cluster_bytes : (idx + 1) * cluster_bytes]
            buf = bytearray(cluster_bytes)
            buf[: len(chunk)] = chunk
            cluster_data[c] = buf

            if idx + 1 < num_clus:
                fat_entries[c] = c + 1
            else:
                fat_entries[c] = EOC_32

        # 32-byte FAT directory entry (ATTR_ARCHIVE = 0x20)
        entry = bytearray(32)
        entry[0:11] = to_83_name(file_path.name)
        entry[11] = 0x20
        struct.pack_into("<H", entry, 20, (first_clus >> 16) & 0xFFFF)  # FstClusHI
        struct.pack_into("<H", entry, 26, first_clus & 0xFFFF)         # FstClusLO
        struct.pack_into("<I", entry, 28, file_size)                    # FileSize
        dir_entries.append(bytes(entry))

    # Pack directory entries into root cluster chain
    packed_dir = b"".join(dir_entries)
    dir_clus_count = max(1, (len(packed_dir) + cluster_bytes - 1) // cluster_bytes)
    cur_c = root_clus
    for d_idx in range(dir_clus_count):
        if d_idx > 0:
            new_c = next_clus
            next_clus += 1
            cluster_data[new_c] = bytearray(cluster_bytes)
            fat_entries[cur_c] = new_c
            fat_entries[new_c] = EOC_32
            cur_c = new_c
        chunk = packed_dir[d_idx * cluster_bytes : (d_idx + 1) * cluster_bytes]
        cluster_data[cur_c][: len(chunk)] = chunk

    # --- 5. Write FAT tables ---
    fat_bytes = bytearray(fat_size_32 * SECTOR_SIZE)
    for clus, val in fat_entries.items():
        offset = clus * 4
        if offset + 4 <= len(fat_bytes):
            struct.pack_into("<I", fat_bytes, offset, val & 0x0FFFFFFF)

    fat_start_lba = part_lba + rsvd_secs
    for f_idx in range(num_fats):
        f_lba = fat_start_lba + (f_idx * fat_size_32)
        for s_idx in range(fat_size_32):
            sec_slice = fat_bytes[s_idx * SECTOR_SIZE : (s_idx + 1) * SECTOR_SIZE]
            write_sector(f_lba + s_idx, sec_slice)

    # --- 6. Write data region ---
    data_start_lba = fat_start_lba + (num_fats * fat_size_32)
    for clus, buf in cluster_data.items():
        clus_lba = data_start_lba + ((clus - 2) * sec_per_clus)
        for s_idx in range(sec_per_clus):
            sec_slice = buf[s_idx * SECTOR_SIZE : (s_idx + 1) * SECTOR_SIZE]
            write_sector(clus_lba + s_idx, sec_slice)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(img)
    print(f"Wrote FAT32 image '{out_path}' ({len(img)} bytes, {len(files)} files, part_lba={part_lba}, spc={sec_per_clus})")


def main() -> int:
    parser = argparse.ArgumentParser(description="Create a FAT32 SD image from a directory")
    parser.add_argument("source_dir", type=Path, help="Directory whose files will populate the FAT32 image")
    parser.add_argument("-o", "--output", type=Path, required=True, help="Output SD image path (.img)")
    parser.add_argument("--size-mb", type=int, default=16, help="Total SD image size in MiB (default: 16)")
    parser.add_argument("--spc", type=int, default=1, help="Sectors per cluster, power of 2 (default: 1)")
    parser.add_argument("--part-lba", type=int, default=2048, help="Partition start LBA (default: 2048)")
    parser.add_argument("--rsvd-secs", type=int, default=32, help="Reserved sectors (default: 32)")
    parser.add_argument("--fats", type=int, default=2, help="Number of FATs (default: 2)")
    parser.add_argument("--label", type=str, default="MR4_FAT32", help="Volume label (up to 11 chars)")
    args = parser.parse_args()

    if not args.source_dir.is_dir():
        print(f"Error: source directory '{args.source_dir}' does not exist.", file=sys.stderr)
        return 1

    build_fat32_image(
        src_dir=args.source_dir,
        out_path=args.output,
        size_mb=args.size_mb,
        sec_per_clus=args.spc,
        part_lba=args.part_lba,
        rsvd_secs=args.rsvd_secs,
        num_fats=args.fats,
        volume_label=args.label,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
