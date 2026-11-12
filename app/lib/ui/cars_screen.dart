// Экран 1: список машин пользователя.
import 'package:material_ui/material_ui.dart';

import '../core/format.dart';
import '../data/store.dart';
import 'add_car_screen.dart';
import 'car_screen.dart';
import 'reminders_screen.dart';
import 'widgets.dart';

class CarsScreen extends StatelessWidget {
  const CarsScreen({super.key, required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final cars = store.cars;
        return Scaffold(
          appBar: AppBar(
            title: const Text('АвтоЗабота'),
            actions: [
              IconButton(
                tooltip: 'Ближайшие напоминания',
                icon: const Icon(Icons.notifications_outlined),
                onPressed: () => Navigator.push(
                    context, MaterialPageRoute(builder: (_) => RemindersScreen(store: store))),
              ),
            ],
          ),
          body: cars.isEmpty
              ? _Empty(onAdd: () => _openAdd(context))
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    for (final car in cars)
                      Builder(builder: (context) {
                        final items = store.scheduleFor(car);
                        final top = items.isEmpty ? null : items.first;
                        return Card(
                          child: ListTile(
                            leading: const Icon(Icons.directions_car, size: 36),
                            title: Text('${car.make} ${car.model}, ${car.year}'),
                            subtitle: Text([
                              if (car.lastKnownKm != null) fmtKm(car.lastKnownKm!),
                              if (top != null) itemTitle(top),
                            ].join(' · ')),
                            trailing: top == null ? null : StatusChip(top.status),
                            onTap: () => Navigator.push(context,
                                MaterialPageRoute(builder: (_) => CarScreen(store: store, carId: car.id))),
                          ),
                        );
                      }),
                  ],
                ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _openAdd(context),
            icon: const Icon(Icons.add),
            label: const Text('Добавить авто'),
          ),
        );
      },
    );
  }

  void _openAdd(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => AddCarScreen(store: store)));
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.directions_car_outlined, size: 72, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          Text('Добавьте машину', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text('Посчитаем, когда менять масло, фильтры и шины, и напомним заранее.',
              textAlign: TextAlign.center),
          const SizedBox(height: 24),
          FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add), label: const Text('Добавить авто')),
        ]),
      ),
    );
  }
}
