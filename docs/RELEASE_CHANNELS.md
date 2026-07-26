# Release channels

Three long-lived branches, one per build channel. The channel decides whether a
build ships developer tooling — developer mode and the build watermark.

| Branch    | Channel   | Dev mode default | Watermark default | Audience              |
|-----------|-----------|------------------|-------------------|-----------------------|
| `stable`  | `stable`  | off              | off               | public releases       |
| `staging` | `staging` | **on**           | **on**            | testers / release RCs |
| `nightly` | `nightly` | **on**           | **on**            | daily internal builds |
| any other | `nightly` | **on**           | **on**            | feature branches      |

`stable` is the repository default branch. Branching and promotion rules live in
[`WORKFLOW.md`](./WORKFLOW.md).

## How the channel reaches the app

CI derives the channel from the branch it is building and injects it as a
compile-time define (`.github/workflows/build-branch.yml`, `metadata` job):

```bash
case "$BUILD_BRANCH" in
  stable)  BUILD_CHANNEL=stable  ;;
  staging) BUILD_CHANNEL=staging ;;
  *)       BUILD_CHANNEL=nightly ;;
esac
```

It is passed to all three build jobs (Android, Windows, iOS) alongside the
existing defines:

```
--dart-define=BUILD_CHANNEL=${{ needs.metadata.outputs.build_channel }}
```

`lib/core/constants/build_channel.dart` reads it back:

```dart
const buildChannel = String.fromEnvironment('BUILD_CHANNEL', defaultValue: 'nightly');
const isStableChannel = buildChannel == 'stable';
const devToolingEnabledByDefault = !isStableChannel;
```

The default is `nightly`, so a local `flutter run` — which never passes the
define — keeps dev tooling on. Nothing about the developer experience changes.

## What the channel actually controls

Only the **defaults** of two persisted settings in
`lib/core/state/dev_mode_provider.dart`:

```dart
// devModeProvider
return prefs?.getBool(_prefsKey) ?? devToolingEnabledByDefault;

// hideBuildWatermarkProvider  (note: "hide", so stable → hidden)
return prefs?.getBool(_prefsKey) ?? isStableChannel;
```

Two consequences worth being explicit about:

- **A user's own choice still wins.** Both values are persisted in
  `SharedPreferences`; the channel only supplies the value used when nothing has
  been stored yet.
- **`stable` is not a lockout.** The 7-tap easter egg on the version badge
  (`lib/features/menu/about_screen.dart`) still unlocks dev mode on a stable
  build, and the watermark can then be switched back on from the Dev group for
  diagnostics. This is deliberate — it keeps production builds debuggable.

If you ever need the watermark to be genuinely unreachable on `stable`, gate the
widget itself on `!isStableChannel` in `lib/app.dart` rather than changing the
default — that is a behaviour change, not a default change.

## Adding a new channel

1. Add the branch name to the `case` in the workflow's `metadata` job.
2. If it needs different dev-tooling behaviour, extend
   `build_channel.dart` — keep the derived flags `const` so they tree-shake.

Do not read `buildChannel` directly in feature code; depend on the derived
booleans instead, so the channel list stays in one place.
