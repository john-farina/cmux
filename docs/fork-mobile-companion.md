# cmux iphone companion — end-to-end survey (fork notes)

survey of the iOS companion app, its mac-side host, auth, pairing, transport, and the fork build/debug workflow. line refs are as of this writing; regenerate with the greps in each section if drifted.

## 1. architecture map

### phone side

app shell lives in `ios/` (xcworkspace `ios/cmux.xcworkspace`, xcconfigs in `ios/Config/`). the app target is a thin wrapper; nearly all code is SPM packages.

| package | owns |
|---|---|
| `ios/cmuxPackage/Sources/cmuxFeature/` | composition roots only: `MobileAuthComposition.swift` (auth graph), `CMUXMobileRuntime.swift` (transport + token providers for the RPC layer), `CMUXMobileRootScene.swift` (builds `CMUXMobileShellStore`, injects everything into SwiftUI environment) |
| `Packages/iOS/CmuxMobileShell` | the store/composite (`MobileShellComposite.swift`), pairing preflight (`MobilePairingAccountPreflight.swift`), device registry (`DeviceRegistryService.swift`), presence (`PresenceClient.swift`, `PresenceServiceConfiguration.swift`), paired-mac backup (`BackingUpPairedMacStore.swift`, `PairedMacBackupClient.swift`) |
| `Packages/iOS/CmuxMobileShellModel` | pure value models: `MobileConnectionState`, `MobileWorkspacePreview`, `MobileShellPhase`, `MobileBuildType`, `MobilePairingURLConnectionResult` |
| `Packages/iOS/CmuxMobileShellUI` | all screens: `CMUXMobileRootView.swift` (deep-link gate at :153), `CMUXMobileAppView.swift`, `WorkspaceDetailView.swift`, `MacComputerDetailView.swift`, `MobileSettingsView.swift` |
| `Packages/iOS/CmuxMobileRPC` | phone-side RPC client + session (`MobileCoreRPCClient.swift`, `MobileCoreRPCSession.swift`), event envelopes (`MobileEventEnvelope.swift`, `MobileTerminalBytesEvent.swift`, …), connect-attempt registry (`MobileRPCConnectAttemptRegistry.swift`) |
| `Packages/iOS/CmuxMobileTransport` | the wire: `CmxNetworkByteTransport.swift` (NWConnection dialer + `CmxConnectFailureKind` classification), `CmxNetworkRoutePinger.swift`, `TailscaleStatusMonitor.swift` (phone-side tailnet detection), `ReachabilityService.swift` |
| `Packages/iOS/CmuxMobileTerminal` / `CmuxMobileTerminalKit` | ghostty surface (`GhosttySurfaceView.swift`, `GhosttyRuntime.swift`), input accessory, key encoding (kit is the pure-logic half) |
| `Packages/iOS/CmuxMobileWorkspace` | pure policies: `MobilePairingScannerPolicy.swift`, `MobileRootAuthGate.swift`, safe-area/layout policies |
| `Packages/iOS/CmuxMobilePairedMac` | persisted paired-mac records (`MobilePairedMacStore.swift`) |
| `Packages/iOS/CmuxMobileCamera` | in-app QR scanner (`QRCodeCaptureController.swift`, `QRCodeScanStream.swift`) |
| `Packages/iOS/CmuxMobileDiagnostics` | `MobileDebugLogSink.swift` ring buffer + DEBUG file sink |
| `Packages/iOS/CmuxMobileBrowser`, `CmuxAgentChatUI`, `CmuxMobileAnalytics`, `CmuxMobileSupport` | browser pane, agent chat UI, analytics, misc UI support |

### shared

