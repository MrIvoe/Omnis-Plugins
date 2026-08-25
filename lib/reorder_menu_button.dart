import 'package:flutter/material.dart';

/// A small trailing overflow menu offering "Move up"/"Move down" as a
/// keyboard/pointer-reachable alternative to dragging within a
/// `ReorderableListView` — every reorderable list in this app otherwise
/// relies entirely on long-press-drag, which has no keyboard-reachable
/// equivalent for a sighted keyboard-only desktop user (Flutter's own
/// screen-reader "Move up"/"Move down" `CustomSemanticsAction`s only help
/// a screen-reader user). Shown on every platform, not gated on any
/// `PlatformCapabilities` flag — a touch user with limited dexterity for
/// long-press-drag benefits from this too, so this is a genuine
/// accessibility improvement, not a desktop-only affordance.
///
/// A duplicate of the Omnis app's own
/// `lib/ui/widgets/reorder_menu_button.dart` — not a move, since several
/// other app-side reorderable lists (`playlist_page.dart`,
/// `global_sidebar_drawer.dart`, `queue_panel.dart`) still use that
/// original directly, and a bundled plugin can't import from
/// `package:omnis/` in the other direction either. The reason there
/// isn't instead a single shared copy living in `omnis_plugins` (which
/// the app already depends on — this isn't a "the app can't reach
/// omnis_plugins" situation) is this plan's own Global Constraint
/// deferring every cross-repo `omnis_plugins` pin bump to Tier 2 task 6:
/// the app is pinned to `omnis_plugins` tag `v0.50.0`, which predates
/// this file's existence, so there's no tagged release yet to import a
/// shared copy from. Once task 6 bumps that pin, this and the app's copy
/// become candidates for consolidation into one shared copy — not done
/// here, just flagged. This copy exists so `HomeDashboardPlugin`'s
/// extracted Customize-sheet reorder UI keeps the same keyboard-reachable
/// reorder fallback it had before the extraction.
///
/// [onReorder] must be the exact same callback the enclosing
/// `ReorderableListView.onReorder` already uses, and is invoked with the
/// `(oldIndex, newIndex)` pair a real one-position drag would produce —
/// per `ReorderableListView.onReorder`'s documented convention, `newIndex`
/// is computed *as if the dragged item had not yet been removed* from the
/// list. Moving up by one is therefore `(index, index - 1)` (no
/// adjustment needed, since the target precedes the removal point), but
/// moving down by one is `(index, index + 2)`, not `(index, index + 1)` —
/// every real `onReorder` implementation in this app already undoes that
/// "as if not yet removed" offset with its own `if (newIndex > oldIndex)
/// newIndex -= 1;`, exactly the way it would for a genuine drag. Passing
/// `(index, index + 1)` instead would have that adjustment cancel itself
/// out into a same-index no-op.
class ReorderMenuButton extends StatelessWidget {
  /// This row's current index within the reorderable list.
  final int index;

  /// The index of the last item in the reorderable list (`length - 1`).
  final int lastIndex;

  /// The same callback passed to the enclosing `ReorderableListView`'s
  /// `onReorder`.
  final void Function(int oldIndex, int newIndex) onReorder;

  const ReorderMenuButton({
    super.key,
    required this.index,
    required this.lastIndex,
    required this.onReorder,
  });

  @override
  Widget build(BuildContext context) {
    final canMoveUp = index > 0;
    final canMoveDown = index < lastIndex;
    // Nothing to offer on a single-item list — an empty-menu button would
    // just be dead weight.
    if (!canMoveUp && !canMoveDown) return const SizedBox.shrink();
    return PopupMenuButton<String>(
      tooltip: 'Reorder',
      icon: const Icon(Icons.swap_vert),
      onSelected: (value) {
        if (value == 'up') onReorder(index, index - 1);
        if (value == 'down') onReorder(index, index + 2);
      },
      itemBuilder: (context) => [
        if (canMoveUp) const PopupMenuItem(value: 'up', child: Text('Move up')),
        if (canMoveDown)
          const PopupMenuItem(value: 'down', child: Text('Move down')),
      ],
    );
  }
}
