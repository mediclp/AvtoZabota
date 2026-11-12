// Экран 4: «Отметить ТО» — что поменяли, когда, на каком пробеге, сколько стоило.
import 'package:material_ui/material_ui.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../core/tires.dart';
import '../data/store.dart';
import 'widgets.dart';

class ServiceScreen extends StatefulWidget {
  const ServiceScreen({super.key, required this.store, required this.carId, this.preselect});
  final AppStore store;
  final String carId;
  final Consumable? preselect; // открыли с пункта графика — он уже отмечен

  @override
  State<ServiceScreen> createState() => _ServiceScreenState();
}

class _ServiceScreenState extends State<ServiceScreen> {
  final _form = GlobalKey<FormState>();
  late final Car car = widget.store.carById(widget.carId)!;
  late DateTime _date = widget.store.today;
  late final _km = TextEditingController(text: car.lastKnownKm?.toString() ?? '');
  final _cost = TextEditingController();
  final _comment = TextEditingController();
  late final Set<Consumable> _done = {if (widget.preselect != null) widget.preselect!};
  TireSeason? _tiresMounted;

  @override
  void initState() {
    super.initState();
    if (_done.contains(Consumable.tires)) _tiresMounted = _suggestedTires();
  }

  @override
  void dispose() {
    for (final c in [_km, _cost, _comment]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Какие шины, скорее всего, ставят: противоположные текущим.
  TireSeason _suggestedTires() {
    final last = lastTireSwap(car, widget.store.today)?.tiresMounted;
    return last == TireSeason.winter ? TireSeason.summer : TireSeason.winter;
  }

  @override
  Widget build(BuildContext context) {
    final consumables = [
      for (final i in widget.store.regulationFor(car).items) i.consumable,
      if (car.tireSetup != null) Consumable.tires,
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Отметить ТО')),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event),
            title: const Text('Дата'),
            subtitle: Text(fmtDate(_date)),
            onTap: _pickDate,
          ),
          IntField(controller: _km, label: 'Пробег', suffix: 'км'),
          const SizedBox(height: 16),
          Text('Что сделали', style: Theme.of(context).textTheme.titleMedium),
          for (final c in consumables)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(c == Consumable.tires ? 'Сменили шины' : c.title),
              value: _done.contains(c),
              onChanged: (v) => setState(() {
                v == true ? _done.add(c) : _done.remove(c);
                if (c == Consumable.tires) _tiresMounted = v == true ? _suggestedTires() : null;
              }),
            ),
          if (_done.contains(Consumable.tires) && car.tireSetup == TireSetup.seasonal) ...[
            const SizedBox(height: 8),
            const Text('Какие поставили'),
            const SizedBox(height: 8),
            SegmentedButton<TireSeason>(
              segments: [for (final t in TireSeason.values) ButtonSegment(value: t, label: Text(t.title))],
              selected: {_tiresMounted ?? _suggestedTires()},
              onSelectionChanged: (s) => setState(() => _tiresMounted = s.first),
            ),
          ],
          const SizedBox(height: 16),
          IntField(controller: _cost, label: 'Стоимость', suffix: '₽', required: false),
          const SizedBox(height: 16),
          TextFormField(
            controller: _comment,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Комментарий (СТО, артикулы…)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          // TODO: фото чека — пакет image_picker (камера/галерея), путь сохранить в receiptPhotos.
          const ListTile(
            contentPadding: EdgeInsets.zero,
            enabled: false,
            leading: Icon(Icons.photo_camera_outlined),
            title: Text('Фото чека'),
            subtitle: Text('Появится в следующей версии'),
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: _save, child: const Text('Сохранить')),
        ]),
      ),
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
        context: context, initialDate: _date, firstDate: day(1990, 1, 1), lastDate: widget.store.today);
    if (picked != null) setState(() => _date = dateOnly(picked));
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_done.isEmpty) {
      showError(context, 'Отметьте, что сделали');
      return;
    }
    try {
      await widget.store.addService(
        car,
        ServiceRecord(
          on: _date,
          odometerKm: parseIntField(_km)!,
          consumables: Set.of(_done),
          costRub: parseIntField(_cost),
          comment: _comment.text.trim(),
          tiresMounted: _done.contains(Consumable.tires) && car.tireSetup == TireSetup.seasonal
              ? (_tiresMounted ?? _suggestedTires())
              : null,
        ),
      );
      if (mounted) Navigator.pop(context);
    } on ArgumentError catch (e) {
      if (mounted) showError(context, e);
    }
  }
}
