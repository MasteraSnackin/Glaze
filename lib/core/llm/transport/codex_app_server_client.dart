import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import '../../utils/platform_paths.dart';

typedef _CfStringCreateNative =
    Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Uint32);
typedef _CfStringCreateDart =
    Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, int);
typedef _CfPreferencesCopyAppValueNative =
    Pointer<Void> Function(Pointer<Void>, Pointer<Void>);
typedef _CfPreferencesCopyAppValueDart =
    Pointer<Void> Function(Pointer<Void>, Pointer<Void>);
typedef _CfReleaseNative = Void Function(Pointer<Void>);
typedef _CfReleaseDart = void Function(Pointer<Void>);

final class _WindowsGuid extends Struct {
  @Uint32()
  external int data1;

  @Uint16()
  external int data2;

  @Uint16()
  external int data3;

  @Array(8)
  external Array<Uint8> data4;
}

typedef _ShGetKnownFolderPathNative =
    Int32 Function(
      Pointer<_WindowsGuid>,
      Uint32,
      IntPtr,
      Pointer<Pointer<Utf16>>,
    );
typedef _ShGetKnownFolderPathDart =
    int Function(Pointer<_WindowsGuid>, int, int, Pointer<Pointer<Utf16>>);
typedef _CoTaskMemFreeNative = Void Function(Pointer<Void>);
typedef _CoTaskMemFreeDart = void Function(Pointer<Void>);

/// A typed notification emitted by Codex App Server.
class CodexAppServerNotification {
  const CodexAppServerNotification({
    required this.method,
    required this.params,
  });

  final String method;
  final Map<String, dynamic> params;
}

/// The narrow App Server surface consumed by Glaze.
///
/// Keeping this interface independent from [Process] makes the transport
/// deterministic to test and keeps process ownership in one place.
abstract interface class CodexAppServerSession {
  Stream<CodexAppServerNotification> get notifications;

  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]);

  void notify(String method, [Map<String, dynamic>? params]);

  Future<void> close();
}

class CodexAppServerException implements Exception {
  const CodexAppServerException(this.message);

  final String message;

  @override
  String toString() => message;
}

class CodexAppServerRpcException extends CodexAppServerException {
  const CodexAppServerRpcException(super.message, {this.code, this.data});

  final int? code;
  final Object? data;
}

class CodexNotInstalledException extends CodexAppServerException {
  const CodexNotInstalledException()
    : super(
        'Codex CLI was not found. Install Codex 0.147.0 or 0.149.0, then '
        'return here to sign in with ChatGPT.',
      );
}

class CodexUnsupportedPlatformException extends CodexAppServerException {
  const CodexUnsupportedPlatformException()
    : super(
        'ChatGPT subscription connections are available in Windows and Linux '
        'desktop builds, and in local macOS development builds.',
      );
}

class CodexIsolationException extends CodexAppServerException {
  const CodexIsolationException(super.message);
}

class CodexStartupCancelledException extends CodexAppServerException {
  const CodexStartupCancelledException()
    : super('Codex App Server startup was cancelled.');
}

/// Cancellation view passed into process startup without coupling the App
/// Server client to Dio or a particular UI cancellation type.
class CodexStartupCancellation {
  const CodexStartupCancellation({
    required this.isCancelled,
    required this.whenCancelled,
  });

  final bool Function() isCancelled;
  final Future<void> whenCancelled;
}

/// Serialises authenticated App Server lifetimes and credential deletion.
///
/// Codex's file-backed refresh lock is process-local, so two App Server
/// processes must not refresh the same rotating OAuth credential concurrently.
/// The same lease also makes reset wait until the active process has verified
/// shutdown before deleting the isolated credential.
class CodexSessionLifetimeCoordinator {
  CodexSessionLifetimeCoordinator._();

  static Future<void> _tail = Future<void>.value();

  static Future<CodexSessionLifetimeLease> acquire({
    CodexStartupCancellation? cancellation,
  }) async {
    final predecessor = _tail;
    final released = Completer<void>();
    _tail = predecessor.then<void>((_) => released.future);

    try {
      if (cancellation == null) {
        await predecessor;
      } else {
        if (cancellation.isCancelled()) {
          throw const CodexStartupCancelledException();
        }
        await Future.any<void>(<Future<void>>[
          predecessor,
          cancellation.whenCancelled.then<void>(
            (_) => throw const CodexStartupCancelledException(),
          ),
        ]);
        if (cancellation.isCancelled()) {
          throw const CodexStartupCancelledException();
        }
      }
      return CodexSessionLifetimeLease._(released);
    } catch (_) {
      // Preserve queue ordering if a waiter is cancelled. Its no-op slot is
      // released only after the predecessor, never while that process is live.
      unawaited(
        predecessor.whenComplete(() {
          if (!released.isCompleted) released.complete();
        }),
      );
      rethrow;
    }
  }

  static Future<T> runExclusive<T>(Future<T> Function() action) async {
    final lease = await acquire();
    try {
      return await action();
    } finally {
      lease.release();
    }
  }
}

class CodexSessionLifetimeLease {
  CodexSessionLifetimeLease._(this._released);

  final Completer<void> _released;

  void release() {
    if (!_released.isCompleted) _released.complete();
  }
}

/// Headerless, newline-delimited JSON RPC used by Codex App Server.
///
/// Codex responses and notifications can interleave. Requests are therefore
/// correlated by ID rather than by line order. Unknown response fields are
/// deliberately ignored so a newer CLI can add fields without breaking Glaze.
class CodexJsonLineSession implements CodexAppServerSession {
  CodexJsonLineSession(Stream<String> lines, this._writeLine) {
    _lineSubscription = lines.listen(
      _handleLine,
      onError: (Object error, StackTrace stackTrace) {
        fail(error, stackTrace);
      },
      onDone: () {
        if (!_closed) {
          fail(
            const CodexAppServerException(
              'Codex App Server closed before the request completed.',
            ),
          );
        }
      },
      cancelOnError: false,
    );
  }

  final void Function(String line) _writeLine;
  final Map<Object, Completer<Map<String, dynamic>>> _pending = {};
  final StreamController<CodexAppServerNotification> _notificationController =
      StreamController<CodexAppServerNotification>.broadcast();

  late final StreamSubscription<String> _lineSubscription;
  int _nextRequestId = 1;
  bool _closed = false;
  bool _failed = false;
  Object? _terminalError;

