// Экран 3: график ТО одной машины.
import 'package:material_ui/material_ui.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../core/schedule.dart';
import '../core/tires.dart';
import '../data/store.dart';
import 'history_screen.dart';
import 'service_screen.dart';
import 'widgets.dart';

class CarScreen extends StatelessWidget {
  const CarScreen({super.key, required this.store, required this.carId});
  final AppStore store;
  final String carId;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final car = store.carById(carId);
        if (car == null) return const Scaffold(); // машину только что удалили
        final items = store.scheduleFor(car);
        final forecast = store.forecastFor(car);
        final (rate, rateSource) = estimateKmPerDay(car, store.today);
        final cs = Theme.of(context).colorScheme;

        return Scaffold(
          appBar: AppBar(
            title: Text('${car.make} ${car.model}'),
            actions: [
              IconButton(
                tooltip: 'История обслуживания',
                icon: const Icon(Icons.history),
                onPressed: () => Navigator.push(
                    context, MaterialPageRoute(builder: (_) => HistoryScreen(store: store, carId: carId))),
              ),
              IconButton(tooltip: 'Удалить', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(context, car)),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${car.year} г.${car.engineId != null ? ' · ${_engineTitle(car)}' : ''}'),
                    const SizedBox(height: 4),
                    Text('Пробег: ${car.lastKnownKm == null ? '—' : fmtKm(car.lastKnownKm!)}'),
                    Text('В среднем ${rate.round()} км/день (${_rateText(rateSource)})',
                        style: TextStyle(color: cs.onSurfaceVariant)),
                    if (car.tireSetup != null) ...[
                      const SizedBox(height: 4),
                      Text(car.city == null
                          ? 'Шины: по календарю (${climateZones[car.climateZone]!.title})'
                          : forecast == null
                              ? 'Шины: ${car.city}, прогноз погоды ещё не загружен — по календарю'
                              : 'Шины: ${car.city}, прогноз погоды от ${fmtDate(forecast.fetchedOn)}'),
                    ],
                  ]),
                ),
              ),
              const SizedBox(height: 8),
              for (final s in items)
                Card(
                  child: ListTile(
                    leading: Icon(statusIcon(s.status), color: statusColor(s.status, cs)),
                    title: Text(itemTitle(s)),
                    subtitle: Text(itemDetails(s)),
                    trailing: Text(s.status.title, style: TextStyle(color: statusColor(s.status, cs))),
                    onTap: () => _openService(context, car, preselect: s.consumable),
                  ),
                ),
            ],
          ),
          floatingActionButton: Row(mainAxisSize: MainAxisSize.min, children: [
            FloatingActionButton.extended(
              heroTag: 'km',
              onPressed: () => _updateKm(context, car),
              icon: const Icon(Icons.speed),
              label: const Text('Пробег'),
            ),
            const SizedBox(width: 12),
            FloatingActionButton.extended(
              heroTag: 'service',
              onPressed: () => _openService(context, car),
              icon: const Icon(Icons.build),
              label: const Text('Отметить ТО'),
            ),
          ]),
        );
      },
    );
  }

  String _engineTitle(Car car) =>
      store.regulationFor(car).engines.where((e) => e.id == car.engineId).map((e) => e.title).firstOrNull ?? '';

  String _rateText(RateSource s) => switch (s) {
        RateSource.readings => 'по вашим показаниям',
        RateSource.declared => 'с ваших слов',
        RateSource.defaultRate => 'средний по стране — обновляйте пробег, станет точнее',
      };

  void _openService(BuildContext context, Car car, {Consumable? preselect}) => Navigator.push(context,
      MaterialPageRoute(builder: (_) => ServiceScreen(store: store, carId: car.id, preselect: preselect)));

  Future<void> _updateKm(BuildContext context, Car car) async {
    final controller = TextEditingController(text: car.lastKnownKm?.toString() ?? '');
    final km = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Пробег сейчас'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(suffixText: 'км'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, parseIntField(controller)), child: const Text('Сохранить')),
        ],
      ),
    );
    if (km == null) return;
    try {
      await store.addReading(car, km);
    } on ArgumentError catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _delete(BuildContext context, Car car) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Удалить ${car.make} ${car.model}?'),
        content: const Text('История обслуживания этой машины тоже удалится.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok == true) {
      await store.deleteCar(car);
      if (context.mounted) Navigator.pop(context);
    }
  }
}
