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
- Multikey HLS,dynamic license renewal and a blanket key
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

## CK7 Inflated-Rate Candidate

- Physical CK6 reports still froze before becoming playable. Safe queue
  diagnostics exposed600fps video despite declared25fps;reserve computation
  divides queued frames/packets by FPS,so even many packets can fail startup.
- Selected live plans parse integer/rational/inherited MPD frameRate. Correct
  only invalid/nonpositive or wildly inflated probe rates before video queue
  and decoder creation,using a validated1..120fps declaration. No guessed FPS.
- Keep ordinary routes,audio,normal25/50/60/120fps,missing/unsafe declarations,
  source/key/TLS policy and startup/refill/watchdog unchanged. Upstream interlace
  processing still controls filtering and any doubled output rate.
- Tests reproduce inflated-rate capacity starvation and inject600fps into the
  actual owned live controller/decoder pipeline. Require legacy-blocked control
  and corrected steady clock/render progression,not merely one primed frame.
- Candidate tests and physical-device acceptance must be recorded separately.

## CK8 Stage1C License Candidate

- Modern ClearKey HTTP server_url performs a temporary JSON POST based on
  declared CENC DASH key IDs. Legacy empty-body GET/inline/data paths retained.
- Supported declared legacy/modern challenge templates and legacy raw/base64/
  root-JSON response wrappers are validated;unknown/session/PSSH/HDCP/persistent
  policies fail explicitly. No guessed keys,requests or GET fallback.
- License-only headers for new POST flows,ephemeral nonpersistent sessions,
  streaming size bounds,5redirect limit,origin-safe license redirects and
  unchanged30s player startup deadline. Canceled generations cannot attach
  a stale player. New manifest-first licensed live starts favor3s reserve;
  CK7legacy1.5s startup,4s refill and ordinary routing remain unchanged.
- Owned tests cover actual licensing,two-key decoder output,moving live engine,
  negative replies,header/cookie isolation,redirects,streaming bounds and cancel.
