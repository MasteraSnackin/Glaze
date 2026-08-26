# Build Notes

Platform/toolchain gotchas and their workarounds. Loaded on demand.

## macOS App Sandbox and the Codex ChatGPT provider

The desktop ChatGPT connection starts the user's installed `codex app-server`
executable. A macOS App Sandbox build cannot execute an arbitrary CLI from the
user's home directory or Homebrew installation. `Release.entitlements`
therefore retains App Sandbox, and release-mode code hides and rejects this
provider on macOS. The local Debug and Profile configurations use
`DebugProfile.entitlements`, which is deliberately unsandboxed so a developer
running the source checkout can launch the external CLI. Those builds are for
local development, not distribution. A distributable macOS implementation
would need a compatible helper bundled and signed inside the application.

Windows and Linux releases, plus local macOS Debug/Profile builds, accept
exactly the native Codex CLI 0.147.0 and 0.149.0 executables. Script and npm
wrappers are rejected on every platform. Each process receives a Glaze-owned
`CODEX_HOME` and `CODEX_SQLITE_HOME`, a small environment allowlist with no
inherited authentication, proxy or custom-CA variables, and a private working
directory beneath the isolated profile. Threads are ephemeral and read-only,
with network disabled for sandboxed tools, no approvals, no dynamic tools and
no external instruction sources. The release-effective
`CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED=1` startup marker disables
persisted App Server remote control before worker threads start. The provider
itself retains the network access needed for browser OAuth, token refresh and
ChatGPT response generation. `--strict-config` makes Codex fail at startup
rather than silently ignoring an unsupported isolation setting.

App Server normally starts authenticated model-catalogue and managed-policy
work before its `initialize` handshake. Glaze avoids that race in three ways:

- it materialises the audited Codex 0.147.0 model catalogue from
  `assets/codex/model-catalog-0.147.0.json`, verifies SHA-256
  `20a56af9d9b33ebd124dcd94b4ab88a7cbdd66e5112aca076af41b1c3b0de0b4`,
  and pins `model_catalog_json` before process start. The three upstream GPT-5.6
  `code_mode_only` values are set to `null`, and all code-mode features are
  forced and verified false, so the model cannot start Codex's V8 code-mode
  helper;
- it first launches and verifies a credential-free temporary profile, then
  repeats every check against the real Glaze profile;
- it pins generation's `openai_base_url` to
  `https://chatgpt.com/backend-api/codex`, but pins the auxiliary
  `chatgpt_base_url` to the closed local TLS endpoint `https://127.0.0.1:1`.
  Browser OAuth and token refresh still use Codex's dedicated OpenAI auth
  endpoints. Auxiliary cloud-policy, plugin and remote-control work therefore
  has no usable route before verification.

The bundled catalogue is a safety-restricted derivative of OpenAI Codex
0.147.0 and remains under its Apache-2.0 terms;
`assets/codex/LICENSE-APACHE` and `assets/codex/NOTICE` retain the upstream
attribution. It is also accepted by the audited 0.149.0 App Server, but it is
static rather than account-specific. A model may therefore appear in Glaze even
when the signed-in plan cannot use it, and newly released models require a
reviewed catalogue update.

`CODEX_HOME` does not suppress every Codex configuration source by itself.
Before Glaze performs account access, browser sign-in, model listing or thread
creation, it reads the effective layered configuration and requires exactly its
own user and highest-precedence session layers plus Codex's built-in empty
system layer. Project, MDM, enterprise, legacy, unknown and non-empty system
layers fail closed. The effective provider must be the built-in `openai`
provider, its two base URLs and local catalogue path must match exactly, custom
provider definitions must be absent, managed requirements must be absent and
the MCP inventory must be empty. Account responses must confirm
`requiresOpenaiAuth`, and every created thread must report `openai` as its
provider at both response levels. `project_root_markers=[]` and private working
directories prevent project discovery. Immediately before every process start,
Glaze also refuses the audited host-policy sources: `/etc/codex` policy files,
macOS `com.openai.codex` managed preferences, Windows ProgramData policy files,
and the real Windows profile's `.agents\\skills` root. That Windows root is
checked separately because the audited Rust dependency resolves it through the
Shell rather than the isolated `USERPROFILE` variable.

