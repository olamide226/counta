import 'package:flutter/material.dart';

import '../../core/config/build_config.dart';
import '../../domain/counting/block_service.dart';
import '../../domain/counting/counting_engine.dart';
import '../../domain/models/phrase_history_entry.dart';
import '../../domain/validation/phrase_validator.dart';

/// Where the user says what this voice session should listen for.
///
/// A session can count several phrases towards one total, but the single
/// phrase case is the common one and must not pay for that: the screen opens
/// as one field and a button, exactly as it did when only one phrase was
/// possible. Extra rows are opt-in, and a row left blank is ignored rather
/// than treated as a mistake.
class PhraseSetupScreen extends StatefulWidget {
  final List<PhraseHistoryEntry> recentPhrases;

  /// Starts the session. Awaited: the sheet stays open, showing why, when
  /// starting fails — popping first made a failed start look like a success.
  final Future<void> Function(PhraseSet phrases) onStartSession;

  /// The phrases of a session being resumed, which come back as rows.
  final List<String>? initialPhrases;

  const PhraseSetupScreen({
    super.key,
    this.recentPhrases = const [],
    this.initialPhrases,
    required this.onStartSession,
  });

  @override
  State<PhraseSetupScreen> createState() => _PhraseSetupScreenState();
}

class _PhraseSetupScreenState extends State<PhraseSetupScreen> {
  /// Shown in the first row when there is nothing to resume, as an example of
  /// the kind of thing that counts well.
  static const String _exemplarPhrase = "I'm rich in wisdom";

  final PhraseValidator _validator = PhraseValidator();
  final List<_PhraseRow> _rows = [];

  PhraseSetValidationResult? _validationResult;
  String? _startError;
  bool _starting = false;

