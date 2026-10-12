# Isolated ClearKey Playback Prototype

Experimental on-device playback module for an owner-supplied iOS player.
No third-party IPA, playlist, subscription credentials, content keys or media
are stored in this repository or supplied to CI.

## Scope

- Extended M3U ClearKey metadata, HTTP headers, inline KID:KEY/JSON/JWKS or
  provider-supplied HTTP(S) GET key endpoint. Keys stay in process memory.
- Observer hooks leave networking, responses, authentication and QR traffic
  unchanged. Only a registered ClearKey stream is routed away from AVPlayer.
- Distinct test player, manual CK TEST panel, playback on device rather than
  forwarding to a conversion server. Ordinary channels keep their old path.
- This initial prototype requires one distinct 128-bit CENC key per stream.
  Multiple KIDs sharing that key are accepted; different keys are rejected
  explicitly, never guessed. POST-only license flows are not implemented.
- No Widevine/PlayReady, CDM key extraction or license-policy bypass.
- No claim of restored MonPlayer source or tested physical-device playback.

## CK2 Changes

- Explicit LGPL zlib support for gzip/deflate manifests; automatic dependency
  detection is disabled and must not silently drop HTTP compression support.
- Ephemeral URLSession manifest validation follows source redirects before
  opening the player. TLS verification remains enabled; no guessed CDN URLs.
- Safe stage/code diagnostics without private URLs or key/error descriptions.
  Initial buffering has a 30-second deadline and Play can retry a failed open.
- Native regression cases decode owned CENC video through gzip and HTTP
  redirects on a loopback-only fixture server. CI never uses private channels.

## Engine and Licenses

KSPlayer is pinned to commit3558c7645240a191c3e4672eabe7b6ae1ee4f4ae,
whose LICENSE is LGPL2.1, not its current GPL/binary-only revision.
FFmpegKit is pinned to6.1.0. Its prebuilt GPL/nonfree core is NEVER shipped:
CI rebuilds official FFmpeg6.1 with GPL/nonfree/version3 disabled,then
replaces device/simulator core libraries. Native tests assert LGPL at runtime.
The bridge is a replaceable dynamic framework;
buildable bridge source and exact upstream references are provided.
Rebuild via the included macOS workflow and XcodeGen project. Do not assume
third-party binary licensing from a package's name; inspect bundled notices
and configurations before any distribution beyond a personal test.

## Verification

Native tests cover parsing, header isolation, known/unknown key formats,
ClearKey-only routing, normal-player pass-through and the compiled FFmpeg
DASH CENC option. CI does not connect to private stream/license servers.
Successful compilation or simulator unit tests are not proof of actual
channel playback on an iPhone. Local packaging must preserve the original
IPA and record all changed ZIP entries and hashes.
