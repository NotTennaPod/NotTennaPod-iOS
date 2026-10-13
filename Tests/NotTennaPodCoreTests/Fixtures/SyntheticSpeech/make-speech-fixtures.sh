#!/bin/bash
# The seven fixtures with speech in them, made from generate_speech.py's synthetic speech (no recording,
# no system voice) with FFmpeg 9.0.2 (libmp3lame, FFmpeg's AAC encoder, libopus):
# - dai_mono.mp3, dai_48k.mp3, dai_monoshow_stereoad.mp3: 10 s of speech, a 5 s tone "ad", the next 10 s of
#   speech, MP3 streams without Xing frame or ID3 tag joined end to end (MP3FormatChanges/generate.py records
#   their segments);
# - dai_adts_mono.aac, dai_adts_48k.aac: the same as raw ADTS (PlaybackDecoder/);
# - surround.m4a, surround.opus: 20 s of 5.1 with the speech on the centre channel only and a quiet 220 Hz
#   tone on front left and right (Surround/).
# The ads are -6 dB sines: 440 Hz mono at 44.1 kHz, 660 Hz stereo at 48 kHz, 440 Hz stereo at 44.1 kHz.
# Usage: make-speech-fixtures.sh <empty output directory>
set -euo pipefail
out="$1"
here=$(cd "$(dirname "$0")" && pwd)
F=${FFMPEG:-ffmpeg}  # ffmpeg on PATH unless FFMPEG names another
Q=(-hide_banner -loglevel error -nostdin -n)
version=$("$F" -version | head -1)
[[ $version == "ffmpeg version 9.0.2 "* ]] || echo "warning: the fixtures were made with FFmpeg 9.0.2, not: $version" >&2
python3 -I "$here/generate_speech.py" "$out/speech.raw"
S=(-f s16le -ar 44100 -ac 2 -i "$out/speech.raw")
M=(-write_xing 0 -id3v2_version 0)
tone() { echo "sine=frequency=$1:sample_rate=$2:duration=5"; }

# MP3: a stereo show with a mono ad, and with a 48 kHz stereo ad.
"$F" "${Q[@]}" "${S[@]}" -t 10 -c:a libmp3lame -b:a 128k "${M[@]}" "$out/seg1.mp3"
"$F" "${Q[@]}" -f lavfi -i "$(tone 440 44100)" -af "volume=-6dB" -ac 1 -c:a libmp3lame -b:a 64k "${M[@]}" "$out/ad_mono.mp3"
"$F" "${Q[@]}" -f lavfi -i "$(tone 660 48000)" -af "volume=-6dB" -ac 2 -c:a libmp3lame -b:a 128k "${M[@]}" "$out/ad_48k.mp3"
"$F" "${Q[@]}" "${S[@]}" -ss 10 -t 10 -c:a libmp3lame -b:a 128k "${M[@]}" "$out/seg2.mp3"
cat "$out/seg1.mp3" "$out/ad_mono.mp3" "$out/seg2.mp3" > "$out/dai_mono.mp3"
cat "$out/seg1.mp3" "$out/ad_48k.mp3" "$out/seg2.mp3" > "$out/dai_48k.mp3"

# MP3: a mono show with a stereo ad.
"$F" "${Q[@]}" "${S[@]}" -t 10 -ac 1 -c:a libmp3lame -b:a 64k "${M[@]}" "$out/mseg1.mp3"
"$F" "${Q[@]}" -f lavfi -i "$(tone 440 44100)" -af "volume=-6dB" -ac 2 -c:a libmp3lame -b:a 128k "${M[@]}" "$out/ad_stereo.mp3"
"$F" "${Q[@]}" "${S[@]}" -ss 10 -t 10 -ac 1 -c:a libmp3lame -b:a 64k "${M[@]}" "$out/mseg2.mp3"
cat "$out/mseg1.mp3" "$out/ad_stereo.mp3" "$out/mseg2.mp3" > "$out/dai_monoshow_stereoad.mp3"

# Raw ADTS: a stereo show with a mono ad, and with a 48 kHz stereo ad.
"$F" "${Q[@]}" "${S[@]}" -t 10 -c:a aac -b:a 128k -f adts "$out/aseg1.aac"
"$F" "${Q[@]}" -f lavfi -i "$(tone 440 44100)" -af "volume=-6dB" -ac 1 -c:a aac -b:a 64k -f adts "$out/aad_mono.aac"
"$F" "${Q[@]}" -f lavfi -i "$(tone 660 48000)" -af "volume=-6dB" -ac 2 -c:a aac -b:a 128k -f adts "$out/aad_48k.aac"
"$F" "${Q[@]}" "${S[@]}" -ss 10 -t 10 -c:a aac -b:a 128k -f adts "$out/aseg2.aac"
cat "$out/aseg1.aac" "$out/aad_mono.aac" "$out/aseg2.aac" > "$out/dai_adts_mono.aac"
cat "$out/aseg1.aac" "$out/aad_48k.aac" "$out/aseg2.aac" > "$out/dai_adts_48k.aac"

# 5.1: the speech only on the front centre (as in dialogue mixes), a quiet tone on front left and right.
"$F" "${Q[@]}" "${S[@]}" -t 20 -f lavfi -i "sine=frequency=220:sample_rate=44100:duration=20" -filter_complex \
  "[0:a]pan=mono|c0=c0[c];[1:a]volume=-30dB[t];[t]asplit=2[l][r];[l][r][c]amerge=inputs=3,pan=5.1|FL=c0|FR=c1|FC=c2|LFE=0*c0|BL=0*c0|BR=0*c0[out]" \
  -map "[out]" -c:a aac -b:a 256k "$out/surround.m4a"
# bitexact: the Ogg stream serial numbers are fixed instead of random, so the bytes repeat.
"$F" "${Q[@]}" -i "$out/surround.m4a" -fflags +bitexact -c:a libopus -b:a 192k -mapping_family 1 "$out/surround.opus"

rm "$out"/seg?.mp3 "$out"/mseg?.mp3 "$out"/ad_*.mp3 "$out"/aseg?.aac "$out"/aad_*.aac
(cd "$out" && shasum -a 256 dai_mono.mp3 dai_48k.mp3 dai_monoshow_stereoad.mp3 dai_adts_mono.aac dai_adts_48k.aac \
  surround.m4a surround.opus)
