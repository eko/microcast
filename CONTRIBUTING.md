# Contributing

Thanks for taking a look. MicroCast is a small codebase on purpose: one Swift package, no third-party
Swift dependencies, macOS frameworks only. Keep it that way when you can.

## Set up

```
git clone https://github.com/eko/microcast.git
cd microcast
./run.sh            # builds build/MicroCast.app and launches it
swift test          # unit tests
```

Requirements: macOS 14+, Xcode command line tools. `lame` (Homebrew) for MP3, `cloudflared` or `ngrok`
to try the tunnels.

## Where things are

| Path | What |
|---|---|
| `Sources/MicroCast/` | the app (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for a tour) |
| `Resources/index.html` | the player page, served by the app |
| `Tests/MicroCastTests/` | XCTest suites: the pure parts (playlist, ACME/JWS, tunnel/DuckDNS, jingle DSP) and integration tests that need no audio hardware or network (real AAC/FLAC/MP3 encoders, AVAssetWriter HLS packaging, the router live and off air, the HTTP and HTTPS servers on a real port, broadcaster back-pressure, recorder) |
| `Tools/make-icon.swift` | renders the app icon |
| `build.sh`, `dist.sh`, `run.sh` | bundle, DMG, run |
| `docs/` | user and developer documentation |

## Documentation images

The pictures in the README are regenerated from the running app, so they cannot quietly drift away
from the interface they advertise:

```sh
defaults write local.microcast demoAddresses -bool true   # example.com instead of your own host
Tools/shoot.sh docs/images/offair.png                     # then press Start, and:
Tools/shoot.sh docs/images/onair.png
swift Tools/make-hero.swift docs/images/hero.png docs/images
defaults delete local.microcast demoAddresses
```

`shoot.sh` asks the app to draw its own window into a PNG. It renders the view hierarchy rather
than photographing the screen, so it needs no Screen Recording permission — which is not a
reasonable thing to ask of someone updating a screenshot. `demoAddresses` swaps the Listen panel
for `cast.example.com`, so a public README never ships a contributor's domain, host name and LAN
address.

## Style

- Swift 5 language mode, tabs, `swift-format`-style layout. Small types with one job; protocols only where a second
  implementation exists.
- Logging goes through `os.Logger` with subsystem `local.microcast`.
- Anything that touches Core Audio, AVFoundation or Network.framework should say *why* in a comment when the
  behaviour is not obvious (there are a few of those; the taps, the encoders and the LL-HLS rules are the usual
  suspects).

## Pull requests

- One topic per PR, with a short description of the behaviour change and how you verified it. For streaming
  changes, `ffprobe`, `ffplay`, VLC and the page itself are the usual witnesses.
- Add or update a unit test when the change is testable without audio hardware.
- `swift test` must pass (64 tests; the MP3 one skips without `lame`); CI runs it on every PR and also builds the DMG.

## Releasing

1. Add a `## <version> — <date>` section at the top of `CHANGELOG.md`; the release notes are extracted from it.
2. `git tag v<version> && git push origin v<version>`.
3. CI (`.github/workflows/ci.yml`, job *release*) tests, runs `VERSION=<version> ./dist.sh`, and creates the GitHub
   release with `MicroCast-<version>.dmg` and `MicroCast-<version>.dmg.sha256`. Tags containing a hyphen are
   published as pre-releases. Signing and notarization happen when the repository secrets listed in the README
   exist; without them the DMG is ad-hoc signed, exactly like a local build.

## Reporting problems

Please include macOS version, the audio device, what player you used, and the output of
`log stream --predicate 'subsystem == "local.microcast"' --style compact` around the problem.
