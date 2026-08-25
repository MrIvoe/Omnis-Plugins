import 'package:flutter/material.dart';
import 'package:omnis_plugin_api/custom_mood.dart';
import 'package:omnis_plugins/color_picker_dialog.dart';

/// A reasonable default vocabulary of mood tags to offer when the current
/// library has no `BaseTrack.mood` values scanned in yet — so the picker
/// never renders an empty, useless chip row for a fresh library. Real
/// mood values found in the library (passed via [MoodBuilderPage
/// .knownMoodTags]) are always shown in addition to these.
const _defaultMoodTags = [
  'Happy',
  'Chill',
  'Energetic',
  'Dark',
  'Relaxed',
  'Focused',
  'Romantic',
  'Melancholic',
];

/// UI_SPEC §13/§14's "user-created moods" builder — full-page like
/// `ThemeEditorPage` (this app's existing convention for editing a rich,
/// many-field object), not a modal dialog: a mood has too many
/// independent fields (name, genres, mood tags, BPM range, rating floor,
/// exclusion, time window, color, icon) to fit comfortably in an
/// `AlertDialog`.
///
/// Moved here from the Omnis app's own `lib/ui/mood_builder_dialog.dart`
/// (Tier 2 task 4) with the rest of the Moods cluster — `MoodsPage` is its
/// only caller.
///
/// Returns the built [CustomMood] via `Navigator.pop(context, mood)` on
/// save, `null` on cancel/back — the caller (the Moods page) owns
/// persisting it via `CustomMoodStore`, the same "dialog returns a value,
/// caller decides what to do with it" shape `ColorPickerDialog` already
/// established.
class MoodBuilderPage extends StatefulWidget {
  /// `null` for "create new"; a real mood for "edit existing" (prefills
  /// every field, keeps the same [CustomMood.id]).
  final CustomMood? existing;

  /// Real genres/mood values seen in the current library — sourced by the
  /// caller (the Moods page), which already has the library loaded.
  final List<String> knownGenres;
  final List<String> knownMoodTags;

  const MoodBuilderPage({
    super.key,
    this.existing,
    this.knownGenres = const [],
    this.knownMoodTags = const [],
  });

  @override
  State<MoodBuilderPage> createState() => _MoodBuilderPageState();
}

