#!/usr/bin/env python3
"""Writes a deterministic speech-like signal: formant-synthesized syllables, no recording and no voice.

Usage: generate_speech.py <output.raw>

The output is 53.7 s of 44.1 kHz stereo signed 16-bit little-endian PCM with identical channels,
the input of make-speech-fixtures.sh. Everything comes from this file and a fixed seed:

- seven phrases separated by pauses of 0.6 to 8.3 s (the phrase lengths and pauses of a read
  podcast intro); within a phrase, words of one to three syllables with short gaps between them
  and the occasional comma-length pause;
- each syllable is an optional consonant and a vowel. Plosives are a short noise burst, fricatives
  band-limited noise, sonorants a quieter voiced onset with low formants; some syllables end in a
  short unvoiced release;
- vowels are a glottal-flow pulse train (Rosenberg pulse) at a fundamental of about 100-190 Hz that
  falls across each phrase, rises on stressed syllables, wavers and jitters from period to period,
  with some breath noise, through five cascaded formant resonators; the first three glide towards
  one of seven vowel targets;
- a quiet seeded room-noise floor everywhere, about -66 dBFS.

The level is set to an RMS of -20 dBFS over the whole signal; a soft limiter keeps peaks at or
below -2 dBFS. The fundamental keeps moving, so no harmonic stays on one frequency: the script
checks that no 50 ms window has more than 60 % of its power at 440 or 660 Hz, the frequencies of
the fixtures' tone ads. Pure Python (standard library only), so the same Python gives the same bytes.
"""
import array
import cmath
import hashlib
import math
import random
import sys

RATE = 44100
SECONDS = 53.7
SEED = 20261011
# (start, length) of each phrase in seconds; the gaps between them are the pauses.
PHRASES = [(0.03, 5.45), (6.08, 3.67), (11.15, 4.60), (18.95, 5.16), (32.35, 5.54), (38.74, 5.07), (46.09, 7.38)]
# Vowel formant targets F1-F3 (Hz): roughly i, e, a, o, u, schwa and ae of an adult voice.
VOWELS = [(280, 2250, 2900), (420, 2000, 2600), (750, 1250, 2500), (520, 900, 2400),
          (330, 920, 2300), (500, 1500, 2500), (700, 1750, 2450)]
BANDWIDTHS = (85, 110, 150)
HIGHER = ((3300, 250), (3850, 300))  # F4 and F5, fixed
# Consonant noise relative to the vowels' RMS.
FRICATIVE_LEVEL = 0.6
PLOSIVE_LEVEL = 0.9
RELEASE_LEVEL = 0.3
NOISE_DBFS = -66.0
TARGET_RMS_DBFS = -20.0
CEILING_DBFS = -2.0


class Resonator:
    """Klatt's two-pole digital resonator: y = a x + b y1 + c y2 (unity gain at 0 Hz)."""
    def __init__(self):
        self.y1 = self.y2 = 0.0
        self.a = self.b = self.c = 0.0

    def tune(self, frequency, bandwidth):
        r = math.exp(-math.pi * bandwidth / RATE)
        self.c = -r * r
        self.b = 2 * r * math.cos(2 * math.pi * frequency / RATE)
        self.a = 1 - self.b - self.c

    def gain(self, frequency):
        z = cmath.exp(-2j * math.pi * frequency / RATE)
        return abs(self.a / (1 - self.b * z - self.c * z * z))

    def step(self, x):
        y = self.a * x + self.b * self.y1 + self.c * self.y2
        self.y2 = self.y1
        self.y1 = y
        return y


def raised(position, length):
    """0 to 1 over `length` samples (a raised cosine)."""
    return 0.5 - 0.5 * math.cos(math.pi * min(1.0, max(0.0, position / length)))


