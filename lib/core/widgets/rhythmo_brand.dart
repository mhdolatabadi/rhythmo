import 'package:flutter/material.dart';
import 'package:rhythmo/core/widgets/rhythmo_mark.dart';

/// The rhythmo mark and name, as every main screen's app bar shows it; wide
/// screens add a line about what rhythmo is.
class RhythmoBrand extends StatelessWidget {
  const RhythmoBrand({super.key, this.compact = true});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final showSubtitle = !compact && constraints.maxWidth >= 220;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            RhythmoMark(size: compact ? 32 : 44),
            const SizedBox(width: 12),
            Flexible(
              child: showSubtitle
                  ? const Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'ریتمو',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          'موسیقی شخصی تو',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    )
                  : const Text(
                      'ریتمو',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}
