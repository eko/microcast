# Streams and endpoints

Everything is served from `http://<host>:<port>/`. With a password set, every URL requires HTTP Basic auth with
any user name, e.g. `http://x:secret@host:8080/stream.flac`.

## Endpoints

| URL | Content | Notes |
|---|---|---|
| `/` | player page | hls.js bundled; light/dark |
| `/status.json` | JSON | `name`, `live`, `lastLive` (unix time, when off air), `listeners`, `peak`, `history` (`[[unix time, count], …]`, last 30 min, one sample per `historyInterval` seconds), `nowPlaying` (`title`, `artist`, `album`, `source`, `artwork` path) when Music or Spotify is the source, `bitrates`, `hls`, `aac`, `mp3`, `flac`, `pcm`, `partDurationMs`, `protected`, `publicURL` |
| `/artwork?id=…` | image | artwork of the current track, as referenced by `nowPlaying.artwork` |
| `/hls/master.m3u8` | `application/vnd.apple.mpegurl` | one rendition per configured bitrate, `EXT-X-SESSION-DATA` with the name |
| `/hls/{bitrate}/stream.m3u8` | media playlist | LL-HLS; supports `?_HLS_msn=N&_HLS_part=P` |
| `/hls/{br}/init.mp4` | `audio/mp4` | fMP4 init segment, title in `moov/udta/©nam` |
| `/hls/{br}/seg{N}.m4s` | `audio/mp4` | full segment (waits until complete) |
| `/hls/{br}/seg{N}.{P}.m4s` | `audio/mp4` | partial segment (waits until produced) |
| `/stream-{bitrate}.aac` | `audio/aac` | ADTS frames, `icy-name`, `icy-br` |
| `/stream-{bitrate}.mp3` | `audio/mpeg` | needs `lame`; ID3v2 `TIT2` first, `icy-name` |
| `/stream.flac` | `audio/flac` | `fLaC` + STREAMINFO + VORBIS_COMMENT `TITLE`, then frames |
| `/screen.mjpeg` | `multipart/x-mixed-replace` | the selected screen region as a stream of JPEG frames; plays in an `<img>` |
| `/screen.jpg` | `image/jpeg` | the latest screen frame (poster/fallback) |
| `/stream.pcm` | `application/octet-stream` | interleaved s16le, 1.5 Mbit/s; `X-Sample-Rate`, `X-Channels`, `X-Bits-Per-Sample` |
| `/hls.min.js` | JavaScript | bundled hls.js |
| `/icon.png`, `/apple-touch-icon.png`, `/favicon.ico` | `image/png` | the app icon, also used as lock-screen artwork |
| `/manifest.webmanifest` | web app manifest | lets phones add the page to the home screen under the stream's name |

`{bitrate}` is any value from the list in Settings → Stream (64, 128, 256 and 320 kbps by default; 64–320, up to
eight). Formats switched off there answer 404, and the screen endpoints answer 404 when screen streaming is off. While the app is online but off air, streams and playlists answer
503 with `Retry-After`, and the page shows its off-air state. All responses carry `Access-Control-Allow-Origin: *`. Streams are sent with `Connection: close` and no
`Content-Length`, Icecast style.

## Formats

| Stream | Codec | Rate | Bitrates |
|---|---|---|---|
| HLS | AAC-LC in fMP4 (CMAF) | 48 kHz stereo | configured list, default 64 / 128 / 256 / 320 kbps |
| AAC | AAC-LC in ADTS | 48 kHz stereo | same list |
| MP3 | MPEG-1 Layer III, CBR, joint stereo | 48 kHz | same list, rounded by lame to legal MP3 rates |
| FLAC | FLAC, 16-bit, 4608-sample blocks | 48 kHz stereo | lossless, ~0.7–1.2 Mbit/s for music |
| PCM | signed 16-bit little-endian, interleaved | 48 kHz stereo | 1.5 Mbit/s |

## Playing

**VLC / mpv / foobar2000** — open the `.m3u8`, `.aac`, `.mp3` or `.flac` URL. The stream name shows as the
title (`icy-name`). With a password: `https://x:secret@host/stream.flac`.

**ffmpeg / ffplay**

```
ffplay http://mac.local:8080/hls/320/stream.m3u8
ffmpeg -i http://mac.local:8080/stream.flac -t 60 archive.flac
```

**hls.js** in your own page

```js
const hls = new Hls({ lowLatencyMode: true, liveDurationInfinity: true });
hls.loadSource('http://mac.local:8080/hls/master.m3u8');
hls.attachMedia(document.querySelector('audio'));
```

**Safari / iOS** — the page uses hls.js through Media Source (iOS 17.1+). Older iOS falls back to native HLS,
which ignores partial segments and sits around 6 s behind.

**OBS** — a Media Source with the HLS or FLAC URL; disable buffering-related options for the lowest delay.

**Raw PCM** — `curl -s http://host:8080/stream.pcm | play -t raw -r 48000 -e signed -b 16 -c 2 -` (sox), or the
page's "Ultra-low latency" mode, which schedules 20 ms chunks in Web Audio with 150 ms of headroom. It is
uncompressed (1.5 Mbit/s), so it needs a connection that keeps up; through ngrok or Tailscale it works over the
internet, through Cloudflare it does not (128 KiB buffering).

## Latency, in practice

| Player | Mode | Measured |
|---|---|---|
| Page, PCM mode (any connection with 1.5 Mbit/s spare) | PCM | 0.17 s buffer, ~0.2 s total |
| Page, same network | LL-HLS, 334 ms parts | 1.3 s |
| Page, through Cloudflare | LL-HLS, 500 ms parts | 2.6 s |
| VLC | FLAC / MP3 direct | 1–2 s |
| Chrome `<audio>` on a direct stream | | 5–7 s (Chrome probes before playing) |
| Native HLS player ignoring parts | | ~3 segments |

Through Cloudflare, direct streams are delivered in 128 KiB blocks (16 s of audio at 64 kbps); prefer HLS there,
or ngrok, which streams in real time. See [TUNNELS.md](TUNNELS.md).

## Metadata

The stream name (Settings → General) is placed everywhere a client might look: page title, `icy-name`, ID3 `TIT2` on
MP3, `TITLE` on FLAC, `EXT-X-SESSION-DATA` and `EXTINF` titles in HLS, and `©nam` in the fMP4 init segment. No
HLS player renders a stream title as such, but ffprobe reports it and hls.js exposes it in `sessionData`.
