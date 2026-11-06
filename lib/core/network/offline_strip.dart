import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:rhythmo/core/network/network_status.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';

/// What the strip says. Browsers keep no songs for offline play yet, so
/// there it only says the app is offline.
const offlineStripText = kIsWeb
    ? 'آفلاین هستی؛ بعد از وصل شدن به‌روز می‌شود'
    : 'آفلاین؛ آهنگ‌های ذخیره‌شده پخش می‌شوند';

/// A slim line above every screen while the server can't be reached, so the
/// listener knows why some things wait: music kept on the device still
/// plays, and the app catches up by itself once it is back online.
class OfflineStrip extends StatelessWidget {
  const OfflineStrip({super.key, required this.network, required this.child});

  final NetworkStatus network;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: network,
      builder: (context, _) {
        final online = network.online;
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final media = MediaQuery.of(context);
        // The same two children online and off, so the screens below keep
        // their state when the connection comes and goes.
        return Column(
          children: [
            if (online)
              const SizedBox.shrink()
            else
              Material(
                color: scheme.surfaceContainerHigh,
                child: Padding(
                  padding: EdgeInsets.only(top: media.padding.top),
                  child: Semantics(
                    liveRegion: true,
                    child: SizedBox(
                      height: 28,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(RhythmoIcons.cloudSlash,
                              size: 14, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              offlineStripText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: MediaQuery(
                data: online ? media : media.removePadding(removeTop: true),
                child: child,
              ),
            ),
          ],
        );
      },
    );
  }
}
