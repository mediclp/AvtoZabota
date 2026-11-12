// Экран 2: добавление машины. Поля — из README, раздел «Что нужно экранам».
import 'package:material_ui/material_ui.dart';

import '../core/cities.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../core/regulations.dart';
import '../core/tires.dart';
import '../data/store.dart';
import 'city_picker_screen.dart';
import 'widgets.dart';

const _otherModel = '— другая —';

class AddCarScreen extends StatefulWidget {
  const AddCarScreen({super.key, required this.store});
  final AppStore store;

  @override
  State<AddCarScreen> createState() => _AddCarScreenState();
}

class _AddCarScreenState extends State<AddCarScreen> {
  final _form = GlobalKey<FormState>();
  final _year = TextEditingController();
  final _currentKm = TextEditingController();
  final _lastKm = TextEditingController();
  final _kmPerMonth = TextEditingController();
  final _customMake = TextEditingController();
  final _customModel = TextEditingController();

  String? _make;
  String? _model;
  String? _engineId; // null — «не знаю»
  late DateTime _lastDate = addDays(widget.store.today, -180);
  City? _city;
  TireSetup? _tireSetup; // null — не указывать
  TireSeason? _tiresNow;
  bool _studded = false;

  AppStore get store => widget.store;
  bool get _isOther => _make == _otherModel || _model == _otherModel;

  /// Регламент для выбранной модели и года (или общий).
  Regulation get _regulation {
    final year = parseIntField(_year) ?? store.today.year;
    if (_isOther || _make == null || _model == null) return store.regulations[genericId]!;
    return findRegulation(store.regulations, _make!, _model!, year);
  }

