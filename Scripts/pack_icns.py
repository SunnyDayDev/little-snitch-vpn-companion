#!/usr/bin/env python3
"""Complete Xcode's legacy ICNS fallback from an Apple .iconset directory.

Xcode's Icon Composer pipeline currently emits only a subset of sizes into the
legacy AppIcon.icns. Preserve its correctly encoded small chunks and add the
missing ictool-rendered PNG chunks deterministically.
"""

from __future__ import annotations

import os
from pathlib import Path
import struct
import sys
import tempfile
import zlib


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"

# Xcode already emits valid ic04/ic11/ic07/ic13 chunks for 16, 32, 128, and
# 256 physical pixels. ic04 uses Apple's legacy ARGB encoding, so retain it
# instead of replacing it with a PNG payload. These additions cover every
# physical size through 1024 and the remaining Retina representations.
ADDITIONAL_RENDITIONS = (
    ("icon_32x32.png", "ic05", 32, "argb"),
    ("icon_32x32@2x.png", "ic12", 64, "png"),
    ("icon_256x256.png", "ic08", 256, "png"),
    ("icon_256x256@2x.png", "ic14", 512, "png"),
    ("icon_512x512.png", "ic09", 512, "png"),
    ("icon_512x512@2x.png", "ic10", 1024, "png"),
)

REQUIRED_BASE_CHUNKS = ("ic04", "ic11", "ic07", "ic13")
OUTPUT_ORDER = (
    "ic04",
    "ic11",
    "ic05",
    "ic12",
    "ic07",
    "ic13",
    "ic08",
    "ic14",
    "ic09",
    "ic10",
)


def png_dimensions(data: bytes, path: Path) -> tuple[int, int]:
    if len(data) < 24 or data[:8] != PNG_SIGNATURE or data[12:16] != b"IHDR":
        raise ValueError(f"{path} is not a valid PNG with an IHDR header")
    return struct.unpack(">II", data[16:24])


def paeth(left: int, above: int, upper_left: int) -> int:
    estimate = left + above - upper_left
    left_distance = abs(estimate - left)
    above_distance = abs(estimate - above)
    upper_left_distance = abs(estimate - upper_left)
    if left_distance <= above_distance and left_distance <= upper_left_distance:
        return left
    if above_distance <= upper_left_distance:
        return above
    return upper_left


def decode_rgba_png(data: bytes, path: Path) -> bytes:
    width, height = png_dimensions(data, path)
    bit_depth, color_type, compression, filtering, interlace = data[24:29]
    if (bit_depth, color_type, compression, filtering, interlace) != (8, 6, 0, 0, 0):
        raise ValueError(f"{path} must be a non-interlaced 8-bit RGBA PNG")

    compressed = bytearray()
    offset = 8
    while offset < len(data):
        if offset + 12 > len(data):
            raise ValueError(f"{path} has a truncated PNG chunk")
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        chunk_end = offset + 12 + length
        if chunk_end > len(data):
            raise ValueError(f"{path} has an invalid PNG chunk length")
        if chunk_type == b"IDAT":
            compressed.extend(data[offset + 8 : offset + 8 + length])
        offset = chunk_end

    raw = zlib.decompress(compressed)
    stride = width * 4
    expected_length = height * (stride + 1)
    if len(raw) != expected_length:
        raise ValueError(f"{path} has an unexpected decompressed size")

    pixels = bytearray()
    previous = bytearray(stride)
    offset = 0
    for _ in range(height):
        filter_type = raw[offset]
        row = bytearray(raw[offset + 1 : offset + 1 + stride])
        offset += stride + 1
        for index, value in enumerate(row):
            left = row[index - 4] if index >= 4 else 0
            above = previous[index]
            upper_left = previous[index - 4] if index >= 4 else 0
            if filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = above
            elif filter_type == 3:
                predictor = (left + above) // 2
            elif filter_type == 4:
                predictor = paeth(left, above, upper_left)
            elif filter_type == 0:
                predictor = 0
            else:
                raise ValueError(f"{path} uses unsupported PNG filter {filter_type}")
            row[index] = (value + predictor) & 0xFF
        pixels.extend(row)
        previous = row
    return bytes(pixels)


