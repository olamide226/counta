import 'package:flutter/material.dart';

/// Shows a bottom sheet with the app's standard insets.
///
/// Every sheet had its own `showModalBottomSheet` call and its own padding
/// block, and they had already drifted: three allowed for the keyboard,
/// one did not, and one forgot `isScrollControlled`, which silently caps the
/// sheet at half the screen.
///
/// [dismissible] false is for a sheet that demands a decision — it also blocks
/// the drag-to-dismiss gesture. Wrap such a sheet's body in a `PopScope` so
/// the Android back gesture cannot dismiss it either.
Future<T?> showCountaSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool dismissible = true,
  bool showDragHandle = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    isDismissible: dismissible,
    enableDrag: dismissible,
    showDragHandle: showDragHandle,
    builder: builder,
  );
}

/// The standard body of a Counta sheet: 24pt margins, room for the keyboard,
/// and a column sized to its content.
class CountaSheetBody extends StatelessWidget {
  const CountaSheetBody({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        // Without this a text field in a sheet sits under the keyboard.
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}
