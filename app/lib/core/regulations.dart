// Справочник регламентов — перенос avtozabota/core/regulations.py.
// Файл: assets/data/regulations.json (его же читает Python-прототип).
import 'dart:convert';

import 'models.dart';

const genericId = 'generic';

RegulationItem _parseItem(Map<String, dynamic> i, {Map<String, dynamic>? base}) {
  final src = base ?? i;
  return RegulationItem(
    consumable: Consumable.fromId(src['consumable'] as String),
    action: ServiceAction.fromId(src['action'] as String),
    intervalKm: i['interval_km'] as int?,
    intervalMonths: i['interval_months'] as int?,
    sourced: i['sourced'] as bool? ?? false,
    note: i['note'] as String? ?? '',
    byEngine: base != null
        ? const {}
        : {
            for (final e in (i['by_engine'] as Map<String, dynamic>? ?? const {}).entries)
              e.key: _parseItem(e.value as Map<String, dynamic>, base: i),
          },
  );
}

Map<String, Regulation> parseRegulations(String jsonText) {
  final raw = jsonDecode(jsonText) as Map<String, dynamic>;
  final result = <String, Regulation>{};
  for (final r in raw['regulations'] as List) {
    final m = r as Map<String, dynamic>;
    final id = m['id'] as String;
    if (result.containsKey(id)) throw FormatException('Повтор id регламента: $id');
    final items = [for (final i in m['items'] as List) _parseItem(i as Map<String, dynamic>)];
    final consumables = items.map((i) => i.consumable).toList();
    if (consumables.toSet().length != consumables.length) throw FormatException('$id: расходник указан дважды');
    result[id] = Regulation(
      id: id,
      make: m['make'] as String,
      model: m['model'] as String,
      yearFrom: m['year_from'] as int?,
      yearTo: m['year_to'] as int?,
      items: items,
      source: m['source'] as String? ?? '',
      engines: [
        for (final e in m['engines'] as List? ?? const []) Engine(e['id'] as String, e['title'] as String),
      ],
    );
  }
  if (!result.containsKey(genericId)) throw const FormatException("В справочнике нет общего регламента 'generic'");
  return result;
}

/// Марки и модели для выпадающих списков на экране «Добавить авто».
Map<String, List<String>> catalog(Map<String, Regulation> regs) {
  final result = <String, Set<String>>{};
  for (final r in regs.values) {
    if (r.id != genericId) result.putIfAbsent(r.make, () => {}).add(r.model);
  }
  final makes = result.keys.toList()..sort();
  return {for (final m in makes) m: (result[m]!.toList()..sort())};
}

/// Регламент модели, а если модели нет в справочнике — общий.
Regulation findRegulation(Map<String, Regulation> regs, String make, String model, int year) {
  for (final r in regs.values) {
    if (r.id != genericId && r.matches(make, model, year)) return r;
  }
  return regs[genericId]!;
}