class _MoodBuilderPageState extends State<MoodBuilderPage> {
  late final TextEditingController _nameController;
  late Set<String> _selectedGenres;
  late Set<String> _selectedMoodTags;
  RangeValues _bpmRange = const RangeValues(60, 180);
  bool _bpmEnabled = false;
  int _ratingFloor = 0;
  bool _excludeRecentlyPlayed = false;
  late final TextEditingController _excludeDaysController;
  bool _timeWindowEnabled = false;
  TimeOfDay _windowStart = const TimeOfDay(hour: 21, minute: 0);
  TimeOfDay _windowEnd = const TimeOfDay(hour: 3, minute: 0);
  Color? _color;
  late CustomMoodIcon _icon;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _nameController = TextEditingController(text: existing?.name ?? '');
    _selectedGenres = {...?existing?.genres};
    _selectedMoodTags = {...?existing?.moodTags};
    if (existing?.minBpm != null || existing?.maxBpm != null) {
      _bpmEnabled = true;
      _bpmRange = RangeValues(
        existing?.minBpm ?? 60,
        existing?.maxBpm ?? 180,
      );
    }
    _ratingFloor = existing?.ratingFloor ?? 0;
    _excludeRecentlyPlayed = existing?.excludeRecentlyPlayedDays != null;
    _excludeDaysController = TextEditingController(
      text: '${existing?.excludeRecentlyPlayedDays ?? 7}',
    );
    if (existing?.windowStartMinutes != null &&
        existing?.windowEndMinutes != null) {
      _timeWindowEnabled = true;
      _windowStart = TimeOfDay(
        hour: existing!.windowStartMinutes! ~/ 60,
        minute: existing.windowStartMinutes! % 60,
      );
      _windowEnd = TimeOfDay(
        hour: existing.windowEndMinutes! ~/ 60,
        minute: existing.windowEndMinutes! % 60,
      );
    }
    _color = existing?.color;
    _icon = existing?.icon ?? CustomMoodIcon.mood;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _excludeDaysController.dispose();
    super.dispose();
  }

  int _timeOfDayToMinutes(TimeOfDay t) => t.hour * 60 + t.minute;

  Future<void> _pickColor() async {
    final picked = await showDialog<Color>(
      context: context,
      builder: (context) => ColorPickerDialog(
        initialColor: _color ?? Theme.of(context).colorScheme.primary,
        title: 'Mood color',
      ),
    );
    if (picked != null) setState(() => _color = picked);
  }

  Future<void> _pickWindowStart() async {
    final picked = await showTimePicker(context: context, initialTime: _windowStart);
    if (picked != null) setState(() => _windowStart = picked);
  }

  Future<void> _pickWindowEnd() async {
    final picked = await showTimePicker(context: context, initialTime: _windowEnd);
    if (picked != null) setState(() => _windowEnd = picked);
  }

  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    final excludeDays = int.tryParse(_excludeDaysController.text.trim()) ?? 7;
    final id = widget.existing?.id ??
        'mood_${DateTime.now().microsecondsSinceEpoch}';
    final mood = CustomMood(
      id: id,
      name: name,
      genres: _selectedGenres.toList(),
      moodTags: _selectedMoodTags.toList(),
      minBpm: _bpmEnabled ? _bpmRange.start : null,
      maxBpm: _bpmEnabled ? _bpmRange.end : null,
      ratingFloor: _ratingFloor > 0 ? _ratingFloor : null,
      excludeRecentlyPlayedDays:
          _excludeRecentlyPlayed ? excludeDays.clamp(1, 365) : null,
      windowStartMinutes:
          _timeWindowEnabled ? _timeOfDayToMinutes(_windowStart) : null,
      windowEndMinutes:
          _timeWindowEnabled ? _timeOfDayToMinutes(_windowEnd) : null,
      color: _color,
      icon: _icon,
    );
    Navigator.of(context).pop(mood);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allGenres = {...widget.knownGenres, ..._selectedGenres}.toList()
      ..sort();
    final allMoodTags =
        {..._defaultMoodTags, ...widget.knownMoodTags, ..._selectedMoodTags}
            .toList()
          ..sort();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'New mood' : 'Edit mood'),
        actions: [
          TextButton(
            onPressed: _nameController.text.trim().isEmpty ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Mood name',
              hintText: 'Late Night Drive',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 24),
          Text('Genres', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          if (allGenres.isEmpty)
            Text(
              'No genres found in your library yet.',
              style: theme.textTheme.bodySmall,
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: allGenres.map((genre) {
                final selected = _selectedGenres.contains(genre);
                return FilterChip(
                  label: Text(genre),
                  selected: selected,
                  onSelected: (value) => setState(() {
                    if (value) {
                      _selectedGenres.add(genre);
                    } else {
                      _selectedGenres.remove(genre);
                    }
                  }),
                );
              }).toList(),
            ),
          const SizedBox(height: 24),
          Text('Mood', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: allMoodTags.map((tag) {
              final selected = _selectedMoodTags.contains(tag);
              return FilterChip(
                label: Text(tag),
                selected: selected,
                onSelected: (value) => setState(() {
                  if (value) {
                    _selectedMoodTags.add(tag);
                  } else {
                    _selectedMoodTags.remove(tag);
                  }
                }),
              );
            }).toList(),
          ),
          const SizedBox(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Tempo range'),
            subtitle: _bpmEnabled
                ? Text(
                    '${_bpmRange.start.round()}–${_bpmRange.end.round()} BPM')
                : const Text('No BPM restriction'),
            value: _bpmEnabled,
            onChanged: (value) => setState(() => _bpmEnabled = value),
          ),
          if (_bpmEnabled)
            RangeSlider(
              min: 40,
              max: 220,
              divisions: 36,
              labels: RangeLabels(
                '${_bpmRange.start.round()}',
                '${_bpmRange.end.round()}',
              ),
              values: _bpmRange,
              onChanged: (value) => setState(() => _bpmRange = value),
            ),
          const SizedBox(height: 16),
          Text('Minimum rating', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 1; i <= 5; i++)
                IconButton(
                  onPressed: () => setState(
                    () => _ratingFloor = _ratingFloor == i ? 0 : i,
                  ),
                  icon: Icon(
                    i <= _ratingFloor ? Icons.star : Icons.star_border,
                    color: i <= _ratingFloor ? theme.colorScheme.primary : null,
                  ),
                ),
              if (_ratingFloor > 0)
                Text('$_ratingFloor+', style: theme.textTheme.bodyMedium),
            ],
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Exclude recently played'),
            subtitle: _excludeRecentlyPlayed
                ? Row(
                    children: [
                      const Text('Played in the last '),
                      SizedBox(
                        width: 48,
                        child: TextField(
                          controller: _excludeDaysController,
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          decoration: const InputDecoration(isDense: true),
                        ),
                      ),
                      const Text(' days'),
                    ],
                  )
                : const Text('No exclusion'),
            value: _excludeRecentlyPlayed,
            onChanged: (value) =>
                setState(() => _excludeRecentlyPlayed = value),
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Suggested time window'),
            subtitle: _timeWindowEnabled
                ? Text(
                    '${_windowStart.format(context)} – ${_windowEnd.format(context)}')
                : const Text('No time restriction'),
            value: _timeWindowEnabled,
            onChanged: (value) => setState(() => _timeWindowEnabled = value),
          ),
          if (_timeWindowEnabled)
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _pickWindowStart,
                    child: Text('Start: ${_windowStart.format(context)}'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _pickWindowEnd,
                    child: Text('End: ${_windowEnd.format(context)}'),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 24),
          Text('Appearance', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: _color ?? theme.colorScheme.surfaceContainerHighest,
                shape: BoxShape.circle,
                border: Border.all(color: theme.dividerColor),
              ),
            ),
            title: const Text('Color'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickColor,
          ),
          const SizedBox(height: 8),
          Text('Icon', style: theme.textTheme.bodyMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: CustomMoodIcon.values.map((value) {
              final selected = value == _icon;
              return Tooltip(
                message: value.label,
                child: InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onTap: () => setState(() => _icon = value),
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected
                          ? theme.colorScheme.primaryContainer
                          : null,
                      border: Border.all(
                        color: selected
                            ? theme.colorScheme.primary
                            : theme.dividerColor,
                      ),
                    ),
                    child: Icon(value.icon),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