def plan(rng):
    """Every syllable: (vowel start s, vowel s, vowel, stressed, onset, onset s, release, phrase start, phrase end)."""
    syllables = []
    for start, length in PHRASES:
        end = start + length
        t = start
        first = True
        while True:
            count = rng.choices([1, 2, 3], weights=[5, 4, 2])[0]
            stress = rng.randrange(count)
            word = []
            for index in range(count):
                onset = rng.choices(["none", "plosive", "fricative", "sonorant"], weights=[3, 3, 3, 2])[0]
                onset_seconds = {"none": 0.0, "plosive": rng.uniform(0.03, 0.05),
                                 "fricative": rng.uniform(0.06, 0.11), "sonorant": rng.uniform(0.04, 0.07)}[onset]
                vowel_seconds = rng.uniform(0.15, 0.26) if index == stress else rng.uniform(0.09, 0.15)
                release = rng.random() < 0.3
                word.append((onset, onset_seconds, vowel_seconds, rng.randrange(len(VOWELS)), index == stress, release))
            seconds = sum(o + v + (0.05 if r else 0) + 0.005 for _, o, v, _, _, r in word)
            if not first and t + seconds > end:
                break
            for onset, onset_seconds, vowel_seconds, vowel, stressed, release in word:
                syllables.append((t + onset_seconds, vowel_seconds, vowel, stressed, onset, onset_seconds, release, start, end))
                t += onset_seconds + vowel_seconds + (0.05 if release else 0) + 0.005
            t += rng.uniform(0.02, 0.07) + (rng.uniform(0.12, 0.25) if rng.random() < 0.08 else 0)
            first = False
    return syllables


def band_noise(rng, track, first, length, centre, bandwidth, level, shape):
    """Adds band-limited noise (unit gain at `centre`) with an envelope to `track`."""
    shaper = Resonator()
    shaper.tune(centre, bandwidth)
    scale = level / shaper.gain(centre)
    for n in range(length):
        value = shaper.step(rng.gauss(0, 1))
        if 0 <= first + n < len(track):
            track[first + n] += scale * shape(n, length) * value


def synthesize(rng):
    """The voiced and the unvoiced parts, as two tracks."""
    total = int(SECONDS * RATE)
    voiced = [0.0] * total
    unvoiced = [0.0] * total
    previous = VOWELS[5]
    for vowel_start, vowel_seconds, vowel, stressed, onset, onset_seconds, release, phrase_start, phrase_end in plan(rng):
        gain = rng.uniform(0.85, 1.0) if stressed else rng.uniform(0.5, 0.72)
        begin = int(vowel_start * RATE)
        if onset == "fricative":
            first = int((vowel_start - onset_seconds) * RATE)
            centre = rng.uniform(3000, 8000)
            band_noise(rng, unvoiced, first, begin - first, centre, 0.5 * centre, gain * FRICATIVE_LEVEL,
                       lambda n, length: raised(n, 0.3 * length) * raised(length - n, 0.25 * length))
        elif onset == "plosive":
            first = int((vowel_start - onset_seconds) * RATE)
            centre = rng.uniform(1200, 4000)
            band_noise(rng, unvoiced, first, begin - first, centre, 0.8 * centre, gain * PLOSIVE_LEVEL,
                       lambda n, length: raised(n, 0.001 * RATE) * (math.exp(-n / (0.008 * RATE)) + 0.3 * raised(n, length)))
        # The voiced part (a sonorant onset is voiced too, quieter and with low formants).
        voiced_start = begin - (int(onset_seconds * RATE) if onset == "sonorant" else 0)
        length = int(vowel_seconds * RATE) + (begin - voiced_start)
        target = VOWELS[vowel]
        start_formants = (300, 1100, 2400) if onset == "sonorant" else tuple(
            p + 0.35 * (t - p) for p, t in zip(previous, target))
        resonators = [Resonator() for _ in range(5)]
        for r, (frequency, bandwidth) in zip(resonators[3:], HIGHER):
            r.tune(frequency, bandwidth)
        flow_before = 0.0
        phase = rng.random()
        jitter = 1.0
        waver = rng.uniform(0, 2 * math.pi)
        for n in range(length):
            if n % 64 == 0:
                glide = raised(n, 0.45 * length)
                for r, a, b, w in zip(resonators, start_formants, target, BANDWIDTHS):
                    r.tune(a + (b - a) * glide, w)
            seconds = (voiced_start + n) / RATE
            along = (seconds - phrase_start) / (phrase_end - phrase_start)
            f0 = 168 - 52 * along
            if stressed:
                f0 += 26 * math.sin(math.pi * n / length)
            f0 *= jitter * (1 + 0.04 * math.sin(2 * math.pi * 4.7 * seconds + waver))
            phase += f0 / RATE
            if phase >= 1.0:
                phase -= 1.0
                jitter = 1 + 0.012 * rng.gauss(0, 1)
            if phase < 0.45:
                flow = 0.5 - 0.5 * math.cos(math.pi * phase / 0.45)
            elif phase < 0.52:
                flow = math.cos(0.5 * math.pi * (phase - 0.45) / 0.07)
            else:
                flow = 0.0
            excitation = (flow - flow_before) + 0.02 * flow * rng.gauss(0, 1)
            flow_before = flow
            y = excitation
            for r in resonators:
                y = r.step(y)
            envelope = raised(n, 0.025 * RATE) * raised(length - n, 0.05 * RATE)
            if onset == "sonorant" and n < begin - voiced_start:
                envelope *= 0.45
            index = voiced_start + n
            if 0 <= index < total:
                voiced[index] += gain * envelope * y
        previous = target
        if release:
            centre = rng.uniform(3000, 6000)
            band_noise(rng, unvoiced, begin + int(vowel_seconds * RATE), int(0.05 * RATE), centre, 0.6 * centre,
                       gain * RELEASE_LEVEL, lambda n, length: raised(length - n, length))
    return voiced, unvoiced


