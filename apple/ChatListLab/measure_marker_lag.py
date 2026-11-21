#!/usr/bin/env python3
"""Measure the gap between the lab's keyboard and list markers in a screen recording.

Each decoded frame gives the lowest row of the green bar (left half) and the magenta
bar (right half). While the keyboard moves, any gap between them is visible lag.
"""
import shutil
import subprocess
import sys


def read_size(path):
    out = subprocess.check_output([
        "ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height,avg_frame_rate", "-of", "csv=p=0", path,
    ], text=True).strip().split(",")
    return int(out[0]), int(out[1]), out[2]


def bottom_row(frame, width, height, x_range, matches):
    """The lowest row where most sampled pixels match, or None."""
    columns = range(x_range[0] + 8, x_range[1] - 8, 16)
    for y in range(height - 1, -1, -1):
        hits = 0
        row = y * width * 3
        for x in columns:
            i = row + x * 3
            if matches(frame[i], frame[i + 1], frame[i + 2]):
                hits += 1
        if hits * 2 > len(columns):
            return y
    return None


def main():
    if len(sys.argv) != 2 or shutil.which("ffmpeg") is None:
        sys.exit("usage: measure_marker_lag.py <recording.mp4> (needs ffmpeg)")
    path = sys.argv[1]
    width, height, rate = read_size(path)
    # Half size is plenty for a 6 pt bar and keeps a pure-Python scan quick.
    width, height = width // 2, height // 2
    decoder = subprocess.Popen([
        "ffmpeg", "-v", "error", "-i", path, "-vf", f"scale={width}:{height}:flags=neighbor",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-",
    ], stdout=subprocess.PIPE)
    size = width * height * 3
    green = lambda r, g, b: g > 180 and r < 110 and b < 110
    magenta = lambda r, g, b: r > 180 and b > 180 and g < 110
    samples = []
    while True:
        frame = decoder.stdout.read(size)
        if len(frame) < size:
            break
        samples.append((
            bottom_row(frame, width, height, (0, width // 2), green),
            bottom_row(frame, width, height, (width // 2, width), magenta),
        ))
    decoder.wait()
    # Pixels in the half-size frame, reported in full-frame pixels.
    moving = []
    previous = None
    for keyboard, list_edge in samples:
        if keyboard is not None and list_edge is not None:
            if previous is not None and previous != keyboard:
                moving.append(2 * (list_edge - keyboard))
            previous = keyboard
    resting = [2 * (l - k) for k, l in samples if k is not None and l is not None]
    print(f"frames {len(samples)} at {rate} fps, {width * 2}x{height * 2}")
    print(f"both markers visible: {len(resting)}, keyboard moving: {len(moving)}")
    if moving:
        ordered = sorted(abs(v) for v in moving)
        print("gap while moving, full-frame px (list minus keyboard):")
        print(f"  mean {sum(moving) / len(moving):.1f}  median |gap| {ordered[len(ordered) // 2]}"
              f"  p95 |gap| {ordered[int(len(ordered) * 0.95)]}  max |gap| {ordered[-1]}")
        print(f"  values {moving}")
    if resting:
        ordered = sorted(resting)
        print(f"gap at any time: median {ordered[len(ordered) // 2]}")


if __name__ == "__main__":
    main()
