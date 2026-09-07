import 'package:flutter/material.dart';

import '../../domain/counting/counting_engine.dart';
import '../../domain/models/phrase_history_entry.dart';
import '../../domain/validation/phrase_validator.dart';

class PhraseSetupScreen extends StatefulWidget {
  final List<PhraseHistoryEntry> recentPhrases;

  /// Starts the session. Awaited: the sheet stays open, showing why, when
  /// starting fails — popping first made a failed start look like a success.
  final Future<void> Function(PhraseSpec spec) onStartSession;
  final String? initialPhrase;

  const PhraseSetupScreen({
    super.key,
    this.recentPhrases = const [],
    this.initialPhrase,
    required this.onStartSession,
  });

  @override
  State<PhraseSetupScreen> createState() => _PhraseSetupScreenState();
}

class _PhraseSetupScreenState extends State<PhraseSetupScreen> {
  late final TextEditingController _controller;
  final PhraseValidator _validator = PhraseValidator();

  PhraseValidationResult? _validationResult;
  String? _startError;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.initialPhrase ?? "I'm rich in wisdom",
    );
    _validateCurrentInput();
    _controller.addListener(_validateCurrentInput);
  }

  @override
  void dispose() {
    _controller.removeListener(_validateCurrentInput);
    _controller.dispose();
    super.dispose();
  }

  void _validateCurrentInput() {
    setState(() {
      _validationResult = _validator.validate(_controller.text);
    });
  }

  void _selectPhrase(String phrase) {
    _controller.text = phrase;
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: phrase.length),
    );
  }

  Future<void> _handleSubmit() async {
    _validateCurrentInput();
    final spec = _validationResult?.phraseSpec;
    if (_validationResult?.isValid != true || spec == null) return;

    setState(() {
      _starting = true;
      _startError = null;
    });

    try {
      await widget.onStartSession(spec);
    } on VoiceUnavailable catch (error) {
      // Nothing to retry: this build cannot obtain a credential at all.
      if (mounted) {
        setState(() {
          _starting = false;
          _startError = error.message;
        });
      }
      return;
    } catch (error) {
      if (mounted) {
        setState(() {
          _starting = false;
          _startError = 'Could not start voice counting: $error';
        });
      }
      return;
    }

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isValid = _validationResult?.isValid ?? false;
    final errorMessage = _validationResult?.errorMessage;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Target Phrase Setup'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'What phrase or mantra would you like to repeat?',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                autofocus: true,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: 'Target Phrase',
                  hintText: 'e.g. I\'m rich in wisdom',
                  border: const OutlineInputBorder(),
                  errorText: errorMessage,
                ),
              ),
              const SizedBox(height: 16),
              if (widget.recentPhrases.isNotEmpty) ...[
                const Text(
                  'Recent Phrases',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: widget.recentPhrases.map((entry) {
                    return ActionChip(
                      label: Text(entry.raw),
                      onPressed: () => _selectPhrase(entry.raw),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
              ],
              const Spacer(),
              if (_startError != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _startError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              ElevatedButton.icon(
                onPressed: isValid && !_starting ? _handleSubmit : null,
                icon: const Icon(Icons.mic),
                label: Text(
                  widget.initialPhrase == null
                      ? 'Start Voice Session'
                      : 'Resume Voice Session',
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
      ),
    );
  }
}