Business, Enterprise and Education accounts are deliberately unsupported
because their workspace may provide managed Codex configuration. Glaze detects
those plan types after first-time OAuth, logs the isolated profile out
immediately and does not start a conversation. Personal and team-like plans are
supported only when their reported plan type is in the audited allowlist;
missing or future plan names fail closed. Settings also exposes **Reset ChatGPT
sign-in**. Authenticated App Server lifetimes are globally serialised because
Codex's refresh lock is process-local. Reset waits for the active process to
close and for shutdown to be verified, then deletes only `auth.json` and the
managed-policy cache inside Glaze's dedicated Codex home. This prevents a
concurrent token refresh from recreating a credential after reset.

The isolated profile also disables shell snapshot, shell/unified execution,
code mode, apps, plugins, MCP, memories, skills, web search, image generation,
computer use, multi-agent work, planning and user-input tools. Startup timeout
and user cancellation are propagated into both preflight and authenticated
process startup. A completion is delivered only after verified process
termination and private turn-workspace removal.

On Windows, Glaze launches only the native `codex.exe` process with shell
resolution disabled. It does not launch `codex.cmd` or another command-shell
wrapper, because terminating a wrapper would not reliably terminate the native
App Server child. A standalone Codex installation in
`%USERPROFILE%\.codex\packages\standalone\current\bin` is detected in addition
to a native executable already present on `PATH`. Shutdown uses the trusted
system `taskkill.exe /T /F` route and verifies that the native process exits.

## `path_provider_foundation` + `objective_c` on Windows

**Symptom:** `flutter build windows` fails while compiling a native asset hook.

**Cause:** Flutter compiles native asset hooks for *all* platforms when building
for one. Older `objective_c` build hooks used Apple-only configuration while
building on Windows and failed before the application was compiled.

