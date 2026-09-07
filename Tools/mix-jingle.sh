#!/bin/sh
# Mixes a spoken take over a music bed into a finished radio jingle.
#
#   Tools/mix-jingle.sh <bed.mp3> <voice.mp3> <out.mp3> [lead] [tail] [lufs]
#
# The bed establishes for `lead` seconds, ducks under the voice while it speaks,
# then plays out for `tail` seconds.
#
# Levels are staged by measurement rather than by ear: the voice is normalised to
# VOX_LUFS and the bed to BED_LUFS, then the bed is pulled down a further DUCK dB
# while the voice speaks. That keeps the voice clearly on top of every bed, whatever
# the take. ANALYZE=1 renders the stems and prints the voice-to-bed ratio it achieved.
#
# VOICE=big (default) applies radio imaging treatment: the take is pitched down,
# boosted in the low mids, de-essed and compressed hard, the way station idents are
# produced. VOICE=natural keeps the take as spoken.
set -eu

bed="${1:?usage: mix-jingle.sh <bed.mp3> <voice.mp3> <out.mp3> [lead] [tail] [lufs]}"
voice="${2:?a voice take is required}"
out="${3:?an output path is required}"
lead="${4:-0.7}"
tail="${5:-1.3}"
lufs="${6:--14}"

VOICE="${VOICE:-big}"
PITCH="${PITCH:-0.93}"          # <1 lowers the voice; 0.93 is about a semitone down
VOX_LUFS="${VOX_LUFS:--16}"     # voice level before mixing
BED_LUFS="${BED_LUFS:--20}"     # bed level when it plays alone
DUCK="${DUCK:-9}"               # dB the bed drops while the voice speaks

vdur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$voice")
total=$(python3 -c "print(round($lead + $vdur + $tail, 3))")
fadeout=$(python3 -c "print(round($total - 0.9, 3))")
delay=$(python3 -c "print(int($lead * 1000))")
# The speech window is known exactly, so the duck is an explicit envelope rather than
# a sidechain guess: full bed, ramp down just before the voice, hold, ramp back up.
duck_gain=$(python3 -c "print(round(10 ** (-$DUCK / 20), 5))")
d0=$(python3 -c "print(round(max($lead - 0.2, 0.0), 3))")
d1=$(python3 -c "print(round($lead + 0.05, 3))")
d2=$(python3 -c "print(round($lead + $vdur, 3))")
d3=$(python3 -c "print(round($lead + $vdur + 0.5, 3))")

if [ "$VOICE" = "big" ]; then
	rate=$(python3 -c "print(int(44100 * $PITCH))")
	tempo=$(python3 -c "print(round(1 / $PITCH, 5))")
	tone="asetrate=${rate},aresample=44100,atempo=${tempo},
         highpass=f=75,
         bass=g=5:f=120:w=0.7,
         equalizer=f=350:width_type=o:width=1:g=-3,
         equalizer=f=3200:width_type=o:width=1.2:g=4,
         equalizer=f=9000:width_type=o:width=1:g=2,
         deesser=i=0.4,
         acompressor=threshold=0.05:ratio=6:attack=5:release=150:makeup=3"
	verb="aecho=0.9:0.4:45:0.12"
else
	tone="highpass=f=90,
         equalizer=f=3000:width_type=o:width=1.2:g=3,
         acompressor=threshold=0.1:ratio=3:attack=8:release=180:makeup=2"
	verb="aecho=0.85:0.55:55:0.18"
fi

# Both stems are normalised first so the duck depth means the same thing every time.
vox_chain="[1:a]aformat=sample_rates=44100:channel_layouts=stereo,
         ${tone},${verb},
         loudnorm=I=${VOX_LUFS}:TP=-2:LRA=7,
         aformat=sample_rates=44100:channel_layouts=stereo,
         adelay=${delay}|${delay},apad=whole_dur=${total}[vox]"
bed_chain="[0:a]aformat=sample_rates=44100:channel_layouts=stereo,
         atrim=0:${total},asetpts=N/SR/TB,
         loudnorm=I=${BED_LUFS}:TP=-3:LRA=7,
         aformat=sample_rates=44100:channel_layouts=stereo,
         afade=t=in:st=0:d=0.2,afade=t=out:st=${fadeout}:d=0.9[bedraw]"
duck_chain="[bedraw]volume=eval=frame:volume='
           if(lt(t,${d0}), 1,
           if(lt(t,${d1}), 1+(${duck_gain}-1)*(t-${d0})/(${d1}-${d0}),
           if(lt(t,${d2}), ${duck_gain},
           if(lt(t,${d3}), ${duck_gain}+(1-${duck_gain})*(t-${d2})/(${d3}-${d2}), 1))))'[ducked]"

# Loop the bed so a take longer than the generated music never loses its tail.
ffmpeg -y -v error -stream_loop -1 -i "$bed" -i "$voice" -filter_complex "
    ${bed_chain};
    ${vox_chain};
    ${duck_chain};
    [ducked][vox]amix=inputs=2:normalize=0:duration=first,
         loudnorm=I=${lufs}:TP=-1.5:LRA=7,
         aformat=sample_rates=48000:channel_layouts=stereo[out]
  " -map "[out]" -codec:a libmp3lame -b:a 192k "$out"

printf '  -> %-24s %ss\n' "$(basename "$out")" "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out")"

if [ "${ANALYZE:-0}" = "1" ]; then
	tmp="${TMPDIR:-/tmp}/mixjingle.$$"
	mkdir -p "$tmp"
	ffmpeg -y -v error -stream_loop -1 -i "$bed" -i "$voice" -filter_complex "
	    ${bed_chain};${vox_chain};${duck_chain}" \
		-map "[ducked]" "$tmp/bed.wav" -map "[vox]" "$tmp/vox.wav"
	win_end=$(python3 -c "print(round($lead + $vdur, 3))")
	measure() {
		ffmpeg -hide_banner -nostats -i "$1" \
			-af "atrim=${lead}:${win_end},asetpts=N/SR/TB,loudnorm=print_format=summary" -f null - 2>&1 |
			grep 'Input Integrated' | grep -o '\-*[0-9.]*' | head -1
	}
	v=$(measure "$tmp/vox.wav"); b=$(measure "$tmp/bed.wav")
	python3 -c "print(f'     voice {$v} LUFS / bed {$b} LUFS during speech -> voice is {$v - $b:+.1f} dB above the bed')"
	rm -rf "$tmp"
fi