  @override
  Stream<CodexAppServerNotification> get notifications =>
      _notificationController.stream;

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) {
    if (_closed || _failed) {
      return Future<Map<String, dynamic>>.error(
        _terminalError ??
            const CodexAppServerException(
              'Codex App Server session is closed.',
            ),
      );
    }

    final id = _nextRequestId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    try {
      _send(<String, dynamic>{'method': method, 'id': id, 'params': params});
    } catch (error, stackTrace) {
      _pending.remove(id);
      completer.completeError(error, stackTrace);
    }
    return completer.future;
  }

  @override
  void notify(String method, [Map<String, dynamic>? params]) {
    if (_closed || _failed) {
      final error = _terminalError;
      if (error is CodexAppServerException) throw error;
      throw const CodexAppServerException(
        'Codex App Server session is unavailable.',
      );
    }
    _send(<String, dynamic>{'method': method, 'params': ?params});
  }

  void _send(Map<String, dynamic> envelope) {
    _writeLine(jsonEncode(envelope));
  }

  void _handleLine(String line) {
    if (_closed || _failed || line.trim().isEmpty) return;

    Map<String, dynamic> envelope;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) {
        throw const FormatException('Expected a JSON object');
      }
      envelope = Map<String, dynamic>.from(decoded);
    } catch (error) {
      fail(
        CodexAppServerException(
          'Codex App Server returned invalid protocol data: $error',
        ),
      );
      return;
    }

    final id = envelope['id'];
    if (id != null &&
        (envelope.containsKey('result') || envelope.containsKey('error'))) {
      final completer = _pending.remove(id);
      if (completer == null || completer.isCompleted) return;

      if (envelope.containsKey('error')) {
        final error = envelope['error'];
        final map = error is Map ? Map<String, dynamic>.from(error) : null;
        completer.completeError(
          CodexAppServerRpcException(
            map?['message']?.toString() ??
                error?.toString() ??
                'Codex App Server request failed.',
            code: map?['code'] is int ? map!['code'] as int : null,
            data: map?['data'],
          ),
        );
        return;
      }

      final result = envelope['result'];
      if (result is! Map) {
        completer.completeError(
          const CodexAppServerException(
            'Codex App Server returned a malformed response result.',
          ),
        );
        return;
      }
      completer.complete(Map<String, dynamic>.from(result));
      return;
    }

    final method = envelope['method'];
    if (method is! String) return;

    // App Server can ask the host to approve commands, edits or user input.
    // Glaze is a text-generation client and never grants or dispatches those
    // requests as ordinary generation notifications.
    if (id != null) {
      _send(<String, dynamic>{
        'id': id,
        'error': <String, dynamic>{
          'code': -32601,
          'message': 'Glaze does not permit Codex App Server requests.',
        },
      });
      return;
    }

    final rawParams = envelope['params'];
    final params = rawParams is Map
        ? Map<String, dynamic>.from(rawParams)
        : <String, dynamic>{};
    _notificationController.add(
      CodexAppServerNotification(method: method, params: params),
    );
  }

  void fail(Object error, [StackTrace? stackTrace]) {
    if (_closed || _failed) return;
    _failed = true;
    _terminalError = error;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace ?? StackTrace.current);
      }
    }
    _pending.clear();
    _notificationController.addError(error, stackTrace ?? StackTrace.current);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    const error = CodexAppServerException(
      'Codex App Server session was closed.',
    );
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(error, StackTrace.current);
      }
    }
    _pending.clear();
    await _lineSubscription.cancel();
    await _notificationController.close();
  }
}

/// Owns one local `codex app-server` process.
///
/// A fresh process is used per operation. This avoids shared-process
/// multiplexing races between normal chat, Studio, summaries and extensions,
/// while Codex itself continues to own and refresh the ChatGPT OAuth session.
class CodexAppServerClient implements CodexAppServerSession {
  CodexAppServerClient._(this._process, this._session) {
    // Drain stderr independently. It can contain non-fatal cache diagnostics
    // even when stdout returns a successful protocol response.
    _stderrSubscription = _process.stderr.listen((_) {});
    unawaited(
      _process.exitCode.then((code) {
        if (!_closing) {
          _session.fail(
            CodexAppServerException(
              'Codex App Server exited unexpectedly with code $code.',
            ),
          );
        }
      }),
    );
  }

  final Process _process;
  final CodexJsonLineSession _session;
  late final StreamSubscription<List<int>> _stderrSubscription;
  bool _closing = false;
  Future<void>? _closeFuture;
  CodexSessionLifetimeLease? _lifetimeLease;

  static Future<CodexAppServerClient> start({
    String? executable,
    String? workingDirectory,
    String? codexHome,
    CodexStartupCancellation? startupCancellation,
  }) async {
    if (!_isDesktop || (Platform.isMacOS && kReleaseMode)) {
      throw const CodexUnsupportedPlatformException();
    }
    _throwIfStartupCancelled(startupCancellation);

    final resolvedExecutable = executable ?? CodexExecutableLocator.resolve();
    if (!CodexExecutableLocator.isNativeExecutable(
      resolvedExecutable,
      isWindows: Platform.isWindows,
    )) {
      throw const CodexNotInstalledException();
    }
    final resolvedCodexHome = codexHome ?? await CodexIsolatedHome.prepare();
    final resolvedWorkingDirectory =
        workingDirectory ??
        await CodexIsolatedHome.prepareAccountWorkingDirectory();

    final lifetimeLease = await CodexSessionLifetimeCoordinator.acquire(
      cancellation: startupCancellation,
    );

    // App Server can perform model refresh and telemetry setup before the
    // initialize handshake. Probe every external configuration channel with a
    // credential-free profile first, then launch the real profile with the
    // same highest-precedence safety overrides. The real process repeats every
    // check before it is returned to account or generation code.
    try {
      final probeHome = await CodexIsolatedHome.prepareProbe();
      try {
        final probe = await _startVerified(
          executable: resolvedExecutable,
          workingDirectory: resolvedWorkingDirectory,
          codexHome: probeHome.path,
          startupCancellation: startupCancellation,
        );
        await probe.close();
      } finally {
        await CodexIsolatedHome.disposeProbe(probeHome);
      }

      _throwIfStartupCancelled(startupCancellation);

      final client = await _startVerified(
        executable: resolvedExecutable,
        workingDirectory: resolvedWorkingDirectory,
        codexHome: resolvedCodexHome,
        startupCancellation: startupCancellation,
      );
      client._lifetimeLease = lifetimeLease;
      return client;
    } catch (_) {
      lifetimeLease.release();
      rethrow;
    }
  }

  static Future<CodexAppServerClient> _startVerified({
    required String executable,
    required String workingDirectory,
    required String codexHome,
    CodexStartupCancellation? startupCancellation,
  }) async {
    // Stock Codex applies host requirements and macOS managed preferences
    // before the initialize response, and those settings can re-enable plugin
    // startup. Refuse every audited host-policy source before executing either
    // the credential-free probe or the authenticated process.
    await CodexHostPolicyGuard.verifyAbsent(codexHome);
    // The real home is memoised, so remove the exact cloud-policy cache for
    // every process rather than only when the directory is first prepared.
    await CodexIsolatedHome.removeCloudConfigCache(codexHome);
    _throwIfStartupCancelled(startupCancellation);

    Process process;
    try {
      process = await Process.start(
        executable,
        CodexInvocationPolicy.arguments(codexHome),
        workingDirectory: workingDirectory,
        environment: CodexIsolatedEnvironment.build(codexHome),
        includeParentEnvironment: false,
        // Owning the native process is important on Windows. Launching through
        // cmd.exe can leave the wrapper's native child alive after kill().
        runInShell: false,
      );
    } on ProcessException {
      throw const CodexNotInstalledException();
    }

    late final CodexAppServerClient client;
    final session = CodexJsonLineSession(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      (line) {
        process.stdin.writeln(line);
      },
    );
    client = CodexAppServerClient._(process, session);

    try {
      final initializeResponse = await _startupAware(
        client
            .request('initialize', CodexInvocationPolicy.initializeParams)
            .timeout(const Duration(seconds: 15)),
        startupCancellation,
      );
      CodexIsolationPolicy.validateInitialize(
        initializeResponse,
        codexHome: codexHome,
      );
      client.notify('initialized');
      await _startupAware(
        CodexIsolationPolicy.verify(
          client,
          codexHome: codexHome,
          workingDirectory: workingDirectory,
        ).timeout(const Duration(seconds: 15)),
        startupCancellation,
      );
      return client;
    } catch (error) {
      await client.close();
      if (error is TimeoutException) {
        throw const CodexAppServerException(
          'Codex App Server did not complete its startup isolation checks. '
          'Update Codex CLI and try again.',
        );
      }
      rethrow;
    }
  }

  static void _throwIfStartupCancelled(CodexStartupCancellation? cancellation) {
    if (cancellation?.isCancelled() == true) {
      throw const CodexStartupCancelledException();
    }
  }

