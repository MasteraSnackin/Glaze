import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/state/chat_session_ops_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/utils/time_formatter.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../chat_history/chat_history_provider.dart';
import '../chat_actions_service.dart';
import '../chat_provider.dart';
import '../generating_sessions_provider.dart';
import '../unread_sessions_provider.dart';

/// What the user picked in [showSessionPickerSheet]. Null means dismissed.
enum SessionPickerAction { open, newSession, importChat }

class SessionPickerResult {
  final SessionPickerAction action;

  /// The chosen session — set only for [SessionPickerAction.open].
  final SessionMetadata? session;

  const SessionPickerResult._(this.action, this.session);

  const SessionPickerResult.open(SessionMetadata session)
    : this._(SessionPickerAction.open, session);
  const SessionPickerResult.newSession()
    : this._(SessionPickerAction.newSession, null);
  const SessionPickerResult.importChat()
    : this._(SessionPickerAction.importChat, null);
}

/// The session picker, for every place that offers one.
///
/// The magic drawer and the character catalog both used to hand-roll this: the
/// drawer decoded whole sessions to render its own rows, the catalog listed
/// bare "Session #N" menu entries with a message count and nothing else, and
/// neither matched the chat list. They are the same list of the same rows —
/// only what a tap does differs — so they share this sheet, and it shows what
/// the chat list shows: session name, message count, relative time, an
/// origin-aware preview ("Created on …" / "Branched on …"), the unread dot, the
/// live "typing" line, and the same export / rename / delete actions (delete
/// behind the chat list's confirmation).
///
/// Resolves with the user's choice *after* the sheet has closed, so the caller
/// can navigate without chaining a second `Navigator.pop` onto the sheet's own
/// exit animation.
Future<SessionPickerResult?> showSessionPickerSheet(
  BuildContext context, {
  required String charId,
}) {
  return GlazeBottomSheet.show<SessionPickerResult>(
    context,
    title: 'history_title'.tr(),
    headerAction: const _SessionPickerAddButton(),
    child: SessionPickerList(charId: charId),
  );
}

class _SessionPickerAddButton extends StatelessWidget {
  const _SessionPickerAddButton();

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(Icons.add, color: context.cs.primary),
      onPressed: () {
        final rootNav = Navigator.of(context, rootNavigator: true);
        GlazeBottomSheet.show<SessionPickerAction>(
          context,
          title: 'action_new_session'.tr(),
          items: [
            BottomSheetItem(
              icon: Icons.add_circle_outline,
              label: 'action_new_session'.tr(),
              onTap: () => rootNav.pop(SessionPickerAction.newSession),
            ),
            BottomSheetItem(
              icon: Icons.file_download,
              label: 'action_import'.tr(),
              onTap: () => rootNav.pop(SessionPickerAction.importChat),
            ),
          ],
        ).then((action) {
          // Runs once the inner sheet's route is gone, so this pop closes the
          // picker rather than racing the menu's exit animation.
          if (action == SessionPickerAction.newSession) {
            rootNav.pop(const SessionPickerResult.newSession());
          } else if (action == SessionPickerAction.importChat) {
            rootNav.pop(const SessionPickerResult.importChat());
          }
        });
      },
    );
  }
}

/// The rows of [showSessionPickerSheet]. Pops its route with a
/// [SessionPickerResult] when a session is tapped.
class SessionPickerList extends ConsumerStatefulWidget {
  final String charId;

  const SessionPickerList({super.key, required this.charId});

  @override
  ConsumerState<SessionPickerList> createState() => _SessionPickerListState();
}

class _SessionPickerListState extends ConsumerState<SessionPickerList> {
  List<SessionMetadata> _sessions = const [];
  bool _loading = true;

