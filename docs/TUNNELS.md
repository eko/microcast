# Listening from the internet

Pick a tunnel under **Settings → Internet**; it starts together with the stream and the public address appears in
the menu (first row, with a globe), in the page header and in `/status.json` (`publicURL`). Set a **password** in
the same pane first: it protects every URL with HTTP Basic auth. Browsers ask for it once and hls.js reuses it; VLC and mpv accept
`https://x:password@host/…`.

## Providers

| Provider | Install | Account | Address | Notes |
|---|---|---|---|---|
| Cloudflare quick tunnel | `brew install cloudflared` | none | random `*.trycloudflare.com`, new on every start | Shown only after the tunnel is registered: the DNS name does not exist before, and a too-early lookup is cached as missing by macOS for a minute. |
| Cloudflare named tunnel | `cloudflared` + token from Zero Trust → Networks → Tunnels | Cloudflare | your own hostname | Point the tunnel's public hostname at `http://localhost:<port>` in the dashboard; enter the token and hostname in Settings → Internet. |
| ngrok | `brew install ngrok`, `ngrok config add-authtoken …` | ngrok | random `*.ngrok-free.app` or your reserved domain | |
| Tailscale Funnel | Tailscale app, Funnel enabled on the tailnet | Tailscale | `https://<mac>.<tailnet>.ts.net` | |
| Custom command | anything | | first `https://` URL the command prints | `{port}` is replaced, e.g. `bore local {port} --to bore.pub` or `lt --port {port}`. |
| DuckDNS + HTTPS | a free duckdns.org account, a port forwarded on your router | DuckDNS | `yourname.duckdns.org`, or your own hostname CNAME'd to it | Not a tunnel: your router forwards a port to the Mac; the app keeps the name pointed at your address and serves HTTPS with a Let's Encrypt certificate it obtains itself. Streams in real time. See below. |
| Own hostname + HTTPS | a name your router's DynDNS keeps current, ports 443 and 80 forwarded | none | your hostname | Same as above without DuckDNS: the certificate is checked over HTTP on port 80 instead of a DNS record. |

The app looks for CLIs in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/share/mise/shims`, `~/.local/bin` and
`PATH` (apps launched from the Finder get a very short `PATH`). Use the custom command with a full path otherwise.

## What to expect

Measured from a Mac in France:

| | Cloudflare quick tunnel | ngrok |
|---|---|---|
| Public address ready | ~9 s after Start | ~1 s |
| LL-HLS in hls.js | works, ≈ PART-HOLD-BACK + 1 s | works |
| Direct AAC/MP3/FLAC | delivered in 128 KiB blocks: 3 s of startup delay at 320 kbps, 16 s at 64 kbps | real time |
| Page ultra-low-latency (PCM) mode | unusable (blocks) | works when the listener has 1.5 Mbit/s |

So: HLS through Cloudflare for listeners anywhere; ngrok when they need the direct streams.

The tunnel process is stopped with the stream and when the app quits, so no tunnel outlives MicroCast.

## Security notes

- A quick tunnel URL is unguessable but public: anyone who has it can listen unless a password is set.
- The password travels as HTTP Basic auth over the tunnel's HTTPS, and in clear text on the local network.
- Cloudflare's free plan allows personal audio streaming; heavy use may fall under their traffic policies.

## Your own domain for free: DuckDNS + HTTPS

Tunnels give you a random name or buffer the audio; DuckDNS gives a fixed, free name you can CNAME from your own
domain, and MicroCast can serve HTTPS on it directly. What it takes:

1. Create a subdomain at [duckdns.org](https://www.duckdns.org) and copy the token.
2. On your router, forward a public port (443 is the natural choice) to this Mac's **local HTTPS port**
   (8443 by default). Give the Mac a fixed local address or a DHCP reservation.
3. In MicroCast, Settings → Internet: choose **DuckDNS + HTTPS**, enter the subdomain and token, the forwarded
   port, and keep **HTTPS with a Let's Encrypt certificate** on.
4. Optional, for `cast.example.com`: at your DNS provider add `cast CNAME yourname.duckdns.org` and
   `_acme-challenge.cast CNAME _acme-challenge.yourname.duckdns.org` (the certificate check follows that CNAME
   to the DuckDNS TXT record), then enter `cast.example.com` as *Your own hostname*.

Press Start. The app updates the DuckDNS address every five minutes, requests a certificate for the DuckDNS
name and your hostname through the DNS-01 challenge (no port 80 involved), stores it under
`~/Library/Application Support/MicroCast/certificates`, renews it when less than 30 days remain, and shows
`https://cast.example.com` in the menu once the HTTPS listener is up. The plain HTTP listener keeps serving the
local network as before. If validation of your hostname fails, the app falls back to a certificate for the DuckDNS
name alone and says so in the menu; the usual cause is the missing `_acme-challenge` CNAME.

### Without DuckDNS: your router's own DynDNS

Most boxes (Freebox, Livebox, Fritz!Box…) can keep a DynDNS name pointed at your address themselves. Then
choose **Own hostname + HTTPS**, enter the name (or a hostname of yours CNAME'd to it), and forward **two**
ports: the public port to the local HTTPS port (443 → 8443), and **80 → the local HTTP port** (8080). Let's
Encrypt validates the certificate by fetching `http://<host>/.well-known/acme-challenge/…`, which the app answers
without any password; port 80 is only used at issuance and at each renewal, but it has to stay forwarded.
Two checks worth making: the name must resolve to your IPv4 only (an IPv6 record sends browsers straight to the
Mac on a port nothing listens on), and if the DNS zone is on Cloudflare the record must be *DNS only*, not
proxied, or Cloudflare sits in front and buffers the streams again.

Notes: the first certificate takes about a minute (DNS propagation plus validation). Let's Encrypt allows five
identical certificates per week, which the cache keeps you far from. The identity is imported into your login
keychain because that is the only way into Network.framework's TLS; you'll see it in Keychain Access. Set a
password in the same pane: with a fixed public name, anyone who guesses it can listen.
