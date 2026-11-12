// Экран 5: история обслуживания машины.
import 'package:material_ui/material_ui.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../data/store.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key, required this.store, required this.carId});
  final AppStore store;
  final String carId;

  @override
  Widget build(BuildContext context) {
    final car = store.carById(carId)!;
    // Новые сверху; записи одного дня — в обратном порядке добавления (sort в Dart не сохраняет порядок равных).
    final indexed = car.services.indexed.toList()
      ..sort((a, b) {
        final byDate = b.$2.on.compareTo(a.$2.on);
        return byDate != 0 ? byDate : b.$1.compareTo(a.$1);
      });
    final records = [for (final (_, r) in indexed) r];
    final total = records.fold<int>(0, (sum, r) => sum + (r.costRub ?? 0));

    return Scaffold(
      appBar: AppBar(title: const Text('История обслуживания')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        if (total > 0)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text('Потрачено на обслуживание: $total ₽', style: Theme.of(context).textTheme.titleMedium),
          ),
        for (final r in records)
          Card(
            child: ListTile(
              title: Text('${fmtDate(r.on)} · ${fmtKm(r.odometerKm)}'),
              subtitle: Text([
                if (r.isBaseline) 'Введено при добавлении машины',
                [
                  for (final c in r.consumables)
                    c == Consumable.tires && r.tiresMounted != null
                        ? 'поставили ${r.tiresMounted!.title.toLowerCase()} шины'
                        : c.title,
                ].join(', '),
                if (r.costRub != null) '${r.costRub} ₽',
                if (r.comment.isNotEmpty) r.comment,
              ].join('\n')),
              isThreeLine: true,
            ),
          ),
      ]),
    );
  }
}
