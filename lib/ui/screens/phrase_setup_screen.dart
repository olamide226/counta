import 'package:flutter/material.dart';

import '../../domain/counting/counting_engine.dart';
import '../../domain/models/phrase_history_entry.dart';
import '../../domain/validation/phrase_validator.dart';

class PhraseSetupScreen extends StatefulWidget {
  final List<PhraseHistoryEntry> recentPhrases;
  final Function(PhraseSpec spec) onStartSession;

  const PhraseSetupScreen({
    super.key,
    this.recentPhrases = const [],
    required this.onStartSession,
  });

  @override
  State<PhraseSetupScreen> createState() => _PhraseSetupScreenState();
}

class _PhraseSetupScreenState extends State<PhraseSetupScreen> {
  final TextEditingController _controller =
      TextEditingController(text: "I'm rich in wisdom");
  final PhraseValidator _validator = PhraseValidator();

  PhraseValidationResult? _validationResult;

  @override
  void initState() {
    super.initState();
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

  void _handleSubmit() {
    _validateCurrentInput();
    if (_validationResult != null &&
        _validationResult!.isValid &&
        _validationResult!.phraseSpec != null) {
      widget.onStartSession(_validationResult!.phraseSpec!);
      Navigator.of(context).pop();
    }
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
              ElevatedButton.icon(
                onPressed: isValid ? _handleSubmit : null,
                icon: const Icon(Icons.mic),
                label: const Text('Start Voice Session'),
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
