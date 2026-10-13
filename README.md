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
- CK3 adds a bounded KID-to-key map for DASH/CENC with up to128 supplied
  128-bit keys. Missing multikey matches fail;keys are never guessed. Sources
  with one distinct key retain CK2's default-key compatibility path.
- Multikey HLS,POST-only licenses,dynamic license renewal and a blanket key
  rotation claim remain outside this checkpoint. Unsupported paths fail
  explicitly rather than silently dropping the key map.
- No Widevine/PlayReady, CDM key extraction or license-policy bypass.
- No claim of restored MonPlayer source or tested physical-device playback.
- CK4 adds the supported subset of Kodi modern inline ClearKey JSON,drm_legacy,
  data:application/json;base64 and bare base64 JSON/JWKS. Original legacy
  ClearKey URL/GET playlists keep their existing request path.

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
CK3 includes a local LGPL source modification for MOV/DASH supplied-key maps;
it is NOT an unmodified upstream FFmpeg release. Exact original file hashes
are validated;no public ABI changes are introduced. Cipher state is discarded
when the sample key changes,without inventing or fetching a missing key.
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

## CK3 Checkpoint

- Deterministic supplied-key serialization,128-key limit,canonical conflict
  rejection,and explicit rejection of multikey HLS until its path is added.
- Owned encrypted red video and sine audio use DIFFERENT keys. Native tests
  compare decoded video luma and decoded audio against an owned PCM reference,
  including gzip HTTP and missing/wrong-key negative cases.
- Pinned-source patch idempotence/tamper tests;cache identity incorporates the
  actual core-build and key-map modification source to reject stale binaries.
- Real keys/URLs never enter CI. CK2's signed installation and user-reported
  SCTV1/ON playback are baseline evidence,not CK3 physical verification.

## CK4 Stage 1B Checkpoint

- Parse modern `inputstream.adaptive.drm` inline `license.keyids` or JSON data
  URIs,and `inputstream.adaptive.drm_legacy` inline/data/legacy-GET sources.
- Keep license-only headers separate from stream headers;percent-encoded
  headers handle form spaces/literal plus and case-insensitive overrides.
- Reject ambiguous/conflicting declarations,duplicate/escaped JSON keys,
  unsafe headers and declared-but-unimplemented license/header scopes.
- Modern remote license challenge flows,POST/custom bodies,wrappers and
  manifest-embedded key discovery are still Stage1C work. No guessed GET is
  substituted for a modern standard-license declaration.
- Refresh observed metadata so an old ClearKey key is not reused after the
  source becomes unprotected/another DRM;HLS manifests are not channel lists.
- Owned parser-to-two-key decode and negative/isolation regressions extend
  the existing native tests. Real user secrets never enter public tests/CI.

## CK5 Live Stability Candidate

- Well-described single-period live DASH with one video adaptation group can
  select its highest declared resolution/bitrate before probing components.
  The optional local LGPL DASH ID filter also runs on manifest refresh.
- Audio/subtitles and source URL/template resolution are retained. Missing or
  ambiguous selected IDs fail rather than silently changing quality or keys.
- Selected streams avoid bitrate hopping;first playback needs1.5seconds of
  reserve plus decoded frames,refill needs4seconds,and reserve is capped20s.
  Other manifest shapes and ordinary-player routing retain their old options.
- Safe monotonic stage timings and rebuffer counts aid physical comparisons.
  Ready means the engine became playable,not an independently observed frame.
- Owned native regressions deliberately break unused renditions and verify
  selected video/audio still decode. No live iPhone stall-fix claim is made
  from PC metadata,source inspection or simulator evidence alone.

## CK6 Live-Window Candidate

- User-reported CK5 ON playback still freezes after a first picture and never
  reaches playable state;CK5 is NOT accepted as a physical stability fix.
- Pinned DASH timeline startup falls back60seconds from the end. An opt-in
  local core option now starts6seconds back for the selected live-video plan,
  keeping video/audio away from an expiring30second DVR boundary.
- The old60second default remains when the option is absent/zero. Ordinary
  routing,keys,TLS,source templates and the30second startup watchdog remain.
- Owned rolling live tests use moving encrypted video/stereo,different keys,
  expired/unpublished segment rejection and actual engine/render progression.
  They compare legacy old-edge selection with near-live video/audio start ages.
- Selected live refresh converts global segment numbers into relative timeline
  indices and back,without truncating audio timing to whole seconds. At the
  live edge it waits interruptibly up to20seconds instead of skipping through
  unpublished fragment numbers. The default/ordinary paths remain unchanged.
- The owned fixture uses large segment numbers like production sources;tests
  require steady8second progression and zero future/expired fragment requests.
- Safe queue diagnostics show decoded frames,packet counts and fps;Ready-- is
  not interpreted as smooth playback merely because a first frame appeared.
- Simulator/live-fixture results are not physical ON stability proof.