def encode_rle(channel: bytes) -> bytes:
    encoded = bytearray()
    literals = bytearray()

    def flush_literals() -> None:
        while literals:
            count = min(len(literals), 128)
            encoded.append(count - 1)
            encoded.extend(literals[:count])
            del literals[:count]

    index = 0
    while index < len(channel):
        run_length = 1
        while (
            index + run_length < len(channel)
            and channel[index + run_length] == channel[index]
        ):
            run_length += 1

        if run_length >= 3:
            flush_literals()
            remaining = run_length
            while remaining >= 3:
                count = min(remaining, 130)
                encoded.extend((0x80 + count - 3, channel[index]))
                remaining -= count
            literals.extend(channel[index : index + remaining])
        else:
            literals.extend(channel[index : index + run_length])
        index += run_length

    flush_literals()
    return bytes(encoded)


def encode_argb(data: bytes, path: Path) -> bytes:
    rgba = decode_rgba_png(data, path)
    channels = (
        rgba[3::4],  # Alpha
        rgba[0::4],  # Red
        rgba[1::4],  # Green
        rgba[2::4],  # Blue
    )
    return b"ARGB" + b"".join(encode_rle(channel) for channel in channels)


def read_icns(path: Path) -> dict[str, bytes]:
    data = path.read_bytes()
    if len(data) < 8 or data[:4] != b"icns":
        raise ValueError(f"{path} is not an ICNS file")
    declared_size = struct.unpack(">I", data[4:8])[0]
    if declared_size != len(data):
        raise ValueError(f"{path} declares {declared_size} bytes but contains {len(data)}")

    chunks: dict[str, bytes] = {}
    offset = 8
    while offset < len(data):
        if offset + 8 > len(data):
            raise ValueError(f"{path} has a truncated chunk header")
        chunk_type = data[offset : offset + 4].decode("ascii")
        chunk_size = struct.unpack(">I", data[offset + 4 : offset + 8])[0]
        if chunk_size < 8 or offset + chunk_size > len(data):
            raise ValueError(f"{path} has an invalid {chunk_type} chunk")
        chunks[chunk_type] = data[offset : offset + chunk_size]
        offset += chunk_size
    return chunks


def build_icns(iconset: Path, base_icns: Path) -> bytes:
    chunks = read_icns(base_icns)
    missing = [chunk_type for chunk_type in REQUIRED_BASE_CHUNKS if chunk_type not in chunks]
    if missing:
        raise ValueError(f"{base_icns} is missing Xcode fallback chunks: {', '.join(missing)}")

    for filename, chunk_type, expected_size, encoding in ADDITIONAL_RENDITIONS:
        path = iconset / filename
        data = path.read_bytes()
        dimensions = png_dimensions(data, path)
        if dimensions != (expected_size, expected_size):
            raise ValueError(
                f"{path} is {dimensions[0]}x{dimensions[1]}, "
                f"expected {expected_size}x{expected_size}"
            )
        payload = encode_argb(data, path) if encoding == "argb" else data
        chunks[chunk_type] = chunk_type.encode("ascii") + struct.pack(
            ">I", len(payload) + 8
        ) + payload

    body = b"".join(chunks[chunk_type] for chunk_type in OUTPUT_ORDER)
    return b"icns" + struct.pack(">I", len(body) + 8) + body


def write_atomically(data: bytes, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.name}.", dir=destination.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
        temporary.replace(destination)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def main() -> int:
    if len(sys.argv) != 4:
        print(
            f"usage: {Path(sys.argv[0]).name} INPUT.iconset BASE.icns OUTPUT.icns",
            file=sys.stderr,
        )
        return 2

    iconset = Path(sys.argv[1])
    base_icns = Path(sys.argv[2])
    destination = Path(sys.argv[3])
    if not iconset.is_dir():
        print(f"error: iconset directory not found: {iconset}", file=sys.stderr)
        return 1

    try:
        write_atomically(build_icns(iconset, base_icns), destination)
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
