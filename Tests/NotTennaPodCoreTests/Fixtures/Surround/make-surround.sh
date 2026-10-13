#!/bin/bash
# Labelled multichannel tone fixtures: each channel its own sine (FFmpeg's default
# amplitude 1/8). join puts the first, FC-labelled mono input on FC and the rest in order:
# FC 300, FL 500, FR 700, LFE 60, BL 1100, BR 1300 Hz; 7.1 adds SL 1700, SR 1900 Hz. FFmpeg 9.0.2.
# Usage: make-surround.sh <empty output directory>
set -euo pipefail
out="$1"
F=${FFMPEG:-ffmpeg}  # ffmpeg on PATH unless FFMPEG names another
Q=(-hide_banner -loglevel error -nostdin -n)
s() { echo "sine=frequency=$1:sample_rate=$2:duration=1"; }
inputs() { local rate=$1; shift; for f in "$@"; do printf -- '-f\nlavfi\n-i\n%s\n' "$(s "$f" "$rate")"; done; }
mapfile -t six44 < <(inputs 44100 300 500 700 60 1100 1300)
mapfile -t six48 < <(inputs 48000 300 500 700 60 1100 1300)
mapfile -t eight48 < <(inputs 48000 300 500 700 60 1100 1300 1700 1900)
join6='[0][1][2][3][4][5]join=inputs=6:channel_layout=5.1[a]'
join8='[0][1][2][3][4][5][6][7]join=inputs=8:channel_layout=7.1[a]'
"$F" "${Q[@]}" "${six44[@]}" -filter_complex "$join6" -map '[a]' -c:a aac -b:a 256k "$out/labelled-5.1.m4a"
"$F" "${Q[@]}" -i "$out/labelled-5.1.m4a" -c copy -f adts "$out/labelled-5.1.aac"
"$F" "${Q[@]}" "${six44[@]}" -filter_complex "$join6" -map '[a]' -c:a flac "$out/labelled-5.1.flac"
"$F" "${Q[@]}" "${six48[@]}" -filter_complex "$join6" -map '[a]' -c:a libopus -mapping_family 1 -b:a 256k "$out/labelled-5.1.opus"
"$F" "${Q[@]}" "${eight48[@]}" -filter_complex "$join8" -map '[a]' -c:a libopus -mapping_family 1 -b:a 320k "$out/labelled-7.1.opus"
# Six channels with a mid-stream layout change: one second of 5.1 with a 500 Hz tone on back-left only,
# then one second of hexagonal (FL FR FC BL BR BC, written with a PCE) with a 700 Hz tone on back-centre only.
silence="anullsrc=channel_layout=mono:sample_rate=48000,atrim=duration=1"
"$F" "${Q[@]}" -f lavfi -i "$silence" -f lavfi -i "$(s 500 48000)" \
  -filter_complex "[0]asplit=5[a][b][c][d][e];[a][b][c][d][1][e]join=inputs=6:channel_layout=5.1:map=0.0-FL|1.0-FR|2.0-FC|3.0-LFE|4.0-BL|5.0-BR[o]" \
  -map '[o]' -c:a aac -b:a 384k -f adts "$out/change-a.aac"
"$F" "${Q[@]}" -f lavfi -i "$silence" -f lavfi -i "$(s 700 48000)" \
  -filter_complex "[0]asplit=5[a][b][c][d][e];[a][b][c][d][e][1]join=inputs=6:channel_layout=hexagonal:map=0.0-FL|1.0-FR|2.0-FC|3.0-BL|4.0-BR|5.0-BC[o]" \
  -map '[o]' -c:a aac -aac_pce 1 -b:a 384k -f adts "$out/change-b.aac"
cat "$out/change-a.aac" "$out/change-b.aac" > "$out/layout-change-6ch.aac"
rm "$out/change-a.aac" "$out/change-b.aac"
