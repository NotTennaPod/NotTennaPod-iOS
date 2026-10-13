#!/usr/bin/env python3
"""Generates MP3s whose format changes mid-file, like a show with an inserted ad.

Usage: generate.py <ffmpeg> <empty output directory> [speech fixture directory]
converted-chain.mp3 joins six segments in five formats, four converted in a row, each
carrying 2 kHz marker bursts near its start and its end over seeded low-level noise.
Refuses to replace existing files. Each file is three independently encoded
MP3 streams (libmp3lame, no Xing/Info frame) joined end to end, the way
dynamic ad insertion splices an ad into a show. Every segment and channel
carries its own tone (so pitch and channel identity can be checked), shaped
by a slow envelope plus seeded low-level noise (so positions can be located).
The manifest records commands, hashes, and for each segment its byte range,
MPEG frame count, frame size, rate, channels and tones.

With a speech fixture directory (the output of ../SyntheticSpeech/make-speech-fixtures.sh),
its three spliced shows are copied unchanged (dai_mono.mp3, dai_48k.mp3,
dai_monoshow_stereoad.mp3: 10 s of synthetic speech, a 5 s tone ad, 10 s of speech)
and their segments are recorded from their frame headers.
"""
import hashlib, json, math, os, random, struct, subprocess, sys, tempfile, wave

FILES = {
    # Stereo show, mono ad, stereo show (all 44.1 kHz): the ad must reach both channels.
    "stereo-mono-stereo.mp3": [(44100, [300, 700], 2.0, "128k"), (44100, [1000], 1.5, "64k"), (44100, [450, 900], 2.0, "128k")],
    # Mono show, stereo ad with different left and right content: both reach the one channel.
    "mono-stereo-mono.mp3": [(44100, [500], 2.0, "64k"), (44100, [1200, 2400], 1.5, "128k"), (44100, [500], 2.0, "64k")],
    # Low rate show (MPEG-2, 576-sample frames), high rate ad (MPEG-1, 1152).
    "low-high-low.mp3": [(22050, [800], 2.0, "48k"), (48000, [1500], 1.5, "96k"), (22050, [800], 2.0, "48k")],
    # High rate stereo show, low rate mono ad.
    "high-low-high.mp3": [(48000, [600, 1100], 2.0, "128k"), (16000, [900], 1.5, "32k"), (48000, [600, 1100], 2.0, "128k")],
}
# Consecutive converted segments, each quiet but for two short 2 kHz bursts (markers): one
# 60 ms after its start and one 40 ms before its end, so the position of every segment's
# content, including its last moments, can be measured. Channels list "marker" per channel.
MARKERS = (0.06, -0.04)
CHAINS = {
    "converted-chain.mp3": [(44100, 2, 0.6, "128k"), (48000, 2, 0.35, "128k"), (48000, 1, 0.35, "64k"),
                            (22050, 1, 0.35, "48k"), (16000, 1, 0.3, "32k"), (44100, 2, 0.6, "128k")],
}

def synthesize_markers(path, rate, channels, seconds, seed):
    rng = random.Random(seed)
    frames = int(seconds * rate)
    centres = [int((at if at > 0 else seconds + at) * rate) for at in MARKERS]
    half = int(0.002 * rate)
    data = bytearray()
    for n in range(frames):
        burst = 0.0
        for centre in centres:
            if abs(n - centre) < half:
                window = 0.5 + 0.5 * math.cos(math.pi * (n - centre) / half)
                burst += 0.6 * window * math.sin(2 * math.pi * 2000 * (n - centre) / rate)
        for _ in range(channels):
            value = burst + 0.005 * rng.gauss(0, 1)
            data += struct.pack("<h", max(-32767, min(32767, int(value * 32767))))
    with wave.open(path, "wb") as out:
        out.setnchannels(channels); out.setsampwidth(2); out.setframerate(rate); out.writeframes(bytes(data))

def synthesize(path, rate, tones, seconds, seed):
    rng = random.Random(seed)
    frames = int(seconds * rate)
    data = bytearray()
    for n in range(frames):
        t = n / rate
        for c, hz in enumerate(tones):
            envelope = 0.6 + 0.4 * math.sin(2 * math.pi * 0.7 * t + c)
            value = 0.4 * envelope * math.sin(2 * math.pi * hz * t) + 0.03 * rng.gauss(0, 1)
            data += struct.pack("<h", max(-32767, min(32767, int(value * 32767))))
    with wave.open(path, "wb") as out:
        out.setnchannels(len(tones)); out.setsampwidth(2); out.setframerate(rate); out.writeframes(bytes(data))

# The spliced shows' ads: a -6 dB sine (frequency, rate, channels); the speech around them is 44.1 kHz.
SPEECH = {"dai_mono.mp3": (440, 44100, 1), "dai_48k.mp3": (660, 48000, 2), "dai_monoshow_stereoad.mp3": (440, 44100, 2)}

