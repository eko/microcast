#!/bin/sh
# Generates produced station jingles with ElevenLabs: an expressive voice over a
# generated music bed, ducked and loudness-matched, ready to drop into MicroCast.
#
#   Tools/make-jingles.sh --voices                  voices on your account
#   Tools/make-jingles.sh --library                 French voices in the shared library
#   Tools/make-jingles.sh --beds                    regenerate the music beds only
#   Tools/make-jingles.sh <male_id> <female_id> [outdir]
#
# Lines come from Tools/jingles-fr.txt (name | M/F | text). Text may carry Eleven v3
# performance tags such as [confident]; a default is applied per voice when it has none.
# BED_PROMPT / BED_COUNT pick the musical style. The API key is read from
# $ELEVENLABS_API_KEY or ~/.microcast-elevenlabs and is never written into the repository.
set -eu
cd "$(dirname "$0")/.."

KEY="${ELEVENLABS_API_KEY:-}"
[ -n "$KEY" ] || KEY="$(cat "$HOME/.microcast-elevenlabs" 2>/dev/null || true)"
if [ -z "$KEY" ]; then
	echo "No API key. Put it in ~/.microcast-elevenlabs (chmod 600) or export ELEVENLABS_API_KEY." >&2
	exit 1
fi
case "$KEY" in sk_*) ;; *) echo "That looks like an API key ID, not a key: real keys start with 'sk_'." >&2; exit 1 ;; esac

show() {
	python3 -c '
import json, sys
key = sys.argv[1]
for v in json.load(sys.stdin).get(key, []):
    labels = v.get("labels") or {}
    bits = [labels.get("gender", "?"), labels.get("accent", ""), labels.get("age", ""), labels.get("description", "")]
    print("  {:<26} {:<24} {}".format(v.get("name", "?"), v.get("voice_id", "?"), " ".join(b for b in bits if b)))' "$1"
}

if [ "${1:-}" = "--voices" ]; then
	curl -fsS -H "xi-api-key: $KEY" https://api.elevenlabs.io/v1/voices | show voices
	exit 0
fi

if [ "${1:-}" = "--library" ]; then
	echo "French voices in the shared library (these need a paid plan to synthesise):"
	curl -fsS -H "xi-api-key: $KEY" "https://api.elevenlabs.io/v1/shared-voices?page_size=100&language=fr" | show voices
	exit 0
fi

OUT="${3:-$HOME/Music/MicroCast/Jingles}"
BEDS="$OUT/.beds"
MODEL="${MODEL:-eleven_v3}"
LOUDNESS="${LOUDNESS:--14}"     # LUFS; jingles play over music ducked by ~12 dB
LEAD="${LEAD:-0.7}"             # seconds of music before the voice enters
TAIL="${TAIL:-1.3}"             # seconds of music after the voice ends
BED_COUNT="${BED_COUNT:-3}"
BED_SOURCE="${BED_SOURCE:-synth}"   # synth = Tools/make-bed.py, api = sound generator
BED_STYLE="${BED_STYLE:-chr}"       # synth only: chr, dance, hotac, retro, news
BED_BPM="${BED_BPM:-128}"
BED_PROMPT="${BED_PROMPT:-Upbeat radio station jingle music bed, bright synth stabs, punchy electronic drums, uplifting major chord progression, no vocals, energetic FM radio imaging}"

# Music beds are generated once and reused across jingles; --beds forces a refresh.
# The sound generator makes texture rather than tunes, so a bed that needs an actual
# melody is synthesised locally instead.
make_beds() {
	mkdir -p "$BEDS"
	i=1
	while [ "$i" -le "$BED_COUNT" ]; do
		printf 'generating bed %d/%d (%s)\n' "$i" "$BED_COUNT" "$BED_SOURCE"
		if [ "$BED_SOURCE" = "synth" ]; then
			python3 Tools/make-bed.py "$BEDS/bed-$i.wav" \
				--style "$BED_STYLE" --bars 4 --bpm "$BED_BPM" --seed "$i" >/dev/null
			ffmpeg -v error -y -i "$BEDS/bed-$i.wav" -b:a 192k "$BEDS/bed-$i.mp3"
			rm -f "$BEDS/bed-$i.wav"
		else
			python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1], "duration_seconds": 8, "prompt_influence": 0.6}))' "$BED_PROMPT" > /tmp/jingle-bed.json
			curl -fsS -X POST https://api.elevenlabs.io/v1/sound-generation \
				-H "xi-api-key: $KEY" -H "Content-Type: application/json" \
				--data @/tmp/jingle-bed.json -o "$BEDS/bed-$i.mp3"
		fi
		i=$((i + 1))
	done
	rm -f /tmp/jingle-bed.json
}

if [ "${1:-}" = "--beds" ]; then
	make_beds
	echo "done -> $BEDS"
	exit 0
fi

MALE="${1:?usage: make-jingles.sh <male_id> <female_id> [outdir]  (--voices / --library to browse)}"
FEMALE="${2:?a female voice id is required too}"
mkdir -p "$OUT"
[ -f "$BEDS/bed-1.mp3" ] || make_beds

bed_index=0
grep -v '^[[:space:]]*#' Tools/jingles-fr.txt | grep '|' | while IFS='|' read -r name voice text; do
	name=$(echo "$name" | sed 's/[[:space:]]*$//')
	voice=$(echo "$voice" | tr -d ' ')
	text=$(echo "$text" | sed 's/^[[:space:]]*//')
	[ -n "$name" ] && [ -n "$text" ] || continue
	# Male idents get the imaging treatment; pitching a warm female take down would
	# only cost it its warmth, so it stays natural.
	case "$voice" in
		F) id="$FEMALE"; mood="[sensual][smiling]";                style="${VOICE_F:-natural}" ;;
		*) id="$MALE";   mood="[booming][radio imaging announcer]"; style="${VOICE_M:-big}" ;;
	esac
	# Only add a performance direction when the line does not already carry one.
	case "$text" in *"["*) ;; *) text="$mood $text" ;; esac

	printf 'generating %-18s [%s] %s\n' "$name" "$voice" "$text"
	python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1], "model_id": sys.argv[2], "voice_settings": {"stability": 0.3, "similarity_boost": 0.85, "use_speaker_boost": True}}))' "$text" "$MODEL" > /tmp/jingle-body.json
	curl -fsS -X POST "https://api.elevenlabs.io/v1/text-to-speech/$id?output_format=mp3_44100_128" \
		-H "xi-api-key: $KEY" -H "Content-Type: application/json" \
		--data @/tmp/jingle-body.json -o "/tmp/$name.vox.mp3"

	bed_index=$((bed_index % BED_COUNT + 1))
	VOICE="$style" Tools/mix-jingle.sh "$BEDS/bed-$bed_index.mp3" "/tmp/$name.vox.mp3" "$OUT/$name.mp3" "$LEAD" "$TAIL" "$LOUDNESS"
	rm -f "/tmp/$name.vox.mp3"
done
rm -f /tmp/jingle-body.json
echo "done -> $OUT"