  @override
  void dispose() {
    for (final c in [_year, _currentKm, _lastKm, _kmPerMonth, _customMake, _customModel]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final catalog = store.modelCatalog;
    final engines = _regulation.engines;
    const gap = SizedBox(height: 16);

    return Scaffold(
      appBar: AppBar(title: const Text('Новая машина')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _section('Машина'),
            DropdownButtonFormField<String>(
              initialValue: _make,
              decoration: const InputDecoration(labelText: 'Марка', border: OutlineInputBorder()),
              items: [
                for (final m in catalog.keys) DropdownMenuItem(value: m, child: Text(m)),
                const DropdownMenuItem(value: _otherModel, child: Text(_otherModel)),
              ],
              onChanged: (v) => setState(() {
                _make = v;
                _model = v == _otherModel ? _otherModel : null;
                _engineId = null;
              }),
              validator: (v) => v == null ? 'Выберите марку' : null,
            ),
            gap,
            if (_make != null && _make != _otherModel) ...[
              DropdownButtonFormField<String>(
                key: ValueKey('model:$_make'), // новая марка → новый список, выбор модели сбрасывается
                initialValue: _model,
                decoration: const InputDecoration(labelText: 'Модель', border: OutlineInputBorder()),
                items: [
                  for (final m in catalog[_make]!) DropdownMenuItem(value: m, child: Text(m)),
                  const DropdownMenuItem(value: _otherModel, child: Text(_otherModel)),
                ],
                onChanged: (v) => setState(() {
                  _model = v;
                  _engineId = null;
                }),
                validator: (v) => v == null ? 'Выберите модель' : null,
              ),
              gap,
            ],
            if (_isOther) ...[
              if (_make == _otherModel) ...[
                TextFormField(
                  controller: _customMake,
                  decoration: const InputDecoration(labelText: 'Марка', border: OutlineInputBorder()),
                  validator: (v) => (v ?? '').trim().isEmpty ? 'Заполните поле' : null,
                ),
                gap,
              ],
              TextFormField(
                controller: _customModel,
                decoration: const InputDecoration(labelText: 'Модель', border: OutlineInputBorder()),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Заполните поле' : null,
              ),
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Этой модели нет в справочнике — возьмём общие осторожные интервалы.'),
              ),
              gap,
            ],
            IntField(
              controller: _year,
              label: 'Год выпуска',
              validator: (v) => v == null || v < 1950 || v > store.today.year + 1 ? 'Проверьте год' : null,
            ),
            gap,
            if (engines.isNotEmpty) ...[
              DropdownButtonFormField<String?>(
                key: ValueKey('engine:${_regulation.id}'),
                initialValue: _engineId,
                decoration: const InputDecoration(
                    labelText: 'Двигатель', helperText: 'Влияет на интервал замены свечей', border: OutlineInputBorder()),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Не знаю')),
                  for (final e in engines) DropdownMenuItem(value: e.id, child: Text(e.title)),
                ],
                onChanged: (v) => setState(() => _engineId = v),
              ),
              gap,
            ],
            _section('Пробег и последнее ТО'),
            IntField(controller: _currentKm, label: 'Пробег сейчас', suffix: 'км'),
            gap,
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event),
              title: const Text('Дата последнего ТО'),
              subtitle: Text(fmtDate(_lastDate)),
              onTap: _pickLastDate,
            ),
            IntField(
              controller: _lastKm,
              label: 'Пробег на последнем ТО',
              suffix: 'км',
              validator: (v) {
                final now = parseIntField(_currentKm);
                return v != null && now != null && v > now ? 'Не больше текущего пробега' : null;
              },
            ),
            gap,
            IntField(controller: _kmPerMonth, label: 'Пробег за месяц, примерно', suffix: 'км', required: false),
            _section('Город и шины'),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.location_city),
              title: Text(_city?.title ?? 'Город'),
              subtitle: Text(_city == null
                  ? 'Нужен для прогноза погоды и сроков смены шин'
                  : 'Климатическая зона: ${climateZones[_city!.climateZone]!.title}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _pickCity,
            ),
            gap,
            const Text('Шины'),
            const SizedBox(height: 8),
            SegmentedButton<TireSetup?>(
              showSelectedIcon: false, // на узком экране галочка съедает место под подпись
              segments: const [
                ButtonSegment(value: TireSetup.seasonal, label: Text('Лето + зима')),
                ButtonSegment(value: TireSetup.allSeason, label: Text('Всесезонные')),
                ButtonSegment(value: null, label: Text('Не знаю')),
              ],
              selected: {_tireSetup},
              onSelectionChanged: (s) => setState(() => _tireSetup = s.first),
            ),
            if (_tireSetup == TireSetup.seasonal) ...[
              gap,
              const Text('Какие стоят сейчас'),
              const SizedBox(height: 8),
              SegmentedButton<TireSeason?>(
                showSelectedIcon: false,
                segments: [
                  for (final t in TireSeason.values) ButtonSegment(value: t, label: Text(t.title)),
                  const ButtonSegment(value: null, label: Text('Не помню')),
                ],
                selected: {_tiresNow},
                onSelectionChanged: (s) => setState(() => _tiresNow = s.first),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Зимние шины с шипами'),
                subtitle: const Text('Летом их нельзя использовать по закону'),
                value: _studded,
                onChanged: (v) => setState(() => _studded = v),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(onPressed: _save, child: const Text('Сохранить')),
          ],
        ),
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 12),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );

  Future<void> _pickLastDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _lastDate,
      firstDate: day(1990, 1, 1),
      lastDate: store.today,
    );
    if (picked != null) setState(() => _lastDate = dateOnly(picked));
  }

  Future<void> _pickCity() async {
    final city = await Navigator.push<City>(
        context, MaterialPageRoute(builder: (_) => CityPickerScreen(cities: store.cities)));
    if (city != null) setState(() => _city = city);
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final today = store.today;
    final reg = _regulation;
    final currentKm = parseIntField(_currentKm)!;
    final car = Car(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      make: _make == _otherModel ? _customMake.text.trim() : _make!,
      model: _isOther ? _customModel.text.trim() : _model!,
      year: parseIntField(_year)!,
      regulationId: reg.id,
      engineId: _engineId,
      kmPerMonthDeclared: parseIntField(_kmPerMonth),
      tireSetup: _tireSetup,
      winterStudded: _tireSetup == TireSetup.seasonal && _studded,
    );
    if (_city != null) applyCity(car, _city!);
    try {
      // «Последнее ТО» — обычная запись с пометкой isBaseline: считаем, что тогда меняли всё по регламенту.
      car.addService(ServiceRecord(
        on: _lastDate,
        odometerKm: parseIntField(_lastKm)!,
        consumables: {for (final i in reg.items) i.consumable},
        isBaseline: true,
      ));
      car.addReading(OdometerReading(today, currentKm));
      if (_tireSetup == TireSetup.seasonal && _tiresNow != null) {
        car.addService(ServiceRecord(
          on: today,
          odometerKm: currentKm,
          consumables: {Consumable.tires},
          isBaseline: true,
          tiresMounted: _tiresNow,
        ));
      }
      await store.addCar(car);
      if (mounted) Navigator.pop(context);
    } on ArgumentError catch (e) {
      if (mounted) showError(context, e);
    }
  }
}