def frames(data):
    result, offset = [], 0
    while offset + 4 <= len(data):
        header = struct.unpack(">I", data[offset:offset + 4])[0]
        assert header & 0xFFE00000 == 0xFFE00000, f"lost sync at {offset}"
        version = (header >> 19) & 3
        rate = [44100, 48000, 32000][(header >> 10) & 3] // {3: 1, 2: 2, 0: 4}[version]
        index = (header >> 12) & 15
        table = ([32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320] if version == 3
                 else [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160])
        size = (144 if version == 3 else 72) * table[index - 1] * 1000 // rate + ((header >> 9) & 1)
        result.append({"rate": rate, "channels": 1 if (header >> 6) & 3 == 3 else 2,
                       "samples": 1152 if version == 3 else 576, "offset": offset, "size": size})
        offset += size
    assert offset == len(data)
    return result

def main():
    ffmpeg, output = sys.argv[1], sys.argv[2]
    os.makedirs(output, exist_ok=True)
    version = subprocess.run([ffmpeg, "-version"], capture_output=True, text=True, check=True).stdout.splitlines()[0]
    manifest = {"source": "synthetic tones with a slow envelope and seeded noise; no recordings",
                "ffmpeg": version, "files": []}
    seed = 100
    with tempfile.TemporaryDirectory() as scratch:
        for name, segments in list(FILES.items()) + list(CHAINS.items()):
            destination = os.path.join(output, name)
            if os.path.exists(destination):
                sys.exit(f"refusing to replace {destination}")
            joined, described = b"", []
            for rate, content, seconds, bitrate in segments:
                seed += 1
                source = os.path.join(scratch, f"{seed}.wav")
                encoded = os.path.join(scratch, f"{seed}.mp3")
                if name in CHAINS:
                    synthesize_markers(source, rate, content, seconds, seed)
                    tones = []
                else:
                    synthesize(source, rate, content, seconds, seed)
                    tones = content
                arguments = ["-map_metadata", "-1", "-fflags", "+bitexact", "-flags:a", "+bitexact",
                             "-c:a", "libmp3lame", "-b:a", bitrate, "-write_xing", "0", "-id3v2_version", "0"]
                subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-i", source] + arguments + [encoded], check=True)
                data = open(encoded, "rb").read()
                parsed = frames(data)
                channels = content if name in CHAINS else len(content)
                assert all(f["rate"] == rate and f["channels"] == channels for f in parsed)
                described.append({"byteOffset": len(joined), "byteCount": len(data), "sampleRate": rate,
                                  "channels": channels, "tonesHz": tones, "seconds": seconds, "seed": seed,
                                  "markersSeconds": [at if at > 0 else seconds + at for at in MARKERS] if name in CHAINS else [],
                                  "mpegFrames": len(parsed), "framesPerPacket": parsed[0]["samples"],
                                  "arguments": arguments})
                joined += data
            with open(destination, "wb") as out:
                out.write(joined)
            manifest["files"].append({"name": name, "sha256": hashlib.sha256(joined).hexdigest(), "segments": described})
    if len(sys.argv) > 3:
        for name, (tone, ad_rate, ad_channels) in SPEECH.items():
            destination = os.path.join(output, name)
            if os.path.exists(destination):
                sys.exit(f"refusing to replace {destination}")
            data = open(os.path.join(sys.argv[3], name), "rb").read()
            runs = []
            for frame in frames(data):
                key = (frame["rate"], frame["channels"], frame["samples"])
                if runs and runs[-1]["key"] == key:
                    runs[-1]["mpegFrames"] += 1; runs[-1]["byteCount"] += frame["size"]
                else:
                    runs.append({"key": key, "byteOffset": frame["offset"], "byteCount": frame["size"], "mpegFrames": 1})
            described = []
            for run in runs:
                rate, channels, samples = run.pop("key")
                ad = (rate, channels) == (ad_rate, ad_channels) and len(described) == 1
                described.append({"byteOffset": run["byteOffset"], "byteCount": run["byteCount"], "sampleRate": rate,
                                  "channels": channels, "tonesHz": [tone] * channels if ad else [],
                                  "mpegFrames": run["mpegFrames"], "framesPerPacket": samples})
            with open(destination, "wb") as out:
                out.write(data)
            manifest["files"].append({"name": name, "sha256": hashlib.sha256(data).hexdigest(),
                                      "source": "SyntheticSpeech/make-speech-fixtures.sh, unchanged", "segments": described})
    with open(os.path.join(output, "manifest.json"), "w") as out:
        json.dump(manifest, out, indent=2)
        out.write("\n")

if __name__ == "__main__":
    main()