def level(values):
    return 20 * math.log10(math.sqrt(sum(v * v for v in values) / len(values)))


def share(values, frequency):
    """Goertzel: the share of the window's power at one frequency."""
    coefficient = 2 * math.cos(2 * math.pi * frequency / RATE)
    previous = before = 0.0
    total = 0.0
    for x in values:
        total += x * x
        current = x + coefficient * previous - before
        before = previous
        previous = current
    power = previous * previous + before * before - coefficient * previous * before
    return 2 * power / (len(values) * total) if total > 0 else 0.0


def main():
    rng = random.Random(SEED)
    voiced, unvoiced = synthesize(rng)
    sounding = [v for v in voiced if v != 0.0]
    vowel_rms = math.sqrt(sum(v * v for v in sounding) / len(sounding))
    speech = [v + vowel_rms * u for v, u in zip(voiced, unvoiced)]
    # The room-noise floor, then the speech scaled so the whole signal has the target RMS.
    noise_rng = random.Random(SEED + 1)
    noise, smoothed = [], 0.0
    for _ in speech:
        smoothed += 0.3 * (noise_rng.gauss(0, 1) - smoothed)
        noise.append(smoothed)
    noise_gain = 10 ** (NOISE_DBFS / 20) / math.sqrt(sum(v * v for v in noise) / len(noise))
    noise = [v * noise_gain for v in noise]
    speech_power = sum(v * v for v in speech) / len(speech)
    noise_power = sum(v * v for v in noise) / len(noise)
    gain = math.sqrt((10 ** (TARGET_RMS_DBFS / 10) - noise_power) / speech_power)
    ceiling = 10 ** (CEILING_DBFS / 20)
    knee = 0.75 * ceiling
    mixed = []
    for s, w in zip(speech, noise):
        x = gain * s + w
        magnitude = abs(x)
        if magnitude > knee:
            magnitude = knee + (ceiling - knee) * math.tanh((magnitude - knee) / (ceiling - knee))
            x = math.copysign(magnitude, x)
        mixed.append(x)
    samples = array.array("h")
    for x in mixed:
        value = max(-32768, min(32767, round(x * 32768)))
        samples.append(value)
        samples.append(value)
    if sys.byteorder != "little":
        samples.byteswap()
    data = samples.tobytes()
    with open(sys.argv[1], "wb") as out:
        out.write(data)
    window = int(0.05 * RATE)
    worst = max(share(mixed[i:i + window], f) for f in (440, 660) for i in range(0, len(mixed) - window, window))
    peak = 20 * math.log10(max(abs(v) for v in mixed))
    print(f"{len(mixed) / RATE:.2f} s, RMS {level(mixed):.2f} dBFS, peak {peak:.2f} dBFS, "
          f"0-10 s {level(mixed[:10 * RATE]):.2f}, 10-20 s {level(mixed[10 * RATE:20 * RATE]):.2f} dBFS, "
          f"largest 50 ms share at 440/660 Hz {worst:.3f}, sha256 {hashlib.sha256(data).hexdigest()}")
    assert worst < 0.6, "the speech holds a steady tone at an ad frequency"


if __name__ == "__main__":
    main()
