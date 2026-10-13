#!/bin/bash
# A stereo show with distinct left/right markers (440 Hz left, 660 Hz right), a mono ad (1000 Hz) and the
# show again, as raw ADTS at 44.1 kHz (FFmpeg's AAC encoder). Usage: make-markers.sh <empty output directory>
set -euo pipefail
out="$1"
F=${FFMPEG:-ffmpeg}  # ffmpeg on PATH unless FFMPEG names another
Q=(-hide_banner -loglevel error -nostdin -n)
"$F" "${Q[@]}" -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=2" -f lavfi -i "sine=frequency=660:sample_rate=44100:duration=2" \
  -filter_complex "[0][1]join=inputs=2:channel_layout=stereo:map=0.0-FL|1.0-FR[a]" -map '[a]' -c:a aac -b:a 128k -f adts "$out/show.aac"
"$F" "${Q[@]}" -f lavfi -i "sine=frequency=1000:sample_rate=44100:duration=1" -ac 1 -c:a aac -b:a 64k -f adts "$out/ad.aac"
cat "$out/show.aac" "$out/ad.aac" "$out/show.aac" > "$out/stereo-markers-mono-ad.aac"
rm "$out/show.aac" "$out/ad.aac"