| package | owns |
|---|---|
| `Packages/Shared/CMUXMobileCore` | wire/protocol types both sides speak: `CmxAttachTicket` (compact coder), `CmxPairingQRCode.swift` (v2 QR grammar), `CmxPairingURLScheme.swift` (channel schemes), `CmxTransport.swift`, `MobileSyncProtocol.swift`, render-grid types |
| `Packages/Shared/CmuxAuthRuntime` | the auth graph both apps use: `Coordinator/AuthCoordinator.swift`, `Client/StackAuthClient.swift`, `BrowserSignIn/HostBrowserSignInFlow.swift` (mac), `TokenStores/`, `Push/PushRegistrationService.swift`, `Diagnostics/AuthDebugLog.swift` |
| `Packages/Shared/CMUXAuthCore` | pure auth values (`CMUXAuthConfig`, caches, `CMUXAuthUser`) |
| `vendor/stack-auth-swift-sdk-prerelease` | stack SDK: `Sources/StackAuth/StackClientApp.swift` (oauth mechanics), `TokenStore.swift` |

### mac side (the host)

| file | owns |
|---|---|
| `Sources/Mobile/MobileHostService.swift` (2404 lines) | the whole host: NWListener, RPC dispatch (:1344–:1521), stack-auth gate (`authorizationError(for:)` :1287), ticket mint (`createAttachTicket` :1066), `statusUpdates()` :857, `.shared` :294, pairing on/off defaults key :474 |
| `Sources/Mobile/MobileHostService+Capabilities.swift` | `mobileHostCapabilities` — the capability strings advertised in `mobile.host.status` that iOS feature-detects against |
| `Sources/Mobile/MobileHostRPC.swift` | JSON-RPC envelope decode (`MobileHostRPCRequest`, `auth.attachToken` / `auth.stackAccessToken`) |
| `Sources/Mobile/MobileAttachTicketStore.swift` | ticket records + attach-url encoding (:131 `attachURL(for:)`, v2 QR preferred, v1 compact fallback :149) |
| `Sources/Mobile/MobileRouteResolver.swift` | computes advertised routes (tailscale hosts, 30s DNS cache) |
| `Sources/Mobile/MobileHostNetworkPathMonitor.swift` | NWPathMonitor → route republish trigger (dedup by path signature incl. local IPv4s) |
| `Sources/Mobile/Pairing/MobilePairingModel.swift` | pairing-window state machine (below) |
| `Sources/Mobile/Pairing/MobilePairingView.swift` / `MobilePairingWindowController.swift` | the "connect iPhone/iPad" window |
| `Sources/MobileConnectTitlebarAccessory.swift` | titlebar iphone button (posthog-flag gated :47 `isMobileConnectButtonEnabled`) |
| `Sources/Mobile/AgentChat/` | agent transcript/chat data plane served to the phone |
| `Sources/Mobile/MobileTerminalByteTee.swift`, `MobileTerminalRenderObserver.swift`, `MobileWorkspaceListObserver.swift` | terminal byte/render/workspace feeds into the event stream |

## 2. auth

### environments

two Stack projects, hardcoded in `Packages/Shared/CmuxAuthRuntime/.../Coordinator/AuthConfig.swift:44-48`: dev `454ecd03-…`, prod `9790718f-…`. dev api base `http://localhost:3000`, prod `https://cmux.com` (:53-60). DEBUG builds default to development, Release to production (`MobileAuthComposition.resolvedAuthEnvironment`, `ios/cmuxPackage/Sources/cmuxFeature/MobileAuthComposition.swift:193`).

### --prod-auth mechanics (issue 7145)

stack user ids are per-project, so a dev build's user id can never match a release mac's QR `ub` binding — pairing fails instantly even with the same email. `ios/scripts/reload.sh --prod-auth` (:135, :169-183):

- bakes `CMUXAuthEnvironment=production` into Info.plist via the `CMUX_IOS_AUTH_ENV` build setting (`ios/Config/Shared.xcconfig:37-49`); read back at `MobileAuthComposition.swift:168` (`authEnvironmentInfoPlistKey`). a bundled `LocalConfig.plist` `AuthEnvironment` entry wins over the bake (:175-186).
- presence follows the AUTH channel, not the build config: `CMUXMobileRootScene.makePresenceClient()` (`CMUXMobileRootScene.swift:167-182`) passes `isDevelopmentAuthChannel` into `PresenceClient.resolvedServiceBaseURL` (`Packages/iOS/CmuxMobileShell/.../PresenceServiceConfiguration.swift:40`), so a --prod-auth build subscribes to `https://presence.cmux.dev` and release macs appear in Computers.
- skips dogfood auto sign-in/auto-pair (those creds are dev-project; reload.sh:183).
- project-switch detection: `MobileAuthComposition.detectAuthProjectSwitch` (:265) persists the resolved project id under `auth_stack_project_id`; switching channels on one install clears the previous project's session via `AuthLaunchOptions.clearStaleAuthOnLaunch` so you start signed out instead of restoring a foreign identity.

