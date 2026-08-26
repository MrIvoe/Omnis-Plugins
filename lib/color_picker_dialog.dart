import 'package:flutter/material.dart';

/// Shared color-picker dialog: a fixed swatch of named preset colors plus
/// a hex-entry field for arbitrary values.
///
/// There is no external color-picker package dependency in this project
/// (a deliberate choice) — a closed set of presets plus a hand-rolled hex
/// field is enough for this app's needs, so this stays hand-rolled rather
/// than pulling one in.
///
/// A duplicate of the Omnis app's own `lib/ui/widgets/color_picker_dialog
/// .dart` — not a move, for two independent reasons. First, three app-side
/// callers that this task doesn't touch still need it there
/// (`appearance_settings_page.dart` for the accent color, and
/// `theme_editor_page.dart` for each of `ThemeManifest`'s nine color-scheme
/// roles, which also uses its static `colorToHex`/`colorFromHex`
/// helpers), so the app's copy can't go away. Second, even a
/// plugins-side-only consumer couldn't have imported the app's copy at
/// the time this was written: this plan's own Global Constraint deferred
/// every cross-repo `omnis_plugins` pin bump to Tier 2 task 6, and the
/// dependency only points one way regardless. Task 6 has since bumped
/// that pin (Omnis now pins `omnis_plugins` at `v0.51.0`), so that
/// specific blocker is gone — but task 6 only bumped the pin, it didn't
/// consolidate any duplicated files, so both copies still exist
/// unchanged and remain a candidate for consolidation, not done here,
/// just flagged — same reasoning `track_artwork.dart`/
/// `schema_versioning.dart`'s own doc comments already spell out for
/// their duplicates. `MoodBuilderPage`
/// (moved here with the rest of the Moods cluster) needs a color picker
/// for a custom mood's tile color; this is that picker, kept
/// byte-for-byte equivalent to the app's copy so the two stay trivially
/// comparable.
class ColorPickerDialog extends StatefulWidget {
  final Color initialColor;
  final String title;

  const ColorPickerDialog({
    super.key,
    required this.initialColor,
    this.title = 'Choose a color',
  });

  /// `#RRGGBB` (uppercase, no alpha) — the exact shape
  /// `ThemeManifest.parse`'s `_parseHexColor` accepts for a 6-character
  /// hex string (it treats a missing alpha as opaque), so a color chosen
  /// here round-trips through a saved theme file unchanged.
  static String colorToHex(Color color) {
    final r = (color.r * 255).round() & 0xff;
    final g = (color.g * 255).round() & 0xff;
    final b = (color.b * 255).round() & 0xff;
    return '#${r.toRadixString(16).padLeft(2, '0')}'
            '${g.toRadixString(16).padLeft(2, '0')}'
            '${b.toRadixString(16).padLeft(2, '0')}'
        .toUpperCase();
  }

  /// The inverse of [colorToHex] — mirrors `ThemeManifest`'s own
  /// `_parseHexColor` exactly (accepts `#RRGGBB` or `#AARRGGBB`, with or
  /// without the leading `#`) so a hex string entered here is guaranteed
  /// to be exactly what `ThemeManifest.parse` would later accept too.
  /// Returns `null` for anything that doesn't parse.
  static Color? colorFromHex(String input) {
    var text = input.trim();
    if (text.startsWith('#')) text = text.substring(1);
    if (text.length == 6) text = 'FF$text';
    if (text.length != 8) return null;
    final value = int.tryParse(text, radix: 16);
    return value == null ? null : Color(value);
  }

  @override
  State<ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<ColorPickerDialog> {
  // Not `const`: `Color`/`MaterialColor` override `==`, so the analyzer
  // rejects them as *constant* map keys (`const_map_key_not_primitive_equality`)
  // even though a plain map literal with these as runtime keys is fine.
  static final _presets = {
    Colors.deepPurple: 'Deep purple',
    Colors.blue: 'Blue',
    Colors.teal: 'Teal',
    Colors.green: 'Green',
    Colors.orange: 'Orange',
    Colors.pink: 'Pink',
    Colors.red: 'Red',
    Colors.amber: 'Amber',
    Colors.indigo: 'Indigo',
    Colors.black: 'Black',
    Colors.white: 'White',
    Colors.grey: 'Grey',
  };

  late Color _selectedColor;
  late final TextEditingController _hexController;
  String? _hexError;

  @override
  void initState() {
    super.initState();
    _selectedColor = widget.initialColor;
    _hexController =
        TextEditingController(text: ColorPickerDialog.colorToHex(_selectedColor));
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  void _selectPreset(Color color) {
    setState(() {
      _selectedColor = color;
      _hexController.text = ColorPickerDialog.colorToHex(color);
      _hexError = null;
    });
  }

  void _applyHex(String text) {
    final color = ColorPickerDialog.colorFromHex(text);
    setState(() {
      if (color == null) {
        _hexError = 'Enter a hex color, e.g. #FF6B6B';
      } else {
        _selectedColor = color;
        _hexError = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: _presets.entries.map((entry) {
                final color = entry.key;
                final name = entry.value;
                // `Color.toARGB32()` (the non-deprecated equality-safe
                // comparison) only exists from Flutter 3.29 — this project
                // builds on 3.27.4 (see `AppSettings._packArgb`'s own doc
                // comment for the same constraint), so compare via the hex
                // string both sides already compute rather than `.value`.
                final selected = ColorPickerDialog.colorToHex(color) ==
                    ColorPickerDialog.colorToHex(_selectedColor);
                return Semantics(
                  button: true,
                  label: name,
                  selected: selected,
                  child: GestureDetector(
                    onTap: () => _selectPreset(color),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: selected ? Colors.white : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('color_picker_hex_field'),
              controller: _hexController,
              decoration: InputDecoration(
                labelText: 'Hex color',
                hintText: '#RRGGBB',
                errorText: _hexError,
                prefixIcon: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Container(
                    decoration: BoxDecoration(
                      color: _selectedColor,
                      shape: BoxShape.circle,
                      border:
                          Border.all(color: Theme.of(context).dividerColor),
                    ),
                  ),
                ),
              ),
              onChanged: _applyHex,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: _hexError != null
                ? null
                : () => Navigator.pop(context, _selectedColor),
            child: const Text('Apply')),
      ],
    );
  }
}
