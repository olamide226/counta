import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/enums.dart';
import '../../state/providers/settings_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings'), centerTitle: true),
      body: ListView(
        children: [
          _buildSectionHeader(context, 'Appearance'),
          ListTile(
            leading: const Icon(Icons.brightness_6),
            title: const Text('Theme Mode'),
            subtitle: Text(_themeModeLabel(settings.themeModeChoice)),
            onTap: () =>
                _showThemeModeDialog(context, ref, settings.themeModeChoice),
          ),
          ListTile(
            leading: const Icon(Icons.palette),
            title: const Text('Color Theme'),
            subtitle: Text(_themeIdLabel(settings.themeId)),
            onTap: () => _showThemeIdDialog(context, ref, settings.themeId),
          ),
          const Divider(),
          _buildSectionHeader(context, 'Sound & Feedback'),
          ListTile(
            leading: Icon(_soundModeIcon(settings.soundMode)),
            title: const Text('Sound Mode'),
            subtitle: Text(_soundModeLabel(settings.soundMode)),
            onTap: () => _showSoundModeDialog(context, ref, settings.soundMode),
          ),
          const Divider(),
          _buildSectionHeader(context, 'Default Alert Settings'),
          ListTile(
            leading: const Icon(Icons.flag),
            title: const Text('Default Threshold'),
            subtitle: Text(settings.defaultThreshold?.toString() ?? 'Not set'),
            onTap: () =>
                _showThresholdDialog(context, ref, settings.defaultThreshold),
          ),
          ListTile(
            leading: const Icon(Icons.repeat),
            title: const Text('Default Repeat Interval'),
            subtitle: Text(
              settings.defaultRepeatInterval?.toString() ?? 'Not set',
            ),
            onTap: () =>
                _showRepeatDialog(context, ref, settings.defaultRepeatInterval),
          ),
          const Divider(),
          _buildSectionHeader(context, 'Behavior'),
          SwitchListTile(
            secondary: const Icon(Icons.warning),
            title: const Text('Confirm Reset'),
            subtitle: const Text('Ask before resetting count'),
            value: settings.confirmReset,
            onChanged: (_) =>
                ref.read(settingsProvider.notifier).toggleConfirmReset(),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.screen_lock_portrait),
            title: const Text('Keep Screen On'),
            subtitle: const Text('Prevent screen from sleeping'),
            value: settings.keepScreenOn,
            onChanged: (_) =>
                ref.read(settingsProvider.notifier).toggleKeepScreenOn(),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  String _themeModeLabel(ThemeModeChoice mode) {
    return switch (mode) {
      ThemeModeChoice.system => 'System',
      ThemeModeChoice.light => 'Light',
      ThemeModeChoice.dark => 'Dark',
    };
  }

  String _themeIdLabel(AppThemeId id) {
    return switch (id) {
      AppThemeId.ocean => 'Ocean',
      AppThemeId.forest => 'Forest',
      AppThemeId.sunset => 'Sunset',
      AppThemeId.mono => 'Mono',
      AppThemeId.lavender => 'Lavender',
    };
  }

  IconData _soundModeIcon(SoundMode mode) {
    return switch (mode) {
      SoundMode.mute => Icons.volume_off,
      SoundMode.sound => Icons.volume_up,
      SoundMode.vibrate => Icons.vibration,
      SoundMode.soundAndVibrate => Icons.speaker_phone,
    };
  }

  String _soundModeLabel(SoundMode mode) {
    return switch (mode) {
      SoundMode.mute => 'Mute',
      SoundMode.sound => 'Sound Only',
      SoundMode.vibrate => 'Vibrate Only',
      SoundMode.soundAndVibrate => 'Sound & Vibrate',
    };
  }

  void _showThemeModeDialog(
    BuildContext context,
    WidgetRef ref,
    ThemeModeChoice current,
  ) {
    showDialog(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Theme Mode'),
        children: ThemeModeChoice.values.map((mode) {
          return RadioListTile<ThemeModeChoice>(
            title: Text(_themeModeLabel(mode)),
            value: mode,
            groupValue: current,
            onChanged: (value) {
              if (value != null) {
                ref.read(settingsProvider.notifier).setThemeModeChoice(value);
                Navigator.of(context).pop();
              }
            },
          );
        }).toList(),
      ),
    );
  }

  void _showThemeIdDialog(
    BuildContext context,
    WidgetRef ref,
    AppThemeId current,
  ) {
    showDialog(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Color Theme'),
        children: AppThemeId.values.map((id) {
          return RadioListTile<AppThemeId>(
            title: Text(_themeIdLabel(id)),
            value: id,
            groupValue: current,
            onChanged: (value) {
              if (value != null) {
                ref.read(settingsProvider.notifier).setThemeId(value);
                Navigator.of(context).pop();
              }
            },
          );
        }).toList(),
      ),
    );
  }

  void _showSoundModeDialog(
    BuildContext context,
    WidgetRef ref,
    SoundMode current,
  ) {
    showDialog(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Sound Mode'),
        children: SoundMode.values.map((mode) {
          return RadioListTile<SoundMode>(
            title: Text(_soundModeLabel(mode)),
            secondary: Icon(_soundModeIcon(mode)),
            value: mode,
            groupValue: current,
            onChanged: (value) {
              if (value != null) {
                ref.read(settingsProvider.notifier).setSoundMode(value);
                Navigator.of(context).pop();
              }
            },
          );
        }).toList(),
      ),
    );
  }

  void _showThresholdDialog(BuildContext context, WidgetRef ref, int? current) {
    final controller = TextEditingController(text: current?.toString() ?? '');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Default Threshold'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            hintText: 'e.g. 100',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              ref.read(settingsProvider.notifier).setDefaultThreshold(null);
              Navigator.of(context).pop();
            },
            child: const Text('Clear'),
          ),
          FilledButton(
            onPressed: () {
              final value = int.tryParse(controller.text);
              ref.read(settingsProvider.notifier).setDefaultThreshold(value);
              Navigator.of(context).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showRepeatDialog(BuildContext context, WidgetRef ref, int? current) {
    final controller = TextEditingController(text: current?.toString() ?? '');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Default Repeat Interval'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            hintText: 'e.g. 100',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              ref
                  .read(settingsProvider.notifier)
                  .setDefaultRepeatInterval(null);
              Navigator.of(context).pop();
            },
            child: const Text('Clear'),
          ),
          FilledButton(
            onPressed: () {
              final value = int.tryParse(controller.text);
              ref
                  .read(settingsProvider.notifier)
                  .setDefaultRepeatInterval(value);
              Navigator.of(context).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
