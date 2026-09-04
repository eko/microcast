# Troubleshooting

**Silence, but the app plays on the Mac** — the input is quiet. In Wave Link, check which apps are routed to the
*Stream* mix; the level meters in the menu show what is captured. Silence also makes AAC output tiny, which keeps
Chrome from starting playback of a direct stream for a long time (it probes before playing).

**"Microphone access denied"** — System Settings → Privacy & Security → Microphone → MicroCast. macOS keys the
grant to the build's code hash for ad-hoc signed apps and may ask again after a rebuild.

**The app is not listed under Microphone** — it only appears after it asked once. Press Start.

**Capturing applications gives silence** — System Audio Recording was denied: System Settings → Privacy &
Security → Screen & System Audio Recording → *System Audio Recording Only* → MicroCast. As with the microphone,
the grant is keyed to the build and may be asked again after a rebuild.

**An app is missing from the list** — only apps that have played audio since they launched have an audio session
to tap; play something, then Refresh. Helper processes are grouped under their app (Safari, Chrome…).

**Port already in use** — change the port in Settings → General (applies on the next Start), or find the other process
with `lsof -nP -iTCP:8080 -sTCP:LISTEN`.

**MP3 rows missing on the page** — `lame` was not found. `brew install lame`.

**"Tunnel not started: cloudflared not found"** — install it, or use *Custom command* (Settings → Internet) with the full path.

**Public URL never appears (Cloudflare)** — the app waits for cloudflared to report "Registered tunnel
connection". Check that UDP 7844 or TCP 7844 to Cloudflare is not blocked; the app's status line shows the last
line cloudflared printed if it exits.

**DuckDNS: "refused the address update"** — wrong subdomain or token; both come from duckdns.org's dashboard.

**DuckDNS: the certificate request fails** — the menu shows Let's Encrypt's reason. "validation of cast.example.com
failed" means the `_acme-challenge.cast` CNAME is missing or not propagated yet; the app then continues with the
DuckDNS name alone. Rate-limit errors mean too many issuances in a week; the cache under
`~/Library/Application Support/MicroCast/certificates` normally prevents that.

**Own hostname: "validation of … failed"** — Let's Encrypt could not fetch `http://<host>/.well-known/acme-challenge/…`:
port 80 is not forwarded to the Mac's HTTP port, the name points at an old address, or an IPv6 record sends the
check straight to the Mac. `curl http://<host>/.well-known/acme-challenge/test` from outside should answer
"unknown challenge" (404) while the app runs.

**HTTPS works locally but not from outside** — check the router forwards the public port to the Mac's local
HTTPS port (8443 by default) and that the Mac's local address has not changed.

**"MicroCast wants to control Music"** — the now-playing feature reads the track through AppleScript; allow it
once (System Settings → Privacy & Security → Automation to change your mind). The track appears only while
Music or Spotify is playing and is what you stream.

**The off-air page never turns into the player** — the page polls `/status.json` every 3 s; press "Play when it
starts" once so the browser lets it start on its own, and check the page is reachable at all (an unreachable
address shows a browser error, not the off-air page). "Stay online while off air" must be on in Settings → Internet.

**Jingles start after the next song has begun** — Music crossfades songs (Music → Settings → Playback) and
the next one is audible before `current track` changes; the lead time counts from the end the player declares,
so add the crossfade duration to it (a 5 s crossfade and a 2 s lead means 7 s). Tracks that end early get their
jingle at the change instead.

**No jingle plays** — jingles need the Now Playing detection (Music or Spotify playing and selected as the
source), files in the folder shown in Settings → Jingles, and a track change; "Play one now" tests the chain
while live. A jingle already playing is not interrupted by the next change.

**hls.js keeps choosing 64 kbps in Auto** — ABR estimates bandwidth from tiny audio parts and gets it wrong on a
fast network. Pick a fixed rendition; the page defaults to 320 kbps.

**The Start button is disabled** — microphone access is turned off; the panel shows a banner with a button to the
right System Settings pane.

**Playback stutters on a phone** — direct streams are uncompressed or high bitrate. Use HLS at 128 kbps, or set a
longer HLS part (500 ms) which raises latency but tolerates jitter.

**Gatekeeper refuses the app on another Mac** — the DMG is ad-hoc signed. Right-click → Open once, or
`xattr -d com.apple.quarantine /Applications/MicroCast.app`. See `dist.sh` for Developer ID signing.

**Logs**

```
log stream --predicate 'subsystem == "local.microcast"' --style compact
```