### sign-in methods

all flows live on `AuthCoordinator` (`Coordinator/AuthCoordinator.swift`):

| method | entry | mechanics |
|---|---|---|
| oauth (apple/google/github) | `signInWithApple/Google/GitHub` :287-293 → `signInWithOAuth` :295 | stack SDK `StackClientApp.swift:263-315`: `ASWebAuthenticationSession` with `callbackURLScheme: "stack-auth-mobile-oauth-url"` (:279); apple uses native ASAuthorizationController. bounded by `timeouts.interactiveFlow` because system-sheet callbacks are not guaranteed to fire (:303-309) |
| email code | `sendCode(to:)` :216 (magic-link email, nonce kept in `pendingNonce`) → `verifyCode(_:)` :242 |
| debug `42` | typing `42` in the email field (`sendCode` :221) signs in with fixed dev creds `l@l.com`/`abc123`; enabled only when the RESOLVED environment is development — a --prod-auth build compiles the shortcut but never exposes it (`MobileAuthComposition.includesDevAuth` :215) |
| external seed (mac) | `completeExternalSignIn()` :394 — the mac hosted-browser flow (`BrowserSignIn/HostBrowserSignInFlow.swift`, `beginSignIn()` :69) seeds tokens into the store then validates |

### tokens

- simulator DEBUG: in-memory store; device + release: keychain (`MobileAuthComposition.tokenStore` :283-289, backed by `TokenStores/KeychainStackTokenStore.swift`).
- keychain tokens are project-scoped and can outlive UserDefaults (reinstalls) — the project-switch clear deliberately ignores whether defaults look empty (`MobileAuthComposition.swift:246-255`).
- `UserDefaults` carries only `auth_has_tokens`, `auth_cached_user`, `auth_selected_team`.
- DEBUG env override `CMUX_MOBILE_DEV_STACK_AUTH_TOKEN` short-circuits all token providers (`CMUXMobileRuntime.swift:178-190`).

### preflight / cancellation semantics

