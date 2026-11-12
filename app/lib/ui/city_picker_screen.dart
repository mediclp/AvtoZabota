// Экран выбора города: встроенный список (без сети) + онлайн-поиск любого населённого пункта.
import 'package:material_ui/material_ui.dart';

import '../core/cities.dart';
import '../core/tires.dart';
import '../data/api.dart' as api;
import 'widgets.dart';

class CityPickerScreen extends StatefulWidget {
  const CityPickerScreen({super.key, required this.cities});
  final List<City> cities;

  @override
  State<CityPickerScreen> createState() => _CityPickerScreenState();
}

class _CityPickerScreenState extends State<CityPickerScreen> {
  final _query = TextEditingController();
  List<City>? _online; // null — онлайн-поиск не запускали
  bool _loading = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.text;
    final local = q.trim().isEmpty
        ? (List.of(widget.cities)..sort((a, b) => (b.population ?? 0).compareTo(a.population ?? 0))).take(15).toList()
        : searchCities(q, widget.cities, limit: 20);
    final results = _online ?? local;

    return Scaffold(
      appBar: AppBar(title: const Text('Город')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _query,
            autofocus: true,
            decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search), hintText: 'Начните вводить название', border: OutlineInputBorder()),
            onChanged: (_) => setState(() => _online = null),
          ),
        ),
        if (_online != null)
          ListTile(
            dense: true,
            title: Text('Результаты онлайн-поиска (${_online!.length})'),
            trailing: TextButton(onPressed: () => setState(() => _online = null), child: const Text('Назад к списку')),
          ),
        Expanded(
          child: ListView(children: [
            for (final c in results)
              ListTile(
                title: Text(c.name),
                subtitle: Text([
                  if (c.region.isNotEmpty) c.region,
                  climateZones[c.climateZone]!.title,
                ].join(' · ')),
                onTap: () => Navigator.pop(context, c),
              ),
            if (results.isEmpty) const ListTile(title: Text('Ничего не найдено')),
            if (_online == null && q.trim().length >= 2)
              Padding(
                padding: const EdgeInsets.all(12),
                child: OutlinedButton.icon(
                  onPressed: _loading ? null : _searchOnline,
                  icon: _loading
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.travel_explore),
                  label: const Text('Искать другой населённый пункт онлайн'),
                ),
              ),
          ]),
        ),
      ]),
    );
  }

  Future<void> _searchOnline() async {
    setState(() => _loading = true);
    try {
      final found = await api.searchOnline(_query.text);
      if (mounted) setState(() => _online = found);
    } catch (e) {
      if (mounted) showError(context, 'Не удалось выполнить поиск: проверьте интернет');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}