- Standards references:[W3C Clear Key](https://www.w3.org/TR/encrypted-media/#clear-key),
  [Kodi metadata](https://github.com/xbmc/inputstream.adaptive/wiki/Integration-DRM),
  [legacy templates](https://github.com/xbmc/inputstream.adaptive/wiki/Integration-DRM-(old)).
- Source implementation is independently written;no Kodi GPL decoder code is
  copied. Live fetching/renewal and remaining roadmap features are separate
  checkpoints. Candidate native/physical acceptance must be recorded separately.

## CK9 Stage1D Declared-Key Changes

- Monitor only explicitly dynamic,single-period DASH with declared CENC IDs
  and a positive minimumUpdatePeriod,clamped to2..60s. Enable for manifest-first
  authorized POST challenges or consistent supplied multikey inline maps.
  Legacy remote GET and inconsistent single-key compatibility stay untouched.
- Unchanged IDs do not acquire licenses or rebuild. Newly declared IDs must
  be present in supplied maps or returned by the same authorized license flow.
  Reject missing/conflicting/persistent replies;no guessed keys or GET fallback.
- Replace the real player/context after a validated changed ID set. Pinned
  KSPlayer set(url:same,options:new) alone does NOT reload decoder options.
  In-flight updates cannot reopen a closed/failed generation;user pause defers
  applying completed updates until Play. Keys remain memory-only,bounded128
  per playback session. This checkpoint can briefly rebuffer at a key change.
- Owned fixtures switch actual encrypted video init/fragments to a third key,
  while audio retains its distinct key. Test preloaded versus newly issued
  licenses separately;require changed decoder,steady clock/render progression,
  one acquisition,header isolation,negative replies,pause and close safety.
- Limits:MPD-ID changes only,not generic sample-group/init-only changes,same-ID
  key replacement,provider-specific expiration renewal,multiple periods or
  seamless switching. No new FairPlay/Widevine/PlayReady/CDM implementation is
  claimed. Real-provider key rotation still needs authorized physical testing.
- Owned64-byte URL revealed an upstream6.1 DASH scratch-buffer alignment bug:
  reserve the terminating NUL before64-byte alignment. Synthetic boundary
  decodes cover63/64/65/127/128/129 bytes without shortening the failing URL.

## CK10 Stage2A Manifest Preflight Recovery

- Only full manifest GET preflight requests can retry transient408/429/502/503/
  504 or connection-lost/connect/timeout failures:at most3attempts in ONE20s
  monotonic budget(or a caller's shorter timeout). Backoff0.25/0.75s;
  Retry-After seconds/HTTP dates are honored up to2s,long/invalid waits fail
  rather than retry early. License GET/POST,manifest POST/Range,auth,TLS,
  policy,size and parsing failures are never automatically retried.
- Each attempt uses a new ephemeral session,empty response buffer,no persistent
  cookies/credential cache and the SAME declared request. Async cancellation
  interrupts both active read and backoff;closed generations stay invalidated.
- Owned tests check exact request counts,partial-body discard,deadline/auth/
  license exclusions,concurrent header isolation and an actual moving encrypted
  video/stereo engine after two preflight503failures. No real-provider data.
- Scope is URLSession preflight,NOT FFmpeg segment reconnect,CDN credential
  isolation,cookie/token renewal,new fallback,FairPlay or universal DRM.
  PinnedFFmpeg6.1 forwards custom headers to its own HTTP paths;end-to-end
  origin policy needs a separate checked implementation,not this retry claim.
- HTTP reference:[RFC9110](https://www.rfc-editor.org/rfc/rfc9110.html#section-9.2.2).
  All remaining roadmap items and physical acceptance are tracked separately.

## Native Add-Link Integration

Local `patch_ipa.py --official` preserves the normal base bundle and app name,
and sets `CKNativeLinkMode=true`. This disables BOTH installation and opening
of the separate experimental input panel. The original native add-link UI and
executable sections are unchanged;the module passively observes successful
native URL/request completions,streamed Alamofire data and downloaded playlists.
The original callback/data/file/error still reaches its owner unchanged. Final
response URL resolves relative streams;ordinary/failed responses are not routed.
With `CKOriginalPlayerMode=true`,supported ClearKey entries retain the original
AVPlayer/asset/item and playback UI;the prototype controller/placeholder route
is not used. The independently retained experimental mode is not the official UI.
No new public server/provider credentials or source are included in this repo.

Owned native completion/download/redirect->registry->actual AVPlayer->moving
stereo engine tests do NOT execute the supplied ARM64 third-party app's actual
add-link UI. Manual physical import,relaunch/native cached-source behavior and
provider access remain separate verification. Metadata/keys stay bounded in
memory;there is no new raw-key persistence or universal DRM capability.

## Original Player Startup Reserve

Native remuxing stream-copies the selected video/default audio into bounded
memory-only fMP4 HLS. The asynchronous resource-loader redirect waits for real
media before handing the ready loopback master to AVPlayer. Live readiness now
requires at least three complete fragments AND three target durations of media,
not an unconditional six-GOP wait. Fractional/mixed durations cannot bypass the
reserve;finite EOF may expose its shorter real tail. Producer pause/backpressure
checks use the same readiness decision so an app waiting for ready before Play
does not deadlock. Native automatic stalling policy,TLS/key/transport rules,
stream-copy quality and the original UI are unchanged. Owned two/four-second
live fixtures measure first decoded frame and continuing stereo playback;
physical-device latency and long soaks remain separate release checks.
The native-only input lookback follows declared video-fragment duration with
a12-30second default bound,capped by an advertised shorter DVR window,so long
GOPs can prime from already-published media. Invalid,
unknown or finite metadata retains12s;audio duration cannot inflate the hint.
Legacy engine/core defaults and normal short-GOP sources remain unchanged.
On an authorized key update within the same validated live epoch/period,the
remux worker resumes at its last completely published video-keyframe boundary,
not the historical source point it has already appended. Unknown/changed or
multi-period epochs never inherit this boundary. The same original AVPlayerItem
and normal HLS initialization/discontinuity semantics are retained.

## CK11 Stage2B Fragment-Open Transport Recovery

CK12 extends this with a separately opt-in `ck_fragment_resume` option for
selected live DASH whole-resource GET media bodies. Only identity bodies with
known Content-Length and a strong ETag may resume after a partial read. The
same URL/stream headers use Range and If-Range from the bytes actually consumed,
not AVIO read-ahead. Before passing resumed bytes,the core verifies206,status,
exact Content-Range/remaining length,and the same strong ETag. At most two extra
requests share one interruptible five-second recovery budget per fragment.
Selected media disables opaque SDK reconnect so it cannot bypass this check.
Changed/ignored/malformed/ambiguous responses fail closed;no license replay or
decoder rebuild. Exported HTTP metadata is bounded,default-off and reset for
each response;public ABI is unchanged. Init/body range/unknown encoding or
length/weak validators are NOT covered. HTTP statuses,CDN credential policy,
provider key renewal,physical network interruption and universal DRM remain
separate open work. Owned native tests are not physical-provider proof.

- Only the selected live DASH route enablesck_fragment_retry(default0 in core).
  HTTP(S) GET fragment/init opens retry pre-body EOF/reset/refused/pipe/timeout
  errors with at most2extra attempts and one5s recovery budget after the normal
  first request. Backoff0.25/0.75s,remaining I/O/connect timeout and interrupt
  checks retain the same declared URL,headers and byte offsets.
- HTTP status/auth,TLS certificate/format/key errors and partial-body reads
  are not retried. No license request replay,no guessed tokens,no player
  replacement. Unrecoverable opens in the opt-in route fail rather than
  entering upstream's unlimited failed-fragment skipping loop.
- Owned tests exercise actual encrypted moving video/stereo after a mid-play
  pre-body disconnect,default-off/exhaustion/auth/server/deadline controls,
  cancellation and all prior key/source/player regressions. Require normal
  AND sanitized native gates before releasing modified C-core.
- Limits:pre-body OPEN recovery only,not mid-body resume,HTTP Retry-After/
  status recovery,cookie/token expiry,CDN credential isolation,HLS/FairPlay,
  seamless outages or a completed universal-DRM/player roadmap.