- every sign-in entrypoint calls `beginSignInFlow()` (`AuthCoordinator.swift:121`) BEFORE its first await: allocates a monotonic attempt id, then `waitForSessionTokenWorkToQuiesceBeforeSignIn()` (`Coordinator/AuthCoordinator+SignInTokenWorkPreflight.swift:5`) cancels and joins every in-flight validation/token-phase/older exchange, bounded by `timeouts.network` (throws `AuthError.timedOut` if the old work won't quiesce, :49). after quiescing it re-checks `sessionGeneration`/`signOutEpoch` and throws `CancellationError` if a sign-out landed meanwhile (:125).
- staleness model: `sessionGeneration` (bumped on every clear AND publish, :88), `signOutEpoch` (bumped synchronously at sign-out top, :97), `tokenStoreWriteHighWater` (last attempt that wrote the token store, :108). `completeSignIn` :323 rolls back a raced exchange's token write when a sign-out began after the flow started and no newer attempt owns the store (:353-368).
- 30s token reset: `tokenTouchingTimedOutResetNanoseconds = 30_000_000_000` (`AuthCoordinator.swift:115`) — after a token-touching phase (fetchUser/listTeams) times out, that phase's timed-out state blocks/settles for 30s before retries are allowed again (`Coordinator/AuthCoordinator+TokenTouchingPhaseTimeout.swift`).
- sign-out is local-first (:439): cancel in-flight exchanges → bump epochs → capture tokens raw → clear local store → bounded (5s default) best-effort server teardown (push-token delete then stack revocation).

## 3. pairing

### QR payload (v2 grammar)

`Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/CmxPairingQRCode.swift:6`:

```
cmux-ios://attach?v=2&ub=<stack-user-id>&pc=<compat>&av=<version>&ab=<build>&r=<host>:<port>[&r=…]
```

- `ub` = the mac owner's opaque stack user id (never email). `r` = bare tailscale `host:port` routes only; loopback is dropped at encode (:62), refused at mint (mac shows set-up-tailscale instead), and rejected at decode (:189 throws `loopbackRouteRejected`) — a scanned code can never point the phone at itself.
- no auth token, no expiry: the ticket's bearer token authorizes nothing (stack auth is the sole gate); a displayed QR never goes stale. display name/device id arrive post-handshake from `mobile.host.status` (decoder leaves `macDeviceID` empty, :199-212).
- max 8 routes defensively (:50). plain-text URL keeps the QR version low so it scans fast.
- v1 fallback (compact base64 JSON payload) survives for workspace-scoped/dev-loopback tickets and all RPC consumers (`Sources/Mobile/MobileAttachTicketStore.swift:145-158`).

### url schemes are channel-specific

`CmxPairingURLScheme.swift:32`: release builds register/emit `cmux-ios`, dev builds `cmux-ios-dev` (registered scheme comes from `CMUX_IOS_URL_SCHEME` in `ios/Config/Shared.xcconfig:80` / `Release.xcconfig`). the system Camera routes by registered scheme, so a release mac's QR always opens the release app — scanning a release QR with a dev build only works via the **in-app** scanner, which accepts every channel's scheme (`Packages/iOS/CmuxMobileWorkspace/.../MobilePairingScannerPolicy.swift:19` → `CmxPairingURLScheme.hasPairingScheme`). deep links land at `CMUXMobileRootView.swift:153` (`.onOpenURL`; pre-auth URLs are parked in `pendingAttachURL`).

### what validates what

1. phone-side preflight before any dial: `MobilePairingAccountPreflight.failure(for:)` (`Packages/iOS/CmuxMobileShell/.../MobilePairingAccountPreflight.swift:39`) — when the ticket carries `ub` it must equal the phone's stack user id (email is never consulted); mismatch + differing declared channels (scheme) → `authEnvironmentMismatch`, same-channel mismatch → `authFailed`; legacy no-`ub` tickets fall back to email comparison; signed-out/restoring phone stays silent and lets the host decide.
2. host-side, per-request: `MobileHostService.authorizationError(for:)` (`Sources/Mobile/MobileHostService.swift:1287`) — every data-plane request must present a stack access token that verifies against the SAME account signed in on the mac (`MobileHostStackAuthVerifier` :1776). distinct `account_mismatch` error code drives re-auth UI on the phone. the attach ticket is route-discovery/workspace-selection only.

### MobilePairingModel states (mac window)

`Sources/Mobile/Pairing/MobilePairingModel.swift:20`: `loading → signedOut | preparing → ready(Ready) ⇄ connected(Ready) | needsTailscale | failed(String)`.

- `refresh()` :92: await auth bootstrap → signed out? → enable pairing host (defaults key) → `ensureListeningAndReady()` → no phone-reachable tailscale route → `needsTailscale` :132 → mint ticket (`createAttachTicket`, ttl 600s, covers only the v1/RPC fallback token) → assert the URL speaks the v2 grammar (:156, else `needsTailscale`) → `ready`.
- `ready ⇄ connected` flips on connection count above the baseline captured when the code was shown (`connectionTransition` :235) so pairing a second phone works while one is attached.
- codes never expire and never auto-regenerate; Refresh re-mints on demand.

## 4. transport

- **direct dial only, no relay.** the phone dials the QR's tailscale `host:port` routes with `CmxNetworkByteTransport` (`Packages/iOS/CmuxMobileTransport/.../CmxNetworkByteTransport.swift`, NWConnection; failure classified into `CmxConnectFailureKind` :8 — connectionRefused = mac app closed/pairing off, hostUnreachable = off tailnet/asleep, permissionDenied = iOS Local Network permission, etc. — so the UI can say something actionable). there is no traffic relay at cmux.com; if the phone and mac don't share a tailnet, nothing connects.
- **presence worker is discovery, not transport**: `PresenceClient` (`Packages/iOS/CmuxMobileShell/.../PresenceClient.swift`) subscribes to a cloudflare durable object the macs heartbeat to (`presence.cmux.dev` prod / `cmux-presence-dev.debussy.workers.dev` dev; override precedence env `CMUX_PRESENCE_BASE_URL` → defaults `presenceServiceURL` → baked Info.plist `CMUXPresenceBaseURL` → auth-channel default, `PresenceServiceConfiguration.swift:40-61`). it powers the Computers list + paired-mac backup (`PairedMacBackupClient.swift`); pairing state also mirrors into the team device registry (`DeviceRegistryService.swift`, `https://cmux.com` api).
- **runtime wiring**: `CMUXMobileRuntime` (`ios/cmuxPackage/Sources/cmuxFeature/CMUXMobileRuntime.swift`) supplies supported route kinds (`[.tailscale, .debugLoopback]` :130), the transport factory, and three token closures (provider / status / force-refresher :16-22 — force-refresh is called exactly once after a host auth rejection). timeouts: rpc 30s, pairing request/attempt 8s (:10-12).
- **reconnection**: `MobileRPCConnectAttemptRegistry` (`Packages/iOS/CmuxMobileRPC/.../MobileRPCConnectAttemptRegistry.swift:15`) leases routes per connect attempt; abandoned-cleanup twice in a row hard-gates a route for 30s so repeated scans can't pile up unclosed transports. server-push events preferred; legacy 750ms poll only for hosts without `events.v1` (`CMUXMobileRuntime.swift:27-32`).
- **network change handling**: mac side `MobileHostNetworkPathMonitor.swift` triggers route republish on real path changes (path signature includes local IPv4s); phone side `TailscaleStatusMonitor.swift` re-evaluates on NWPath changes + foreground `refresh()` and drives the "tailscale is off" guidance in pairing/disconnected surfaces.

## 5. fork build workflow

### phone build

`scripts/ios-phone-build.sh` (fork-added, 11 lines):

```bash
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"   # Xcode 26.6 — Xcode21 (26.0.1) swift is too old for the mobile packages
export IOS_DEVELOPMENT_TEAM="${IOS_DEVELOPMENT_TEAM:-9QFLC277YH}"                      # Triumph dev team
exec ios/scripts/reload.sh --tag john --device-only --prod-auth --allow-device-registration "$@"
```

- `--device-only`: skip simulator, install to first paired iPhone (reload.sh:89).
- `--prod-auth`: production stack project + presence (see §2; reload.sh:135).
- `--allow-device-registration`: allows provisioning updates for a new device (reload.sh:115; requires `-allowProvisioningUpdates`).
- bundle id becomes `dev.cmux.ios.<tag>` → `dev.cmux.ios.john` (reload.sh:205).
- launch: `xcrun devicectl device process launch --terminate-existing` (reload.sh:659). "device locked" warning means unlock and tap.
- surfaced in cmux as the agent launch template `"Build iPhone App to Phone"` (`~/.config/cmux/cmux.json` templates array, cwd `~/Developer/cmux`, command `scripts/ios-phone-build.sh`).

### mac-side entry points

`Sources/cmuxApp+ForkMenu.swift` (Toolbelt menu): "Connect iPhone/iPad" :34 (`MobilePairingWindowController.shared.show()` — unconditional, because the titlebar iphone button in `Sources/MobileConnectTitlebarAccessory.swift:47` is posthog-flag-gated and can vanish on fork builds), "Sign In" :40 (`auth.browserSignIn.beginSignIn()`), "Sign Out" :50.

### auto sign-in note

`ios/scripts/reload.sh` / `scripts/mobile-dev-launch.sh` auto-auth DEBUG builds from `~/.secrets/cmuxterm-dev.env` — dev-channel creds only; a `--prod-auth` build skips it and you sign in in-app with your real account (reload.sh:183, :564).

## 6. debugging both sides

### mac

```bash
# /usr/bin/log — zsh shadows `log`
/usr/bin/log show --last 2h --predicate 'subsystem == "com.cmuxterm.app"'
/usr/bin/log show --last 1d --predicate 'subsystem == "com.cmuxterm.app" AND category == "auth"'
```

`mobileHostLog` lines (authorization rejections at `MobileHostService.swift:1310,1316`) and `AuthDebugLog` both land there. macOS DEBUG builds additionally tail `/tmp/cmux-auth-debug.log` (`AuthDebugLog.swift:32`).

### phone (DEBUG builds)

two on-device files, both in the app's Documents/ so they're pullable:

| file | writer |
|---|---|
| `Documents/cmux-auth-debug.log` | `AuthDebugLog` (`Packages/Shared/CmuxAuthRuntime/.../Diagnostics/AuthDebugLog.swift:36-38`) — every auth line, redacted (tokens/JWTs/emails stripped :61) |
| `Documents/cmux-debug.log` | `MobileDebugLogSink` file mirror (`Packages/iOS/CmuxMobileDiagnostics/.../MobileDebugLogSink.swift:90-92`; 10MB reset :96) |

pull off the device:

```bash
xcrun devicectl list devices                      # CoreDevice UUID (not the UDID)
xcrun devicectl device copy from \
  --device <coredevice-uuid> \
  --domain-type appDataContainer --domain-identifier dev.cmux.ios.john \
  --source Documents/cmux-auth-debug.log --destination /tmp/
```

`sudo log collect --device-udid <udid>` also works for the unified log but is USB-only and flaky — prefer the Documents files.

### in-app diagnostics

- `MobileDebugLogSink` is a 4000-line actor ring buffer (`MobileDebugLogSink.swift:11`); `MobileDebugLog.shared.copyToPasteboard` is exposed from the workspace-detail overflow menu ("copy debug logs", `Packages/iOS/CmuxMobileShellUI/.../WorkspaceDetailView.swift:440-464`).
- Send Feedback (same menu, :498-560) ships the debug log + visible terminal straight to the paired mac via `dogfood.feedback.submit` (capability `dogfood.v1`, `MobileHostService+Capabilities.swift`; DEBUG shells also carry the structured `DiagnosticLog` injected at `CMUXMobileRootScene.swift:288`).
- connection failures are pre-classified (`CmxConnectFailureKind`) — read the failure kind in the log before theorizing about the network.

## 7. how to extend

- **new phone screen/feature**: views in `Packages/iOS/CmuxMobileShellUI` (state snapshots + action closures — the snapshot-boundary rule from CLAUDE.md applies to any lazy list), state/logic on `MobileShellComposite` (`Packages/iOS/CmuxMobileShell`), pure policy types in `CmuxMobileWorkspace`/`CmuxMobileShellModel` so they unit-test without a store. wire dependencies at `CMUXMobileRootScene.makeStore()` (`CMUXMobileRootScene.swift:262`). new package → `Packages/iOS/<name>` and regenerate the workspace with `python3 scripts/check-workspace-package-groups.py --write`; conventions linted by `scripts/lint-ios-package-conventions.sh`.
- **new RPC between phone and mac**: mac handler in the `MobileHostService.swift` dispatch (:1344/:1389 region; add the method to `requiresAuthorization` intentionally — stack auth is the sole gate), advertise a capability string in `MobileHostService+Capabilities.swift` so old apps degrade, phone request/response types in `Packages/iOS/CmuxMobileRPC`, wire types shared by both sides in `Packages/Shared/CMUXMobileCore` (`MobileSyncProtocol.swift`). iOS must feature-detect on the capability, never on version.
- **localization**: every user-facing string on both sides uses `String(localized:defaultValue:)`; mac keys in `Resources/Localizable.xcstrings`, phone keys in the owning package's xcstrings (`CmuxMobileSupport/L10n.swift` helper). audit en + ja before handoff (CLAUDE.md localization rule).
- **logging**: mac probes via `CmuxLog` (`Sources/App/DebugLogging.swift`) — kebab-case category, `key=value` lines, decisions + skip reasons, never scrollback/env/full commands. phone: `MobileDebugLog`/`DiagnosticEvent` for shell paths, `AuthDebugLog` for anything auth-adjacent (it redacts). permanent probes use these; `cmuxDebugLog` DEBUG-only probes get removed before commit.
