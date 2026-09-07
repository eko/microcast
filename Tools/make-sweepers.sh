#!/bin/sh
# Generates station sweepers — the whooshes, risers and impacts used to move between
# songs — with the ElevenLabs sound generator, which suits effects far better than it
# suits music.
#
#   Tools/make-sweepers.sh [outdir]
#
# Effects come from Tools/sweepers.txt (name | seconds | prompt). Output is normalised
# a little hotter than the jingles so a sweeper cuts through the music it plays over.
set -eu
cd "$(dirname "$0")/.."

KEY="${ELEVENLABS_API_KEY:-}"
[ -n "$KEY" ] || KEY="$(cat "$HOME/.microcast-elevenlabs" 2>/dev/null || true)"
if [ -z "$KEY" ]; then
	echo "No API key. Put it in ~/.microcast-elevenlabs (chmod 600) or export ELEVENLABS_API_KEY." >&2
	exit 1
fi
case "$KEY" in sk_*) ;; *) echo "That looks like an API key ID, not a key: real keys start with 'sk_'." >&2; exit 1 ;; esac

OUT="${1:-$HOME/Music/MicroCast/Sweepers}"
LOUDNESS="${LOUDNESS:--12}"
mkdir -p "$OUT"

grep -v '^[[:space:]]*#' Tools/sweepers.txt | grep '|' | while IFS='|' read -r name secs prompt; do
	name=$(echo "$name" | sed 's/[[:space:]]*$//')
	secs=$(echo "$secs" | tr -d ' ')
	prompt=$(echo "$prompt" | sed 's/^[[:space:]]*//')
	[ -n "$name" ] && [ -n "$prompt" ] || continue
	printf 'generating %-18s %ss\n' "$name" "$secs"
	python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1], "duration_seconds": float(sys.argv[2]), "prompt_influence": 0.7}))' "$prompt" "$secs" > /tmp/sweeper-body.json
	curl -fsS -X POST https://api.elevenlabs.io/v1/sound-generation \
		-H "xi-api-key: $KEY" -H "Content-Type: application/json" \
		--data @/tmp/sweeper-body.json -o "/tmp/$name.raw.mp3"
	# Trim the silence the generator leaves at the head so the sweeper fires on cue.
	ffmpeg -v error -y -i "/tmp/$name.raw.mp3" \
		-af "silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.02,
             loudnorm=I=$LOUDNESS:TP=-1.5:LRA=9,
             afade=t=out:st=$(python3 -c "print(max(float('$secs')-0.15,0.05))"):d=0.15" \
		-ar 48000 -ac 2 -b:a 192k "$OUT/$name.mp3"
	rm -f "/tmp/$name.raw.mp3"
done
rm -f /tmp/sweeper-body.json
echo "done -> $OUT"