  static Future<T> _startupAware<T>(
    Future<T> operation,
    CodexStartupCancellation? cancellation,
  ) {
    if (cancellation == null) return operation;
    _throwIfStartupCancelled(cancellation);
    return Future.any(<Future<T>>[
      operation,
      cancellation.whenCancelled.then<T>(
        (_) => throw const CodexStartupCancelledException(),
      ),
    ]);
  }

  static bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  @override
  Stream<CodexAppServerNotification> get notifications =>
      _session.notifications;

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) => _session.request(method, params);

  @override
  void notify(String method, [Map<String, dynamic>? params]) =>
      _session.notify(method, params);

  @override
  Future<void> close() => _closeFuture ??= _closeOnce();

  Future<void> _closeOnce() async {
    _closing = true;
    Object? sessionCloseError;
    StackTrace? sessionCloseStack;
    Object? terminationError;
    StackTrace? terminationStack;
    var terminationVerified = false;

    try {
      await _session.close();
    } catch (error, stackTrace) {
      sessionCloseError = error;
      sessionCloseStack = stackTrace;
    }

    try {
      await CodexProcessTreeTerminator.terminate(_process);
      terminationVerified = true;
    } catch (error, stackTrace) {
      terminationError = error;
      terminationStack = stackTrace;
    } finally {
      try {
        await _stderrSubscription.cancel();
      } catch (_) {
        // Process termination is independently verified above.
      }
      try {
        await _process.stdin.close();
      } catch (_) {
        // The process may already have closed its input after termination.
      }
      if (terminationVerified) {
        _lifetimeLease?.release();
        _lifetimeLease = null;
      }
    }

    if (terminationError != null) {
      Error.throwWithStackTrace(terminationError, terminationStack!);
    }
    if (sessionCloseError != null) {
      Error.throwWithStackTrace(sessionCloseError, sessionCloseStack!);
    }
  }
}

/// Pre-launch guard for every host-controlled configuration source used by
/// the audited Codex 0.147.0 and 0.149.0 releases.
class CodexHostPolicyGuard {
  CodexHostPolicyGuard._();

  static const List<String> _unixPolicyFiles = <String>[
    '/etc/codex/config.toml',
    '/etc/codex/managed_config.toml',
    '/etc/codex/requirements.toml',
  ];

  static const List<String> _macManagedPreferenceKeys = <String>[
    'config_toml_base64',
    'requirements_toml_base64',
  ];

  static Future<void> verifyAbsent(String codexHome) async {
    final policyFiles = <String>[];
    if (Platform.isMacOS || Platform.isLinux) {
      policyFiles.addAll(_unixPolicyFiles);
    } else if (Platform.isWindows) {
      final windows = p.Context(style: p.Style.windows);
      final codex = windows.join(_windowsProgramDataPath(), 'OpenAI', 'Codex');
      policyFiles.addAll(<String>[
        windows.join(codex, 'config.toml'),
        windows.join(codex, 'requirements.toml'),
        windows.join(codexHome, 'managed_config.toml'),
      ]);

      // Codex's Windows host-skill resolver asks the Shell for
      // FOLDERID_Profile, which ignores the HOME/USERPROFILE values in the
      // isolated child environment. Refuse that external instruction root.
      final hostSkills = windowsHostSkillsPath(_windowsProfilePath());
      if (await FileSystemEntity.type(hostSkills, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw CodexIsolationException(
          'Glaze cannot start Codex while host skills are installed at '
          '$hostSkills. Move that directory out of the Windows profile before '
          'using this connection.',
        );
      }
    }

    for (final file in policyFiles) {
      if (await File(file).exists()) {
        throw CodexIsolationException(
          'Glaze cannot start Codex while host policy is installed at $file. '
          'Use an unmanaged personal desktop profile for this connection.',
        );
      }
    }

    if (Platform.isMacOS) {
      final results = _macManagedPreferenceKeys.map(
        _macManagedPreferenceExists,
      );
      if (results.any((present) => present)) {
        throw const CodexIsolationException(
          'Glaze cannot start Codex while com.openai.codex managed '
          'preferences are installed. Use an unmanaged personal desktop '
          'profile for this connection.',
        );
      }
    }
  }

  static bool _macManagedPreferenceExists(String key) {
    Pointer<Utf8>? keyUtf8;
    Pointer<Utf8>? applicationUtf8;
    Pointer<Void> keyRef = nullptr;
    Pointer<Void> applicationRef = nullptr;
    Pointer<Void> valueRef = nullptr;
    try {
      final coreFoundation = DynamicLibrary.open(
        '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
      );
      final createString = coreFoundation
          .lookupFunction<_CfStringCreateNative, _CfStringCreateDart>(
            'CFStringCreateWithCString',
          );
      final copyPreference = coreFoundation
          .lookupFunction<
            _CfPreferencesCopyAppValueNative,
            _CfPreferencesCopyAppValueDart
          >('CFPreferencesCopyAppValue');
      final release = coreFoundation
          .lookupFunction<_CfReleaseNative, _CfReleaseDart>('CFRelease');

      keyUtf8 = key.toNativeUtf8();
      applicationUtf8 = 'com.openai.codex'.toNativeUtf8();
      const utf8Encoding = 0x08000100;
      keyRef = createString(nullptr, keyUtf8, utf8Encoding);
      applicationRef = createString(nullptr, applicationUtf8, utf8Encoding);
      if (keyRef == nullptr || applicationRef == nullptr) {
        throw StateError('CoreFoundation could not create preference keys');
      }
      valueRef = copyPreference(keyRef, applicationRef);
      final present = valueRef != nullptr;
      if (valueRef != nullptr) release(valueRef);
      release(keyRef);
      release(applicationRef);
      valueRef = nullptr;
      keyRef = nullptr;
      applicationRef = nullptr;
      return present;
    } catch (_) {
      throw const CodexIsolationException(
        'Glaze could not inspect macOS Codex managed preferences.',
      );
    } finally {
      // Only exceptional paths retain Core Foundation references here.
      if (valueRef != nullptr ||
          keyRef != nullptr ||
          applicationRef != nullptr) {
        try {
          final release = DynamicLibrary.open(
            '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
          ).lookupFunction<_CfReleaseNative, _CfReleaseDart>('CFRelease');
          if (valueRef != nullptr) release(valueRef);
          if (keyRef != nullptr) release(keyRef);
          if (applicationRef != nullptr) release(applicationRef);
        } catch (_) {
          // The operation is already failing closed.
        }
      }
      if (keyUtf8 != null) calloc.free(keyUtf8);
      if (applicationUtf8 != null) calloc.free(applicationUtf8);
    }
  }

  static String windowsHostSkillsPath(String profilePath) {
    final windows = p.Context(style: p.Style.windows);
    if (!windows.isAbsolute(profilePath)) {
      throw const CodexIsolationException(
        'The Windows profile directory must be absolute.',
      );
    }
    return windows.join(profilePath, '.agents', 'skills');
  }

  static String _windowsProgramDataPath() => _windowsKnownFolderPath(
    data1: 0x62ab5d82,
    data2: 0xfdc1,
    data3: 0x4dc3,
    tail: const <int>[0xa9, 0xdd, 0x07, 0x0d, 0x1d, 0x49, 0x5d, 0x97],
    name: 'ProgramData',
  );

  static String _windowsProfilePath() => _windowsKnownFolderPath(
    data1: 0x5e6c858f,
    data2: 0x0e22,
    data3: 0x4760,
    tail: const <int>[0x9a, 0xfe, 0xea, 0x33, 0x17, 0xb6, 0x71, 0x73],
    name: 'profile',
  );

  static String _windowsKnownFolderPath({
    required int data1,
    required int data2,
    required int data3,
    required List<int> tail,
    required String name,
  }) {
    Pointer<_WindowsGuid>? folderId;
    Pointer<Pointer<Utf16>>? output;
    Pointer<Utf16> allocated = nullptr;
    try {
      final shell32 = DynamicLibrary.open('shell32.dll');
      final ole32 = DynamicLibrary.open('ole32.dll');
      final getKnownFolderPath = shell32
          .lookupFunction<
            _ShGetKnownFolderPathNative,
            _ShGetKnownFolderPathDart
          >('SHGetKnownFolderPath');
      final free = ole32
          .lookupFunction<_CoTaskMemFreeNative, _CoTaskMemFreeDart>(
            'CoTaskMemFree',
          );

      folderId = calloc<_WindowsGuid>();
      output = calloc<Pointer<Utf16>>();
      folderId.ref
        ..data1 = data1
        ..data2 = data2
        ..data3 = data3;
      for (var index = 0; index < tail.length; index++) {
        folderId.ref.data4[index] = tail[index];
      }

      final result = getKnownFolderPath(folderId, 0, 0, output);
      allocated = output.value;
      if (result != 0 || allocated == nullptr) {
        throw StateError('SHGetKnownFolderPath failed with HRESULT $result');
      }
      final path = allocated.toDartString();
      free(allocated.cast<Void>());
      allocated = nullptr;
      final windows = p.Context(style: p.Style.windows);
      if (!windows.isAbsolute(path)) {
        throw StateError('$name was not absolute');
      }
      return path;
    } catch (_) {
      throw const CodexIsolationException(
        'Glaze could not resolve a required Windows policy directory.',
      );
    } finally {
      if (allocated != nullptr) {
        try {
          DynamicLibrary.open(
            'ole32.dll',
          ).lookupFunction<_CoTaskMemFreeNative, _CoTaskMemFreeDart>(
            'CoTaskMemFree',
          )(allocated.cast<Void>());
        } catch (_) {
          // The operation is already failing closed.
        }
      }
      if (folderId != null) calloc.free(folderId);
      if (output != null) calloc.free(output);
    }
  }
}

/// Terminates the App Server and its descendants without a command shell.
class CodexProcessTreeTerminator {
  CodexProcessTreeTerminator._();