  bool get _isResuming => widget.initialPhrases?.isNotEmpty ?? false;
  bool get _canAddRow => _rows.length < PhraseValidator.maxPhrases;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialPhrases?.where((p) => p.trim().isNotEmpty);
    for (final phrase
        in (initial?.isNotEmpty ?? false)
            ? initial!
            : const [_exemplarPhrase]) {
      _rows.add(_createRow(phrase));
    }
    _validateCurrentInput();
  }

  _PhraseRow _createRow(String text) {
    final row = _PhraseRow(text);
    row.controller.addListener(_validateCurrentInput);
    return row;
  }

  /// Drops a row the user removed.
  ///
  /// The controller is disposed after the frame, not during it: the
  /// [TextField] that still holds it is only unmounted by the rebuild this
  /// removal triggers, and disposing underneath a mounted field throws.
  void _retireRow(_PhraseRow row) {
    row.controller.removeListener(_validateCurrentInput);
    WidgetsBinding.instance.addPostFrameCallback((_) => row.dispose());
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.controller.removeListener(_validateCurrentInput);
      row.dispose();
    }
    super.dispose();
  }

  void _validateCurrentInput() {
    setState(() {
      _validationResult = _validator.validateSet([
        for (final row in _rows) row.controller.text,
      ]);
    });
  }

  void _addPhraseRow({String text = ''}) {
    if (!_canAddRow) return;
    final row = _createRow(text);
    setState(() => _rows.add(row));
    _validateCurrentInput();
    // The row the user just asked for should be the one they are typing in.
    row.focusNode.requestFocus();
  }

  void _removePhraseRow(int index) {
    if (_rows.length <= 1) return;
    _retireRow(_rows.removeAt(index));
    _validateCurrentInput();
  }

  /// Applies a recent setup.
  ///
  /// A remembered *set* is a whole setup, so it replaces what is there. A
  /// single phrase replaces the lone row when there is only one — the user is
  /// still choosing *the* phrase — but joins the list once they have started
  /// building one, which is what makes a set out of two remembered singles.
  void _applyRecent(PhraseHistoryEntry entry) {
    if (entry.isSet || _rows.length == 1) {
      for (final row in _rows) {
        _retireRow(row);
      }
      _rows.clear();
      for (final phrase in entry.phrases.take(PhraseValidator.maxPhrases)) {
        _rows.add(_createRow(phrase));
      }
      _validateCurrentInput();
      return;
    }

    final blankRow = _rows.indexWhere((r) => r.controller.text.trim().isEmpty);
    if (blankRow >= 0) {
      _rows[blankRow].controller.text = entry.phrases.first;
    } else {
      _addPhraseRow(text: entry.phrases.first);
    }
  }

  /// Recent setups still worth offering: a single phrase already in the rows
  /// would only earn a duplicate error, so it is not shown.
  ///
  /// Compared by the validator's own notion of phrase identity, not by raw
  /// text. Matching on text offered "I'm rich in wisdom" next to a row
  /// reading "Im rich in wisdom", and tapping it produced an immediate
  /// duplicate error with nothing to say which chips were safe.
  List<PhraseHistoryEntry> get _offerableRecents {
    final present = {
      for (final row in _rows)
        if (row.controller.text.trim().isNotEmpty)
          _validator.identityOf(row.controller.text),
    };
    return [
      for (final entry in widget.recentPhrases)
        if (entry.isSet ||
            !present.contains(_validator.identityOf(entry.phrases.first)))
          entry,
    ];
  }

  Future<void> _handleSubmit() async {
    _validateCurrentInput();
    final phrases = _validationResult?.phraseSet;
    if (phrases == null) return;

    setState(() {
      _starting = true;
      _startError = null;
    });

    try {
      await widget.onStartSession(phrases);
    } on VoiceUnavailable catch (error) {
      // Nothing to retry: this build cannot obtain a credential at all.
      if (mounted) {
        setState(() {
          _starting = false;
          _startError = error.message;
        });
      }
      return;
    } on BlockFailure catch (failure) {
      // The voice service said no, and each refusal carries a sentence
      // written for the person reading it. The exception itself must never be
      // interpolated here: several of them print as debugging labels, which
      // is how "Block insufficient credit. Balance zero, required five"
      // reached a user's screen.
      if (mounted) {
        setState(() {
          _starting = false;
          _startError = failure.message;
        });
      }
      return;
    } catch (error) {
      if (mounted) {
        setState(() {
          _starting = false;
          // Unknown failures get a plain sentence. The raw error is only
          // useful to someone who can act on it, so it is shown in dev builds
          // alone.
          _startError = BuildConfig.showDebugTools
              ? "Couldn't start voice counting. Please try again.\n\n$error"
              : "Couldn't start voice counting. Please try again.";
        });
      }
      return;
    }

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = _validationResult;
    final isValid = result?.isValid ?? false;
    final errors = result?.errors ?? const <String?>[];
    final warnings = result?.warnings ?? const <String>[];
    final recents = _offerableRecents;
    final isMultiple = _rows.length > 1;

    return Scaffold(
      appBar: AppBar(title: const Text('Phrase Setup'), centerTitle: true),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(20.0),
                children: [
                  Text(
                    isMultiple
                        ? 'What would you like to repeat?'
                        : 'What phrase or mantra would you like to repeat?',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  for (int i = 0; i < _rows.length; i++)
                    Padding(
                      padding: EdgeInsets.only(
                        bottom: i == _rows.length - 1 ? 0 : 12,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _rows[i].controller,
                              focusNode: _rows[i].focusNode,
                              autofocus: i == 0 && !_isResuming,
                              maxLines: 2,
                              minLines: 1,
                              textInputAction: i == _rows.length - 1
                                  ? TextInputAction.done
                                  : TextInputAction.next,
                              onSubmitted: (_) {
                                if (i == _rows.length - 1 &&
                                    isValid &&
                                    !_starting) {
                                  _handleSubmit();
                                }
                              },
                              decoration: InputDecoration(
                                labelText: isMultiple
                                    ? 'Phrase ${i + 1}'
                                    : 'Target Phrase',
                                hintText: 'e.g. $_exemplarPhrase',
                                border: const OutlineInputBorder(),
                                errorText: i < errors.length ? errors[i] : null,
                                errorMaxLines: 2,
                              ),
                            ),
                          ),
                          if (isMultiple)
                            IconButton(
                              onPressed: () => _removePhraseRow(i),
                              icon: const Icon(Icons.close_rounded),
                              tooltip: 'Remove phrase ${i + 1}',
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 4),
                  if (_canAddRow)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _addPhraseRow,
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('Add another phrase'),
                      ),
                    )
                  else
                    Text(
                      'That is the most phrases one session can count.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  if (isMultiple) ...[
                    const SizedBox(height: 4),
                    // The one thing that is not obvious from the form: these
                    // are not separate counters.
                    Text(
                      'Any of these counts towards the same total.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  for (final warning in warnings) ...[
                    const SizedBox(height: 12),
                    _NoticeBox(message: warning),
                  ],
                  if (recents.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text(
                      'Recent',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final entry in recents)
                          ActionChip(
                            avatar: entry.isSet
                                ? const Icon(Icons.layers_outlined, size: 16)
                                : null,
                            // A phrase can be twelve words, and a set label
                            // adds "+2 more" on top. Unbounded, one chip is
                            // wider than the screen and the wrap overflows.
                            label: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth:
                                    MediaQuery.sizeOf(context).width * 0.7,
                              ),
                              child: Text(
                                entry.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            onPressed: () => _applyRecent(entry),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_startError != null) ...[
                    _NoticeBox(message: _startError!, isError: true),
                    const SizedBox(height: 12),
                  ],
                  ElevatedButton.icon(
                    onPressed: isValid && !_starting ? _handleSubmit : null,
                    icon: const Icon(Icons.mic),
                    label: Text(
                      _isResuming
                          ? 'Resume Voice Session'
                          : 'Start Voice Session',
                    ),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: Colors.deepPurple,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One phrase input, owning the controller and focus node that belong to it.
///
/// Rows are added and removed, so keeping the two in one object is what stops
/// a removal disposing the controller of one row and the focus node of
/// another.
class _PhraseRow {
  _PhraseRow(String text) : controller = TextEditingController(text: text);

  final TextEditingController controller;
  final FocusNode focusNode = FocusNode();

  void dispose() {
    controller.dispose();
    focusNode.dispose();
  }
}

/// A soft advisory, or a hard failure when [isError].
class _NoticeBox extends StatelessWidget {
  const _NoticeBox({required this.message, this.isError = false});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = isError
        ? scheme.errorContainer
        : scheme.surfaceContainerHighest;
    final foreground = isError ? scheme.onErrorContainer : scheme.onSurface;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.info_outline_rounded,
            size: 18,
            color: foreground,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: TextStyle(color: foreground)),
          ),
        ],
      ),
    );
  }
}
