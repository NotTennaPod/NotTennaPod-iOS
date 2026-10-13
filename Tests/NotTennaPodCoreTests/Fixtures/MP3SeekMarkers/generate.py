#!/usr/bin/env python3
"""Generates the MP3 seek-admission marker fixtures (MPEG-1, 2 and 2.5 layer III).

Usage: generate.py <ffmpeg> <empty output directory>
Refuses to replace existing files. Each file is six seconds of a synthetic,
non-periodic signal: a slow chirp plus low-passed noise from a fixed seed, so
any 50 ms of decoded audio occurs only once. Stereo files carry different
chirps on the left and right. The manifest records every command, hash and
the MPEG frame facts the tests rely on (frame size, encoder delay, frames that
borrow from the bit reservoir).
"""
import hashlib, json, math, os, random, struct, subprocess, sys, tempfile, wave

SECONDS = 6.0
FILES = [
    # name, rate, channels, encoder options
    ("marker-8k-mono.mp3", 8000, 1, ["-b:a", "16k"]),
    ("marker-16k-mono.mp3", 16000, 1, ["-b:a", "32k"]),
    ("marker-22k-stereo-vbr.mp3", 22050, 2, ["-q:a", "8"]),
    ("marker-44k-stereo-vbr.mp3", 44100, 2, ["-q:a", "7"]),
    ("marker-48k-mono.mp3", 48000, 1, ["-b:a", "64k"]),
]

def synthesize(path, rate, channels, seed):
    rng = random.Random(seed)
    frames = int(SECONDS * rate)
    low = [0.0] * channels
    alpha = math.exp(-2 * math.pi * min(1500.0, rate / 5) / rate)
    data = bytearray()
    for n in range(frames):
        t = n / rate
        for c in range(channels):
            # Left rises from 300 Hz, right falls from 1200 Hz (stays below rate / 4).
            f0, slope = (300.0, 60.0) if c == 0 else (min(1200.0, rate / 4 - 400), -60.0)
            phase = 2 * math.pi * (f0 * t + slope * t * t / 2)
            low[c] = alpha * low[c] + (1 - alpha) * rng.gauss(0, 1)
            value = 0.35 * math.sin(phase) + 0.6 * low[c]
            data += struct.pack("<h", max(-32767, min(32767, int(value * 32767))))
    with wave.open(path, "wb") as out:
        out.setnchannels(channels); out.setsampwidth(2); out.setframerate(rate); out.writeframes(bytes(data))

def frames(data):
    """Walks MPEG audio frames after an optional ID3v2 tag."""
    offset = 0
    if data[:3] == b"ID3":
        offset = 10 + ((data[6] << 21) | (data[7] << 14) | (data[8] << 7) | data[9])
    result = []
    while offset + 4 <= len(data):
        header = struct.unpack(">I", data[offset:offset + 4])[0]
        assert header & 0xFFE00000 == 0xFFE00000, f"lost sync at {offset}"
        version = (header >> 19) & 3
        assert version != 1 and (header >> 17) & 3 == 1
        rate = [44100, 48000, 32000][(header >> 10) & 3] // {3: 1, 2: 2, 0: 4}[version]
        index = (header >> 12) & 15
        table = ([32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320] if version == 3
                 else [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160])
        size = (144 if version == 3 else 72) * table[index - 1] * 1000 // rate + ((header >> 9) & 1)
        mono = (header >> 6) & 3 == 3
        side = offset + 4 + (0 if (header >> 16) & 1 else 2)
        bits = struct.unpack(">H", data[side:side + 2])[0]
        main_data_begin = bits >> 7 if version == 3 else bits >> 8
        result.append({"offset": offset, "size": size, "rate": rate, "mono": mono,
                       "samples": 1152 if version == 3 else 576, "mainDataBegin": main_data_begin})
        offset += size
    assert offset == len(data), "trailing bytes"
    return result

def lame(data, first):
    """Encoder delay and padding from the Xing/Info frame's LAME extension."""
    start = first["offset"]
    frame = data[start:start + first["size"]]
    for marker in (b"Xing", b"Info"):
        position = frame.find(marker)
        if position >= 0:
            break
    else:
        return None
    flags = struct.unpack(">I", frame[position + 4:position + 8])[0]
    cursor = position + 8 + (4 if flags & 1 else 0) + (4 if flags & 2 else 0) + (100 if flags & 4 else 0) + (4 if flags & 8 else 0)
    packed = frame[cursor + 21] << 16 | frame[cursor + 22] << 8 | frame[cursor + 23]
    return {"marker": marker.decode(), "hasTable": bool(flags & 4), "encoderDelay": packed >> 12, "encoderPadding": packed & 4095}

def main():
    ffmpeg, output = sys.argv[1], sys.argv[2]
    os.makedirs(output, exist_ok=True)
    version = subprocess.run([ffmpeg, "-version"], capture_output=True, text=True, check=True).stdout.splitlines()[0]
    manifest = {"source": "synthetic chirp plus seeded low-passed noise; no recordings", "seconds": SECONDS,
                "ffmpeg": version, "files": []}
    with tempfile.TemporaryDirectory() as scratch:
        for seed, (name, rate, channels, options) in enumerate(FILES, start=1):
            destination = os.path.join(output, name)
            if os.path.exists(destination):
                sys.exit(f"refusing to replace {destination}")
            source = os.path.join(scratch, name + ".wav")
            synthesize(source, rate, channels, seed)
            arguments = ["-map_metadata", "-1", "-fflags", "+bitexact", "-flags:a", "+bitexact",
                         "-c:a", "libmp3lame"] + options
            subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-i", source] + arguments + [destination], check=True)
            data = open(destination, "rb").read()
            parsed = frames(data)
            audio = parsed[1:]  # The first frame is the Xing/Info header.
            info = lame(data, parsed[0])
            borrowing = sum(1 for frame in audio if frame["mainDataBegin"] > 0)
            manifest["files"].append({
                "name": name, "sha256": hashlib.sha256(data).hexdigest(), "seed": seed,
                "sampleRate": rate, "channels": channels, "arguments": arguments,
                "framesPerPacket": parsed[0]["samples"], "audioFrames": len(audio), "header": info,
                "framesUsingReservoir": borrowing})
    with open(os.path.join(output, "manifest.json"), "w") as out:
        json.dump(manifest, out, indent=2)
        out.write("\n")

if __name__ == "__main__":
    main()
