import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../utils/platform_paths.dart';

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
        'Codex CLI was not found. Install or update Codex, then return here '
        'to sign in with ChatGPT.',
      );
}

class CodexUnsupportedPlatformException extends CodexAppServerException {
  const CodexUnsupportedPlatformException()
    : super(
        'ChatGPT subscription connections are available only in the '
        'Windows, macOS and Linux versions of Glaze.',
      );
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

  static Future<CodexAppServerClient> start({
    String? executable,
    String? workingDirectory,
    String? codexHome,
  }) async {
    if (!_isDesktop) throw const CodexUnsupportedPlatformException();

    final resolvedExecutable = executable ?? CodexExecutableLocator.resolve();
    final resolvedCodexHome = codexHome ?? await CodexIsolatedHome.prepare();
    Process process;
    try {
      process = await Process.start(
        resolvedExecutable,
        const ['--strict-config', 'app-server'],
        workingDirectory: workingDirectory,
        environment: CodexIsolatedEnvironment.build(resolvedCodexHome),
        includeParentEnvironment: false,
        runInShell: Platform.isWindows,
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
      await client
          .request('initialize', <String, dynamic>{
            'clientInfo': <String, dynamic>{
              'name': 'glaze',
              'title': 'Glaze',
              'version': '0.7.0',
            },
          })
          .timeout(const Duration(seconds: 15));
      client.notify('initialized');
      return client;
    } catch (error) {
      await client.close();
      if (error is TimeoutException) {
        throw const CodexAppServerException(
          'Codex App Server did not complete its startup handshake. Update '
          'Codex CLI and try again.',
        );
      }
      rethrow;
    }
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
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    await _session.close();
    await _stderrSubscription.cancel();
    try {
      await _process.stdin.close();
    } catch (_) {
      // The process may already have closed its input after a protocol error.
    }
    if (_process.kill()) {
      try {
        await _process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        if (!Platform.isWindows) {
          _process.kill(ProcessSignal.sigkill);
        }
      }
    }
  }
}

/// Minimal process environment for the isolated App Server.
///
/// In particular, authentication and workload-identity variables are not
/// inherited. Both Codex state roots are pinned to the Glaze-owned directory,
/// while ordinary locale, temporary-directory, proxy and CA settings remain
/// available so browser sign-in works in managed network environments.
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
    'NODE_EXTRA_CA_CERTS',
    'NO_PROXY',
    'PATH',
    'PATHEXT',
    'ProgramData',
    'ProgramFiles',
    'ProgramFiles(x86)',
    'SSL_CERT_DIR',
    'SSL_CERT_FILE',
    'SystemRoot',
    'TEMP',
    'TMP',
    'TMPDIR',
    'TZ',
    'USER',
    'USERPROFILE',
    'WINDIR',
    'http_proxy',
    'https_proxy',
    'no_proxy',
    'HTTP_PROXY',
    'HTTPS_PROXY',
    'CODEX_CA_CERTIFICATE',
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

  static Future<String>? _prepared;

  static Future<String> prepare() => _prepared ??= _prepare();

  static Future<String> _prepare() async {
    final root = await getAppDataDir();
    final home = Directory('$root${Platform.pathSeparator}codex_chatgpt');
    await home.create(recursive: true);

    // Force file-backed credentials so the isolated home cannot silently pick
    // up a separate Codex login from a shared OS keychain entry.
    final config = File('${home.path}${Platform.pathSeparator}config.toml');
    await config.writeAsString(_isolatedConfig, flush: true);

    if (!Platform.isWindows) {
      try {
        await Process.run('/bin/chmod', ['700', home.path]);
      } catch (_) {
        // Codex still creates its credential file with restrictive
        // permissions. Sandboxed desktop builds may not expose chmod.
      }
    }
    return home.path;
  }

  static const String _isolatedConfig = '''
cli_auth_credentials_store = "file"
check_for_update_on_startup = false
project_doc_max_bytes = 0
approval_policy = "never"
sandbox_mode = "read-only"
allow_login_shell = false
forced_login_method = "chatgpt"

[history]
persistence = "none"

[feedback]
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
browser_use = false
computer_use = false
goals = false
hooks = false
image_generation = false
memories = false
multi_agent = false
plugins = false
shell_tool = false
skill_search = false
unified_exec = false
view_image = false
workspace_dependencies = false

[tools]
web_search = false
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
      if (File(candidate).existsSync()) return candidate;
    }

    // Process.start can still resolve shell-installed commands from PATH. If
    // it cannot, start() translates ProcessException into a clear user error.
    return Platform.isWindows ? 'codex' : executableName;
  }
}
