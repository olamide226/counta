import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers/ui_settings_provider.dart';

class ResizableTapLayout extends ConsumerWidget {
  const ResizableTapLayout({
    super.key,
    required this.tapChild,
    required this.infoChild,
    this.handleExtent = 24,
  });

  final Widget tapChild;
  final Widget infoChild;
  final double handleExtent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final ratio = ref.watch(tapZoneRatioProvider);
        final isLandscape = constraints.maxWidth > constraints.maxHeight;

        if (isLandscape) {
          return _buildHorizontal(context, ref, constraints, ratio);
        }

        return _buildVertical(context, ref, constraints, ratio);
      },
    );
  }

  Widget _buildVertical(
    BuildContext context,
    WidgetRef ref,
    BoxConstraints constraints,
    double ratio,
  ) {
    final maxHeight = constraints.maxHeight;
    final tapHeight = maxHeight * ratio;
    final infoHeight = maxHeight - tapHeight - handleExtent;

    return Column(
      children: [
        SizedBox(height: tapHeight, child: tapChild),
        _ResizeHandle(
          axis: Axis.vertical,
          extent: handleExtent,
          onDrag: (delta) {
            final next = ((tapHeight + delta) / maxHeight).clamp(
              kMinTapZoneRatio,
              kMaxTapZoneRatio,
            );
            ref.read(tapZoneRatioProvider.notifier).state = next;
          },
        ),
        SizedBox(height: infoHeight, child: infoChild),
      ],
    );
  }

  Widget _buildHorizontal(
    BuildContext context,
    WidgetRef ref,
    BoxConstraints constraints,
    double ratio,
  ) {
    final maxWidth = constraints.maxWidth;
    final tapWidth = maxWidth * ratio;
    final infoWidth = maxWidth - tapWidth - handleExtent;

    return Row(
      children: [
        SizedBox(width: tapWidth, child: tapChild),
        _ResizeHandle(
          axis: Axis.horizontal,
          extent: handleExtent,
          onDrag: (delta) {
            final next = ((tapWidth + delta) / maxWidth).clamp(
              kMinTapZoneRatio,
              kMaxTapZoneRatio,
            );
            ref.read(tapZoneRatioProvider.notifier).state = next;
          },
        ),
        SizedBox(width: infoWidth, child: infoChild),
      ],
    );
  }
}

class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({
    required this.axis,
    required this.extent,
    required this.onDrag,
  });

  final Axis axis;
  final double extent;
  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    final isVertical = axis == Axis.vertical;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: isVertical
          ? (details) => onDrag(details.delta.dy)
          : null,
      onHorizontalDragUpdate: !isVertical
          ? (details) => onDrag(details.delta.dx)
          : null,
      child: SizedBox(
        height: isVertical ? extent : double.infinity,
        width: isVertical ? double.infinity : extent,
        child: Center(
          child: Container(
            width: isVertical ? 48 : 4,
            height: isVertical ? 4 : 48,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
      ),
    );
  }
}
