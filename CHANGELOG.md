# Changelog

## 1.0.0 — 2026-09-04

First public release. 64 unit and integration tests; CI builds and releases the DMG on tags.

- Capture any Core Audio input (default: Elgato Wave Link Stream), or the output of chosen running applications through a system audio tap, optionally mixed together; everything converted to 48 kHz stereo.
- Low-Latency HLS with four AAC renditions (64/128/256/320 kbps), partial segments, blocking reloads, preload hints.
- Direct streams: AAC (ADTS), MP3 (via `lame`), FLAC, raw PCM. Every format can be switched off, and the bitrate list is configurable (64–320 kbps).
- Player page with hls.js, an ultra-low-latency PCM mode, level meter, direct stream links, light and dark theme, Media Session controls and a web app manifest.
- Stream name propagated to the page, `icy-name`, ID3, FLAC tags and HLS metadata.
- Internet exposure through cloudflared (quick or named tunnel), ngrok, Tailscale Funnel or any command, with
  optional HTTP Basic password.
- Port-forwarding modes with built-in HTTPS: DuckDNS (address kept current, DNS-01 certificate check) or any
  hostname your router's DynDNS maintains (HTTP-01 check on port 80); Let's Encrypt certificates obtained and
  renewed automatically.
- Recording of the live stream to FLAC, AAC or MP3.
- Menu bar panel with stereo meters, uptime, listener count, QR code and share sheet; Settings window (⌘,).
- Bonjour advertisement, listener count and history graph (panel and page), launch at login, auto-start.
- Off-air page: the address stays online between streams and the page starts playing by itself when you go live.
- Now playing: the track from Music or Spotify, with artwork, on the page, the phone lock screen and the panel.
- Jingles: a folder of audio files played over the ducked music at track changes or on demand, with adjustable duck level, volume and a lead time so the jingle starts before the end of the track.
- DMG packaging, optional Developer ID signing and notarization.