**Bug report:** [dart-lang/native#2480](https://github.com/dart-lang/native/issues/2480) — "[hooks] Exclude a platform from being built by dependency's build hook". Open, milestone: Native Assets v1.x.

**Resolved 2026-07-16:** `objective_c 9.4.1` fixed its misconfigured build hook.
The `path_provider` overrides were removed after successfully building Windows
with `path_provider 2.1.6`, `path_provider_foundation 2.6.0`, and
`objective_c 9.4.1` on Flutter 3.44.0.

The general platform-exclusion request remains open in
[dart-lang/native#2480](https://github.com/dart-lang/native/issues/2480), but it
no longer blocks this dependency combination.

## MSVC 14.51+ rejects `<experimental/coroutine>`

**Symptom:** `flutter build windows` fails while compiling Windows plugins with:

```text
error STL1011: The /await compiler option, <experimental/coroutine>,
<experimental/generator>, and <experimental/resumable> are deprecated by
Microsoft and will be REMOVED SOON.
```

**Cause:** Some plugin/native dependencies still include the deprecated MSVC
experimental coroutine header. Visual Studio 18 / MSVC 14.51 promotes that to a
static assertion failure.

**Workaround (active):** `windows/CMakeLists.txt` defines
`_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS` globally for the Windows
build. Remove it once all affected Windows plugins stop depending on
`<experimental/coroutine>`.

## `app_settings` 6.1.x breaks iOS build with Xcode 16

**Symptom:** `flutter build ios` fails with:

```
Swift Compiler Error: Main actor-isolated static method 'register(with:)' cannot
be used to satisfy nonisolated requirement from protocol 'FlutterPlugin'
Swift Compiler Error: Main actor-isolated instance method 'handle(_:result:)'
cannot be used to satisfy nonisolated requirement from protocol 'FlutterPlugin'
```

**Cause:** Xcode 16 enforces Swift Concurrency strictly. `app_settings` 6.1.1
marks its plugin class `@MainActor` but `FlutterPlugin` requires `nonisolated`
implementations. Fixed upstream in `app_settings` 6.3.0.

**Fix (applied 2026-06-11):** bumped constraint to `^6.3.0` in `pubspec.yaml`.

## GitHub Actions `windows-latest` redirects to Windows Server 2025

**Symptom:** the Windows release workflow fails during
`subosito/flutter-action@v2` before `flutter pub get` or `flutter build windows`.
The log shows the runner image as `windows-2025` and the notice:

```text
windows-latest requests are being redirected to windows-2025-vs2026
```

**Cause:** GitHub started redirecting `windows-latest` to the Windows Server 2025
image. The Flutter setup/cache step is not reliable there yet for this workflow.

**Workaround (active):** `.github/workflows/build-branch.yml` pins the Windows
job to `windows-2022`. Revisit after `subosito/flutter-action` and the GitHub
Windows 2025 image settle.

## Android release APK: `Tag number over 30 is not supported`

**Symptom:** `flutter build apk --release` in CI fails at `:app:packageRelease`:

```text
com.android.ide.common.signing.KeytoolException: Failed to read key <alias>
from store ".../android/<name>.keystore": Tag number over 30 is not supported
```

**Cause:** the signing keystore is passed to Gradle as a base64 secret. A secret
that does not exist in the repository (e.g. after moving the project to a new
GitHub repo — secrets do not travel with the code, and the new repo used
different secret names) still reaches the build as an **empty string**, not as an
unset variable. The old `if (ks != null)` check in `android/app/build.gradle.kts`
therefore passed, `Base64.decode("")` produced 0 bytes, and a 0-byte keystore was
written and handed to AGP. Loading an empty file as PKCS12 makes the JDK DER
parser read tag `-1`, and `-1 and 0x1f == 0x1f` is reported as *"Tag number over
30 is not supported"* — the message says nothing about the file being empty.

**Signing secrets (repository → Settings → Secrets and variables → Actions):**

| Secret | Gradle env | Purpose |
|---|---|---|
| `ANDROID_KEYSTORE_BASE64` | `KEYSTORE_BASE64` | keystore file, base64 of the raw bytes |
| `ANDROID_STORE_PASSWORD` | `KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | `KEY_ALIAS` | alias of the signing key |
| `ANDROID_KEY_PASSWORD` | `KEY_PASSWORD` | password of that key |

All four are required together; the decoded keystore is written to
`android/ci-signing.keystore` (gitignored). Without `KEYSTORE_BASE64` the build
falls back to the local debug signing config, which is what local builds use.

**Fix (applied 2026-07-26):**
- `android/app/build.gradle.kts` treats a blank `KEYSTORE_BASE64` as "no CI
  keystore", tolerates wrapped base64, always rewrites the keystore file,
  requires the other three values to be non-blank, and verifies that the decoded
  store loads and contains `KEY_ALIAS` — failing with an explicit message
  otherwise.
- Both Android workflows read the `ANDROID_*` secrets (they previously looked
  for a `DEBUG_KEYSTORE_BASE64` secret that no longer exists, with alias and
  passwords hardcoded to `debug-key`/`android`) and gained a `Verify signing
  keystore` step that runs before the ~8-minute Gradle build and reports a
  missing, non-base64 or unreadable secret immediately.

**To (re-)create the base64 secret** from the keystore file:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("upload-key.keystore")) | Set-Clipboard
```

Do not paste the output of `certutil -encode` or a file that was re-saved as
text — either mangles the bytes. If the keystore itself is gone, generate a new
one (`keytool -genkeypair -keystore upload-key.keystore -storetype PKCS12 -alias
<ANDROID_KEY_ALIAS> -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Glaze"`)
and update all four secrets; note that a new key changes the APK signature, so
existing installs must be uninstalled before updating.