  static Future<void> terminate(Process process) async {
    if (await _hasExited(process, const Duration(milliseconds: 10))) return;
    if (Platform.isWindows) {
      await _terminateWindows(process);
      return;
    }

    if (process.kill()) {
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
        return;
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        try {
          await process.exitCode.timeout(const Duration(seconds: 2));
          return;
        } on TimeoutException {
          throw const CodexIsolationException(
            'Codex App Server could not be terminated safely.',
          );
        }
      }
    }

    try {
      await process.exitCode.timeout(const Duration(milliseconds: 10));
    } on TimeoutException {
      throw const CodexIsolationException(
        'Codex App Server termination could not be verified.',
      );
    }
  }

  static Future<void> _terminateWindows(Process process) async {
    final executable = windowsTaskkillPath(Platform.environment);
    if (!File(executable).existsSync()) {
      throw const CodexIsolationException(
        'Windows process-tree shutdown is unavailable. Codex was not started '
        'again.',
      );
    }

    final environment = <String, String>{};
    final systemRoot = Platform.environment['SystemRoot'];
    final windowsDirectory = Platform.environment['WINDIR'];
    if (systemRoot != null && systemRoot.isNotEmpty) {
      environment['SystemRoot'] = systemRoot;
    }
    if (windowsDirectory != null && windowsDirectory.isNotEmpty) {
      environment['WINDIR'] = windowsDirectory;
    }
    final result = await Process.run(
      executable,
      taskkillArguments(process.pid),
      environment: environment,
      includeParentEnvironment: false,
      runInShell: false,
    );
    if (result.exitCode != 0) {
      if (await _hasExited(process, const Duration(milliseconds: 100))) return;
      throw const CodexIsolationException(
        'Windows could not terminate the complete Codex process tree.',
      );
    }
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      throw const CodexIsolationException(
        'Windows did not confirm Codex process-tree shutdown.',
      );
    }
  }

  static Future<bool> _hasExited(Process process, Duration timeout) async {
    try {
      await process.exitCode.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  static List<String> taskkillArguments(int pid) => <String>[
    '/PID',
    '$pid',
    '/T',
    '/F',
  ];

  static String windowsTaskkillPath(Map<String, String> environment) {
    final root = environment['SystemRoot'] ?? environment['WINDIR'];
    final windows = p.Context(style: p.Style.windows);
    if (root == null || root.isEmpty || !windows.isAbsolute(root)) {
      throw const CodexIsolationException(
        'Windows did not expose a trusted system directory for process-tree '
        'shutdown.',
      );
    }
    return windows.join(root, 'System32', 'taskkill.exe');
  }
}

/// Highest-precedence controls applied before App Server can read credentials.
class CodexInvocationPolicy {
  CodexInvocationPolicy._();

  static const String openAiBaseUrl = 'https://chatgpt.com/backend-api/codex';
  // Browser OAuth and token refresh use their dedicated OpenAI auth endpoints,
  // while generation uses [openAiBaseUrl]. Point every auxiliary ChatGPT
  // service at a closed privileged loopback port so cloud policy, remote
  // catalogues and other non-generation routes fail locally and promptly.
  // Custom proxy/CA variables are not inherited by the child process.
  static const String chatGptBaseUrl = 'https://127.0.0.1:1';
  static const String modelCatalogFileName = 'model-catalog-0.147.0.json';

  static String modelCatalogPath(String codexHome) =>
      p.join(codexHome, modelCatalogFileName);

  static const Map<String, dynamic> initializeParams = <String, dynamic>{
    'clientInfo': <String, dynamic>{
      'name': 'glaze',
      'title': 'Glaze',
      'version': '0.7.0',
    },
    // Explicit empty environments are an experimental App Server field in
    // Codex 0.147. Opting in makes them authoritative instead of silently
    // falling back to a local environment with built-in file/shell tools.
    'capabilities': <String, dynamic>{'experimentalApi': true},
  };

  static Map<String, Object?> expectedLayerConfig(
    String codexHome,
  ) => <String, Object?>{
    'model_provider': CodexIsolationPolicy.provider,
    'model_providers': <String, Object?>{},
    'mcp_servers': <String, Object?>{},
    'openai_base_url': openAiBaseUrl,
    'chatgpt_base_url': chatGptBaseUrl,
    'model_catalog_json': modelCatalogPath(codexHome),
    'cli_auth_credentials_store': 'file',
    'check_for_update_on_startup': false,
    'project_doc_max_bytes': 0,
    'project_root_markers': <Object>[],
    'approval_policy': 'never',
    'sandbox_mode': 'read-only',
    'allow_login_shell': false,
    'forced_login_method': 'chatgpt',
    'include_apps_instructions': false,
    'include_collaboration_mode_instructions': false,
    'include_environment_context': false,
    'include_permissions_instructions': false,
    'notify': <Object>[],
    'analytics': <String, Object?>{'enabled': false},
    'otel': <String, Object?>{
      'exporter': 'none',
      'trace_exporter': 'none',
      'metrics_exporter': 'none',
      'log_user_prompt': false,
    },
    'history': <String, Object?>{'persistence': 'none'},
    'web_search': 'disabled',
    'feedback': <String, Object?>{'enabled': false},
    'agents': <String, Object?>{'enabled': false},
    'apps': <String, Object?>{
      '_default': <String, Object?>{
        'enabled': false,
        'destructive_enabled': false,
        'open_world_enabled': false,
      },
    },
    'memories': <String, Object?>{
      'use_memories': false,
      'generate_memories': false,
    },
    'features': CodexIsolationPolicy.disabledFeatures,
    'tools': <String, Object?>{
      'update_plan': <String, Object?>{'enabled': false},
      'experimental_request_user_input': <String, Object?>{'enabled': false},
    },
  };

  static List<String> arguments(String codexHome) => <String>[
    '--strict-config',
    '-c',
    'model_provider="openai"',
    '-c',
    'model_providers={}',
    '-c',
    'mcp_servers={}',
    '-c',
    'openai_base_url="https://chatgpt.com/backend-api/codex"',
    '-c',
    'chatgpt_base_url="https://127.0.0.1:1"',
    '-c',
    'model_catalog_json=${jsonEncode(modelCatalogPath(codexHome))}',
    '-c',
    'cli_auth_credentials_store="file"',
    '-c',
    'check_for_update_on_startup=false',
    '-c',
    'project_doc_max_bytes=0',
    '-c',
    'project_root_markers=[]',
    '-c',
    'approval_policy="never"',
    '-c',
    'sandbox_mode="read-only"',
    '-c',
    'allow_login_shell=false',
    '-c',
    'forced_login_method="chatgpt"',
    '-c',
    'include_apps_instructions=false',
    '-c',
    'include_collaboration_mode_instructions=false',
    '-c',
    'include_environment_context=false',
    '-c',
    'include_permissions_instructions=false',
    '-c',
    'notify=[]',
    '-c',
    'analytics.enabled=false',
    '-c',
    'otel.exporter="none"',
    '-c',
    'otel.trace_exporter="none"',
    '-c',
    'otel.metrics_exporter="none"',
    '-c',
    'otel.log_user_prompt=false',
    '-c',
    'history.persistence="none"',
    '-c',
    'web_search="disabled"',
    '-c',
    'feedback.enabled=false',
    '-c',
    'tools.update_plan.enabled=false',
    '-c',
    'tools.experimental_request_user_input.enabled=false',
    '-c',
    'agents.enabled=false',
    '-c',
    'apps._default.enabled=false',
    '-c',
    'apps._default.destructive_enabled=false',
    '-c',
    'apps._default.open_world_enabled=false',
    '-c',
    'memories.use_memories=false',
    '-c',
    'memories.generate_memories=false',
    '-c',
    'features.apps=false',
    '-c',
    'features.auth_elicitation=false',
    '-c',
    'features.browser_use=false',
    '-c',
    'features.computer_use=false',
    '-c',
    'features.code_mode=false',
    '-c',
    'features.code_mode_host=false',
    '-c',
    'features.code_mode_only=false',
    '-c',
    'features.goals=false',
    '-c',
    'features.hooks=false',
    '-c',
    'features.image_generation=false',
    '-c',
    'features.mcp_2026_07_28=false',
    '-c',
    'features.memories=false',
    '-c',
    'features.mentions_v2=false',
    '-c',
    'features.multi_agent=false',
    '-c',
    'features.plugins=false',
    '-c',
    'features.remote_control=false',
    '-c',
    'features.remote_plugin=false',
    '-c',
    'features.shell_tool=false',
    '-c',
    'features.shell_snapshot=false',
    '-c',
    'features.skill_search=false',
    '-c',
    'features.tool_suggest=false',
    '-c',
    'features.unified_exec=false',
    '-c',
    'features.view_image=false',
    '-c',
    'features.web_search_cached=false',
    '-c',
    'features.web_search_request=false',
    '-c',
    'features.standalone_web_search=false',
    '-c',
    'features.workspace_dependencies=false',
    'app-server',
  ];
}

/// Fail-closed validation for every process before account or model access.
///
/// CODEX_HOME isolates the user layer, but Codex can also read system,
/// enterprise, project and session configuration. The effective configuration
/// and its provenance are therefore checked before Glaze permits OAuth, model
/// discovery or thread creation. The MCP inventory is checked separately so a
/// future source that is not represented in config/read cannot go unnoticed.
class CodexIsolationPolicy {
  CodexIsolationPolicy._();

  static const String provider = 'openai';

  static const Map<String, Object?> disabledFeatures = <String, Object?>{
    'apps': false,
    'auth_elicitation': false,
    'browser_use': false,
    'computer_use': false,
    'code_mode': false,
    'code_mode_host': false,
    'code_mode_only': false,
    'goals': false,
    'hooks': false,
    'image_generation': false,
    'mcp_2026_07_28': false,
    'memories': false,
    'mentions_v2': false,
    'multi_agent': false,
    'plugins': false,
    'remote_control': false,
    'remote_plugin': false,
    'shell_tool': false,
    'shell_snapshot': false,
    'skill_search': false,
    'tool_suggest': false,
    'unified_exec': false,
    'view_image': false,
    'web_search_cached': false,
    'web_search_request': false,
    'standalone_web_search': false,
    'workspace_dependencies': false,
  };

  /// Exact Glaze-owned user-layer contract returned by audited Codex versions.
  ///
  /// `skills` is handled as an optional matching entry because some compatible
  /// Codex versions enforce those settings in the skills loader without
  /// returning the table through config/read.
  static Map<String, Object?> expectedUserLayerConfig(
    String codexHome,
  ) => <String, Object?>{
    'model_provider': provider,
    'openai_base_url': CodexInvocationPolicy.openAiBaseUrl,
    'chatgpt_base_url': CodexInvocationPolicy.chatGptBaseUrl,
    'model_catalog_json': CodexInvocationPolicy.modelCatalogPath(codexHome),
    'cli_auth_credentials_store': 'file',
    'check_for_update_on_startup': false,
    'project_doc_max_bytes': 0,
    'project_root_markers': <Object>[],
    'approval_policy': 'never',
    'sandbox_mode': 'read-only',
    'allow_login_shell': false,
    'forced_login_method': 'chatgpt',
    'include_apps_instructions': false,
    'include_collaboration_mode_instructions': false,
    'include_environment_context': false,
    'include_permissions_instructions': false,
    'notify': <Object>[],
    'analytics': <String, Object?>{'enabled': false},
    'otel': <String, Object?>{
      'exporter': 'none',
      'trace_exporter': 'none',
      'metrics_exporter': 'none',
      'log_user_prompt': false,
    },
    'history': <String, Object?>{'persistence': 'none'},
    'web_search': 'disabled',
    'feedback': <String, Object?>{'enabled': false},
    'agents': <String, Object?>{'enabled': false},
    'apps': <String, Object?>{
      '_default': <String, Object?>{
        'enabled': false,
        'destructive_enabled': false,
        'open_world_enabled': false,
      },
    },
    'memories': <String, Object?>{
      'use_memories': false,
      'generate_memories': false,
    },
    'features': disabledFeatures,
    'tools': <String, Object?>{
      'update_plan': <String, Object?>{'enabled': false},
      'experimental_request_user_input': <String, Object?>{'enabled': false},
    },
  };

  static const Map<String, Object?> _optionalSkillsConfig = <String, Object?>{
    'include_instructions': false,
    'bundled': <String, Object?>{'enabled': false},
  };

  static Future<void> verify(
    CodexAppServerSession session, {
    required String codexHome,
    required String workingDirectory,
  }) async {
    final configResponse = await session.request(
      'config/read',
      <String, dynamic>{'cwd': workingDirectory, 'includeLayers': true},
    );
    validateConfigRead(configResponse, codexHome: codexHome);

    final requirementsResponse = await session.request(
      'configRequirements/read',
    );
    validateConfigRequirements(requirementsResponse);

    final mcpResponse = await session.request(
      'mcpServerStatus/list',
      <String, dynamic>{
        'cursor': null,
        'limit': 100,
        'detail': 'toolsAndAuthOnly',
      },
    );
    validateMcpInventory(mcpResponse);
  }

  static void validateInitialize(
    Map<String, dynamic> response, {
    required String codexHome,
  }) {
    final reportedHome = response['codexHome'];
    final userAgent = response['userAgent'];
    if (reportedHome is! String ||
        !_samePath(reportedHome, codexHome) ||
        userAgent is! String ||
        !RegExp(r'^glaze\/(?:0\.147\.0|0\.149\.0) \(').hasMatch(userAgent)) {
      throw const CodexIsolationException(
        'Codex did not confirm an audited Glaze profile and CLI version. '
        'Install Codex CLI 0.147.0 or 0.149.0 before using this connection.',
      );
    }
  }

  static void validateConfigRead(
    Map<String, dynamic> response, {
    required String codexHome,
  }) {
    final effective = _map(response['config']);
    final origins = _map(response['origins']);
    final layers = response['layers'];
    if (effective == null || origins == null || layers is! List) {
      throw const CodexIsolationException(
        'Codex did not return verifiable layered configuration. Update Codex '
        'CLI before using the ChatGPT connection.',
      );
    }

    final expectedConfigFile = p.join(codexHome, 'config.toml');
    var userLayerCount = 0;
    var sessionLayerCount = 0;
    for (var layerIndex = 0; layerIndex < layers.length; layerIndex++) {
      final rawLayer = layers[layerIndex];
      final layer = _map(rawLayer);
      final source = _map(layer?['name']);
      final layerConfig = _map(layer?['config']);
      final type = source?['type'];
      if (layer == null ||
          source == null ||
          layerConfig == null ||
          type is! String ||
          layer['version'] is! String) {
        throw const CodexIsolationException(
          'Codex returned malformed configuration provenance. The ChatGPT '
          'connection was stopped.',
        );
      }

      if (type == 'sessionFlags') {
        sessionLayerCount++;
        if (layerIndex != 0 ||
            !_deepEquals(
              layerConfig,
              CodexInvocationPolicy.expectedLayerConfig(codexHome),
            )) {
          throw const CodexIsolationException(
            'Codex did not preserve Glaze’s highest-precedence startup '
            'configuration. The ChatGPT connection was stopped.',
          );
        }
        continue;
      }

      if (type == 'user') {
        userLayerCount++;
        final file = source['file'];
        if (file is! String ||
            !_samePath(file, expectedConfigFile) ||
            source['profile'] != null ||
            layer['disabledReason'] != null) {
          throw const CodexIsolationException(
            'Codex loaded a user configuration outside the Glaze-owned '
            'profile. The ChatGPT connection was stopped.',
          );
        }
        _validateUserLayer(layerConfig, codexHome: codexHome);
        continue;
      }

      // Codex reports an empty system layer even when /etc/codex/config.toml
      // does not exist. It is the only external layer shape accepted, and only
      // while it contributes no values. Project, enterprise, MDM, legacy,
      // packaged-default and unknown layers are rejected even when empty.
      if (type != 'system' || layerConfig.isNotEmpty) {
        throw CodexIsolationException(
          'Codex loaded an external $type configuration layer. Remove or '
          'disable that layer before using Glaze with ChatGPT.',
        );
      }
    }
    if (sessionLayerCount != 1 || userLayerCount != 1) {
      throw const CodexIsolationException(
        'Codex did not load exactly one Glaze startup layer and one '
        'Glaze-owned user configuration layer.',
      );
    }

    for (final rawOrigin in origins.values) {
      final origin = _map(rawOrigin);
      final source = _map(origin?['name']);
      final type = source?['type'];
      final file = source?['file'];
      if (origin == null || source == null || origin['version'] is! String) {
        throw const CodexIsolationException(
          'Codex reported an external effective configuration origin. The '
          'ChatGPT connection was stopped.',
        );
      }
      if (type == 'sessionFlags') continue;
      if (type != 'user' ||
          file is! String ||
          !_samePath(file, expectedConfigFile) ||
          source['profile'] != null) {
        throw const CodexIsolationException(
          'Codex reported an external effective configuration origin. The '
          'ChatGPT connection was stopped.',
        );
      }
    }
    for (final requiredOrigin in const <String>[
      'model_provider',
      'openai_base_url',
      'chatgpt_base_url',
      'model_catalog_json',
      'forced_login_method',
      'web_search',
      'approval_policy',
      'sandbox_mode',
    ]) {
      final origin = _map(origins[requiredOrigin]);
      final source = _map(origin?['name']);
      if (source?['type'] != 'sessionFlags') {
        throw CodexIsolationException(
          'Codex could not prove the session origin of the required '
          '$requiredOrigin isolation setting.',
        );
      }
    }

    _validateEffectiveConfig(effective, codexHome: codexHome);
  }

  static void validateMcpInventory(Map<String, dynamic> response) {
    final data = response['data'];
    if (data is! List || data.isNotEmpty || response['nextCursor'] != null) {
      throw const CodexIsolationException(
        'Codex reported an active or unverifiable MCP server. MCP servers are '
        'not permitted in the Glaze ChatGPT profile.',
      );
    }
  }

  static void validateConfigRequirements(Map<String, dynamic> response) {
    if (!response.containsKey('requirements') ||
        response['requirements'] != null) {
      throw const CodexIsolationException(
        'Codex reported managed configuration requirements. Managed '
        'requirements are not permitted in the Glaze ChatGPT profile.',
      );
    }
  }

  static void _validateUserLayer(
    Map<String, dynamic> layerConfig, {
    required String codexHome,
  }) {
    final config = Map<String, dynamic>.from(layerConfig);
    final skills = config.remove('skills');
    if (skills != null && !_deepEquals(skills, _optionalSkillsConfig)) {
      throw const CodexIsolationException(
        'The Glaze-owned Codex configuration contains unexpected skill '
        'settings. Startup was stopped.',
      );
    }
    if (!_deepEquals(config, expectedUserLayerConfig(codexHome))) {
      throw const CodexIsolationException(
        'The Glaze-owned Codex configuration differs from the required '
        'isolation policy. Startup was stopped.',
      );
    }
  }

  static void _validateEffectiveConfig(
    Map<String, dynamic> config, {
    required String codexHome,
  }) {
    final modelCatalog = config['model_catalog_json'];
    if (config['model_provider'] != provider ||
        config['openai_base_url'] != CodexInvocationPolicy.openAiBaseUrl ||
        config['chatgpt_base_url'] != CodexInvocationPolicy.chatGptBaseUrl ||
        modelCatalog is! String ||
        !_samePath(
          modelCatalog,
          CodexInvocationPolicy.modelCatalogPath(codexHome),
        ) ||
        config['forced_login_method'] != 'chatgpt' ||
        config['cli_auth_credentials_store'] != 'file' ||
        config['approval_policy'] != 'never' ||
        config['sandbox_mode'] != 'read-only' ||
        config['allow_login_shell'] != false ||
        config['project_doc_max_bytes'] != 0 ||
        config['project_root_markers'] is! List ||
        (config['project_root_markers'] as List).isNotEmpty ||
        config['include_apps_instructions'] != false ||
        config['include_collaboration_mode_instructions'] != false ||
        config['include_environment_context'] != false ||
        config['include_permissions_instructions'] != false) {
      throw const CodexIsolationException(
        'Codex did not preserve the required effective isolation settings.',
      );
    }

    for (final emptyMapKey in const <String>[
      'marketplaces',
      'mcp_servers',
      'model_providers',
      'plugins',
    ]) {
      final value = config[emptyMapKey];
      if (value is! Map || value.isNotEmpty) {
        throw CodexIsolationException(
          'Codex reported an unsafe $emptyMapKey configuration.',
        );
      }
    }
    for (final nullKey in const <String>[
      'compact_prompt',
      'developer_instructions',
      'experimental_compact_prompt_file',
      'experimental_thread_config_endpoint',
      'experimental_thread_store',
      'experimental_thread_store_endpoint',
      'forced_chatgpt_workspace_id',
      'hooks',
      'instructions',
      'mcp_oauth_credentials_store',
      'model_instructions_file',
      'profile',
      'projects',
    ]) {
      if (!config.containsKey(nullKey) || config[nullKey] != null) {
        throw CodexIsolationException(
          'Codex reported an unsafe $nullKey configuration.',
        );
      }
    }

    final history = _map(config['history']);
    final analytics = _map(config['analytics']);
    final otel = _map(config['otel']);
    final agents = _map(config['agents']);
    final apps = _map(config['apps']);
    final appDefault = _map(apps?['_default']);
    final memories = _map(config['memories']);
    final features = _map(config['features']);
    final notify = config['notify'];
    final capabilityChecks = <String, bool>{
      'analytics.enabled': analytics?['enabled'] == false,
      'otel.exporter': otel?['exporter'] == 'none',
      'otel.trace_exporter': otel?['trace_exporter'] == 'none',
      'otel.metrics_exporter': otel?['metrics_exporter'] == 'none',
      'otel.log_user_prompt': otel?['log_user_prompt'] == false,
      'notify': notify is List && notify.isEmpty,
      'history.persistence': history?['persistence'] == 'none',
      'web_search': config['web_search'] == 'disabled',
      'agents.enabled': agents?['enabled'] == false,
      'apps._default.enabled': appDefault?['enabled'] == false,
      'apps._default.destructive_enabled':
          appDefault?['destructive_enabled'] == false,
      'apps._default.open_world_enabled':
          appDefault?['open_world_enabled'] == false,
      'memories.use_memories': memories?['use_memories'] == false,
      'memories.generate_memories': memories?['generate_memories'] == false,
    };
    for (final check in capabilityChecks.entries) {
      if (!check.value) {
        throw CodexIsolationException(
          'Codex did not preserve the disabled ${check.key} setting.',
        );
      }
    }
    if (features == null) {
      throw const CodexIsolationException(
        'Codex did not report its effective feature settings.',
      );
    }
    for (final feature in disabledFeatures.keys) {
      if (features[feature] != false) {
        throw CodexIsolationException(
          'Codex did not keep the $feature capability disabled.',
        );
      }
    }
  }

  static Map<String, dynamic>? _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : null;

  static bool _deepEquals(Object? left, Object? right) {
    if (left is Map && right is Map) {
      if (left.length != right.length) return false;
      for (final key in left.keys) {
        if (!right.containsKey(key) || !_deepEquals(left[key], right[key])) {
          return false;
        }
      }
      return true;
    }
    if (left is List && right is List) {
      if (left.length != right.length) return false;
      for (var index = 0; index < left.length; index++) {
        if (!_deepEquals(left[index], right[index])) return false;
      }
      return true;
    }
    return left == right;
  }

  static bool _samePath(String left, String right) {
    String normalise(String value) {
      var resolved = p.normalize(p.absolute(value));
      try {
        resolved = File(resolved).resolveSymbolicLinksSync();
      } catch (_) {
        // The path may not have been created yet in a unit test. Lexical
        // normalisation is still deterministic in that case.
      }
      return Platform.isWindows ? resolved.toLowerCase() : resolved;
    }

    return normalise(left) == normalise(right);
  }
}

/// Minimal process environment for the isolated App Server.
///
/// In particular, authentication and workload-identity variables are not
/// inherited. Both Codex state roots are pinned to the Glaze-owned directory.
/// Proxy and custom-CA variables are deliberately omitted so a child cannot
/// route OAuth or subscription traffic through an inherited interception
/// endpoint.
class CodexIsolatedEnvironment {
  CodexIsolatedEnvironment._();

  static const Set<String> _allowedParentKeys = <String>{
    'APPDATA',
    'COMSPEC',
    'HOME',
    'LANG',
    'LC_ALL',
    'LC_CTYPE',
    'LOCALAPPDATA',
    'LOGNAME',
    'PATH',
    'PATHEXT',
    'ProgramData',
    'ProgramFiles',
    'ProgramFiles(x86)',
    'SystemRoot',
    'TEMP',
    'TMP',
    'TMPDIR',
    'TZ',
    'USER',
    'USERPROFILE',
    'WINDIR',
  };

  static Map<String, String> build(
    String codexHome, {
    Map<String, String>? parent,
  }) {
    final source = parent ?? Platform.environment;
    final environment = <String, String>{};
    for (final key in _allowedParentKeys) {
      final value = source[key];
      if (value != null && value.isNotEmpty) environment[key] = value;
    }
    // Codex also discovers user-global instructions and skills beneath the
    // operating-system home directory. Point both common home variables at
    // the isolated profile so the real ~/.agents and equivalent Windows paths
    // are outside the child process's discovery boundary.
    environment['HOME'] = codexHome;
    environment['USERPROFILE'] = codexHome;
    environment['CODEX_HOME'] = codexHome;
    environment['CODEX_SQLITE_HOME'] = codexHome;
    // This transport-level marker is consumed before App Server worker threads
    // start. The similarly named feature flag does not disable a persisted
    // remote-control enrollment in Codex 0.147/0.149.
    environment['CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED'] = '1';
    return environment;
  }
}

/// Creates a Glaze-owned Codex state root.
///
/// This is the security boundary that prevents a Glaze prompt from inheriting
/// the user's normal Codex AGENTS.md, MCP servers, plugins, skills or hooks.
/// Codex stores and refreshes its own ChatGPT OAuth credential inside this
/// root; Glaze never reads or copies that credential.
class CodexIsolatedHome {
  CodexIsolatedHome._();

  static const String modelCatalogAsset =
      'assets/codex/model-catalog-0.147.0.json';
  static const String modelCatalogSha256 =
      '20a56af9d9b33ebd124dcd94b4ab88a7cbdd66e5112aca076af41b1c3b0de0b4';
  static const String cloudConfigCacheFileName =
      'cloud-config-bundle-cache.json';
  static Future<String>? _prepared;

  static Future<String> prepare() => _prepared ??= _prepare();

  static Future<String> _prepare() async {
    final root = await getAppDataDir();
    final home = Directory('$root${Platform.pathSeparator}codex_chatgpt');
    await _initialise(home);
    return home.path;
  }

  static Future<Directory> prepareProbe() async {
    final home = await Directory.systemTemp.createTemp(
      'glaze-codex-authless-preflight-',
    );
    await _initialise(home);
    return home;
  }

  /// Returns a stable private cwd for account and model operations. Keeping it
  /// below the 0700 isolated home prevents another local Unix user from
  /// planting `/tmp/.codex` project configuration in an ancestor directory.
  static Future<String> prepareAccountWorkingDirectory() async {
    final home = await prepare();
    final directory = Directory(p.join(home, 'workspaces', 'account'));
    await directory.create(recursive: true);
    await _protectDirectory(directory);
    return directory.path;
  }

  /// Creates a private, per-turn cwd owned by the caller, which removes it
  /// after the App Server process has closed.
  static Future<Directory> createTurnWorkingDirectory() async {
    final home = await prepare();
    final root = Directory(p.join(home, 'workspaces', 'turns'));
    await root.create(recursive: true);
    await _protectDirectory(root);
    final directory = await root.createTemp('turn-');
    await _protectDirectory(directory);
    return directory;
  }

  /// Clears only authentication and managed-policy cache files owned by the
  /// dedicated Glaze Codex profile. It never touches the user's normal Codex
  /// home or any other Glaze data.
  static Future<void> clearAuthentication() async {
    await CodexSessionLifetimeCoordinator.runExclusive(() async {
      final root = await getAppDataDir();
      final home = p.join(root, 'codex_chatgpt');
      for (final fileName in const <String>[
        'auth.json',
        cloudConfigCacheFileName,
      ]) {
        final file = File(p.join(home, fileName));
        if (await file.exists()) await file.delete();
      }
    });
  }

  /// Removes only the exact managed-policy cache in an explicitly selected
  /// Codex home. This is repeated immediately before every process start.
  static Future<void> removeCloudConfigCache(String codexHome) async {
    if (!p.isAbsolute(codexHome)) {
      throw const CodexIsolationException(
        'The isolated Codex profile path must be absolute.',
      );
    }
    final cache = File(p.join(codexHome, cloudConfigCacheFileName));
    if (await cache.exists()) await cache.delete();
  }

  static Future<void> disposeProbe(Directory home) async {
    final name = p.basename(home.path);
    if (!name.startsWith('glaze-codex-authless-preflight-')) {
      throw const CodexIsolationException(
        'Refused to remove an unrecognised Codex preflight directory.',
      );
    }
    if (await home.exists()) await home.delete(recursive: true);
  }

  static Future<void> _initialise(Directory home) async {
    await home.create(recursive: true);

    // Managed cloud policy is unsupported. Remove only Codex's exact cache
    // inside the Glaze-owned profile before either the probe or real process
    // starts, so an identity-matched cached bundle cannot bypass the pinned
    // auxiliary route and run startup work before verification.
    await removeCloudConfigCache(home.path);

    final catalog = await _materialiseModelCatalog(home);

    // Force file-backed credentials so the isolated home cannot silently pick
    // up a separate Codex login from a shared OS keychain entry.
    final config = File('${home.path}${Platform.pathSeparator}config.toml');
    await config.writeAsString(_isolatedConfig(catalog.path), flush: true);

    if (!Platform.isWindows) {
      await _protectDirectory(home);
      final filePermissions = await Process.run('/bin/chmod', [
        '600',
        catalog.path,
        config.path,
      ]);
      if (filePermissions.exitCode != 0) {
        throw const CodexIsolationException(
          'Glaze could not protect its isolated Codex profile permissions.',
        );
      }
    }
  }

  static Future<void> _protectDirectory(Directory directory) async {
    if (Platform.isWindows) return;
    final result = await Process.run('/bin/chmod', ['700', directory.path]);
    if (result.exitCode != 0) {
      throw const CodexIsolationException(
        'Glaze could not protect an isolated Codex working directory.',
      );
    }
  }

  static Future<File> _materialiseModelCatalog(Directory home) async {
    List<int> bytes;
    try {
      final data = await rootBundle.load(modelCatalogAsset);
      bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      throw const CodexIsolationException(
        'Glaze could not load its audited Codex model catalogue.',
      );
    }
    if (sha256.convert(bytes).toString() != modelCatalogSha256) {
      throw const CodexIsolationException(
        'Glaze’s bundled Codex model catalogue failed its integrity check.',
      );
    }

    final catalog = File(
      p.join(home.path, CodexInvocationPolicy.modelCatalogFileName),
    );
    await catalog.writeAsBytes(bytes, flush: true);
    if (sha256.convert(await catalog.readAsBytes()).toString() !=
        modelCatalogSha256) {
      throw const CodexIsolationException(
        'Glaze could not verify the materialised Codex model catalogue.',
      );
    }
    return catalog;
  }

  static String _isolatedConfig(String modelCatalogPath) =>
      '''
model_provider = "openai"
openai_base_url = "https://chatgpt.com/backend-api/codex"
chatgpt_base_url = "https://127.0.0.1:1"
model_catalog_json = ${jsonEncode(modelCatalogPath)}
cli_auth_credentials_store = "file"
check_for_update_on_startup = false
project_doc_max_bytes = 0
project_root_markers = []
approval_policy = "never"
sandbox_mode = "read-only"
allow_login_shell = false
forced_login_method = "chatgpt"
include_apps_instructions = false
include_collaboration_mode_instructions = false
include_environment_context = false
include_permissions_instructions = false
notify = []
web_search = "disabled"

[analytics]
enabled = false

[otel]
exporter = "none"
trace_exporter = "none"
metrics_exporter = "none"
log_user_prompt = false

[history]
persistence = "none"

[feedback]
enabled = false

[tools.update_plan]
enabled = false

[tools.experimental_request_user_input]
enabled = false

[agents]
enabled = false

[apps._default]
enabled = false
destructive_enabled = false
open_world_enabled = false

[memories]
use_memories = false
generate_memories = false

[skills]
include_instructions = false

[skills.bundled]
enabled = false

[features]
apps = false
auth_elicitation = false
browser_use = false
computer_use = false
code_mode = false
code_mode_host = false
code_mode_only = false
goals = false
hooks = false
image_generation = false
mcp_2026_07_28 = false
memories = false
mentions_v2 = false
multi_agent = false
plugins = false
remote_control = false
remote_plugin = false
shell_tool = false
shell_snapshot = false
skill_search = false
tool_suggest = false
unified_exec = false
view_image = false
web_search_cached = false
web_search_request = false
standalone_web_search = false
workspace_dependencies = false
''';
}

class CodexExecutableLocator {
  CodexExecutableLocator._();

  static String resolve() {
    final executableName = Platform.isWindows ? 'codex.exe' : 'codex';
    final candidates = <String>[];
    final path = Platform.environment['PATH'];
    if (path != null && path.isNotEmpty) {
      candidates.addAll(
        path
            .split(Platform.isWindows ? ';' : ':')
            .where((part) => part.isNotEmpty)
            .map((part) => '$part${Platform.pathSeparator}$executableName'),
      );
    }

    final userHome =
        Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    if (userHome != null && userHome.isNotEmpty) {
      candidates.addAll(<String>[
        '$userHome${Platform.pathSeparator}.codex'
            '${Platform.pathSeparator}packages${Platform.pathSeparator}'
            'standalone${Platform.pathSeparator}current'
            '${Platform.pathSeparator}bin${Platform.pathSeparator}'
            '$executableName',
        '$userHome${Platform.pathSeparator}.local${Platform.pathSeparator}bin'
            '${Platform.pathSeparator}$executableName',
        '$userHome${Platform.pathSeparator}.npm-global'
            '${Platform.pathSeparator}bin${Platform.pathSeparator}'
            '$executableName',
      ]);
    }
    if (!Platform.isWindows) {
      candidates.addAll(const <String>[
        '/opt/homebrew/bin/codex',
        '/usr/local/bin/codex',
        '/usr/bin/codex',
      ]);
    }

    for (final candidate in candidates) {
      if (isNativeExecutable(candidate, isWindows: Platform.isWindows)) {
        return candidate;
      }
    }

    // Let the caller produce the normal installation error. An unresolved
    // command name cannot be inspected and is never executed speculatively.
    return executableName;
  }

  static bool isNativeExecutable(String executable, {required bool isWindows}) {
    if (isWindows && p.extension(executable).toLowerCase() != '.exe') {
      return false;
    }
    final file = File(executable);
    if (!file.existsSync()) return false;
    RandomAccessFile? handle;
    try {
      handle = file.openSync();
      final header = handle.readSync(4);
      if (isWindows) {
        return header.length >= 2 && header[0] == 0x4d && header[1] == 0x5a;
      }
      if (header.length < 4) return false;
      if (header[0] == 0x7f &&
          header[1] == 0x45 &&
          header[2] == 0x4c &&
          header[3] == 0x46) {
        return true;
      }
      final magic =
          (header[0] << 24) | (header[1] << 16) | (header[2] << 8) | header[3];
      return const <int>{
        0xfeedface,
        0xcefaedfe,
        0xfeedfacf,
        0xcffaedfe,
        0xcafebabe,
        0xbebafeca,
        0xcafebabf,
        0xbfbafeca,
      }.contains(magic);
    } on FileSystemException {
      return false;
    } finally {
      handle?.closeSync();
    }
  }
}