  /// Bumped by every load so a slow one that started earlier cannot publish
  /// over a newer result — deleting a session reloads the list while the
  /// previous reload may still be in flight.
  int _loadEpoch = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final epoch = ++_loadEpoch;
    // Metadata only: the drawer used to decode every message of every session
    // just to render counts and a preview line, which is what made this sheet
    // slow to open on a character with a long history.
    final sessions = await ref
        .read(chatSessionOpsProvider.notifier)
        .getSessionMetadataByCharacter(widget.charId);
    if (!mounted || epoch != _loadEpoch) return;
    sessions.sort(
      (a, b) => sessionPreviewAndTime(
        b,
      ).time.compareTo(sessionPreviewAndTime(a).time),
    );
    setState(() {
      _sessions = sessions;
      _loading = false;
    });
  }

  String _title(SessionMetadata session) {
    final name = session.sessionName?.trim();
    if (name != null && name.isNotEmpty) return name;
    return 'session_name'.tr(
      namedArgs: {'id': (session.sessionIndex + 1).toString()},
    );
  }

  @override
  Widget build(BuildContext context) {
    // The history provider is the single source of truth for session metadata;
    // renaming or deleting from this sheet moves it, and so does a reply
    // landing in another session while the sheet is open.
    ref.listen(chatHistoryProvider, (previous, next) => _load());

    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32.0),
          child: GlazeSpinner(),
        ),
      );
    }

    final activeSessionId = ref
        .watch(chatProvider(widget.charId))
        .value
        ?.session
        ?.id;
    final generatingSessions = ref.watch(generatingSessionsProvider);
    final unreadSessions = ref.watch(unreadSessionsProvider);

    return GlazeSessionList(
      items: [
        for (final session in _sessions)
          _itemFor(
            session,
            activeSessionId: activeSessionId,
            generating: generatingSessions.contains(session.sessionId),
            unread: unreadSessions.contains(session.sessionId),
          ),
      ],
    );
  }

  BottomSheetSessionItem _itemFor(
    SessionMetadata session, {
    required String? activeSessionId,
    required bool generating,
    required bool unread,
  }) {
    final row = sessionPreviewAndTime(session);
    return BottomSheetSessionItem(
      title: _title(session),
      count: session.messageCount,
      time: row.time == 0 ? '' : formatSessionTimeAgo(row.time),
      preview: row.preview.isEmpty ? 'No messages yet' : row.preview,
      isActive: session.sessionId == activeSessionId,
      generating: generating,
      // A live reply supersedes the unread dot: the row already reads as
      // "active". Same rule as the chat list.
      unread: !generating && unread,
      onTap: () => Navigator.of(
        context,
        rootNavigator: true,
      ).pop(SessionPickerResult.open(session)),
      onMore: () => _showSessionActions(session),
    );
  }

  void _showSessionActions(SessionMetadata session) {
    GlazeBottomSheet.show<String>(
      context,
      title: 'Session',
      items: [
        BottomSheetItem(
          icon: Icons.upload_file,
          label: 'action_export_chat'.tr(),
          onTap: () => Navigator.of(context, rootNavigator: true).pop('export'),
        ),
        BottomSheetItem(
          icon: Icons.drive_file_rename_outline,
          label: 'action_rename'.tr(),
          onTap: () => Navigator.of(context, rootNavigator: true).pop('rename'),
        ),
        BottomSheetItem(
          icon: Icons.delete_outline,
          label: 'action_delete'.tr(),
          isDestructive: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop('delete'),
        ),
      ],
    ).then((result) async {
      if (!mounted) return;
      switch (result) {
        case 'export':
          await ref
              .read(chatActionsServiceProvider)
              .exportSessionUI(
                context,
                charId: widget.charId,
                sessionId: session.sessionId,
              );
        case 'rename':
          _showRenameDialog(session);
        case 'delete':
          _confirmDelete(session);
      }
    });
  }

  void _showRenameDialog(SessionMetadata session) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'Rename Session',
      input: BottomSheetInput(
        placeholder: 'Session name',
        value: _title(session),
        confirmLabel: 'action_rename'.tr(),
        onConfirm: (val) {
          Navigator.of(context, rootNavigator: true).pop();
          if (val.trim().isEmpty) return;
          ref
              .read(chatHistoryProvider.notifier)
              .renameSession(session.sessionId, val.trim());
        },
      ),
    );
  }

  void _confirmDelete(SessionMetadata session) {
    // Deleting a chat is not undoable, so it confirms — the same sheet the
    // chat list uses. The drawer used to delete on the first tap.
    GlazeBottomSheet.show<void>(
      context,
      title: 'action_delete_session'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline,
        description:
            '${'action_delete_session'.tr()} — ${_title(session)}? '
            '${'chat_clear_confirm'.tr()}',
      ),
      items: [
        BottomSheetItem(
          label: 'btn_delete'.tr(),
          isDestructive: true,
          centered: true,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            // `deleteSession` rebinds the chat provider itself, so the open
            // chat can never be left pointing at the row that just went away.
            ref
                .read(chatHistoryProvider.notifier)
                .deleteSession(session.sessionId);
          },
        ),
        BottomSheetItem(
          label: 'btn_cancel'.tr(),
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
      ],
    );
  }
}
