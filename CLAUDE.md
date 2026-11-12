# АвтоЗабота — заметки для Claude Code

Мобильное приложение-напоминалка о плановом ТО (учебный проект СевГУ). Интерфейс и все тексты — на русском.

## Структура
- `app/` — Flutter-приложение (основная версия). Flutter 3.50, Dart 3.14.
  - `lib/core/` — чистая логика без Flutter: модели, расчёт графика ТО, шины, погода, города, форматирование, план уведомлений. Покрыта `test/core_test.dart`.
  - `lib/data/` — `AppStore` (ChangeNotifier: машины в SharedPreferences, кэш прогноза, настройки уведомлений), `api.dart` (Open-Meteo), `notifications.dart` (flutter_local_notifications).
  - `lib/ui/` — экраны на стандартных Material-компонентах (временный вид, ждёт макетов дизайнера). Состояние — `ListenableBuilder(listenable: store)`.
  - `assets/data/` — `regulations.json` (регламенты ТО), `cities.json` (города). Общие с Python-прототипом.
- `avtozabota/` — Python-прототип той же логики (`core/`, `tests/`). Правила расчёта описаны в его README.
- `ДЛЯ_ДИЗАЙНЕРА.md` — инструкция для дизайнера: какие данные на каких экранах.

## Команды
```bash
cd app && flutter analyze && flutter test        # проверка приложения
cd app && flutter run -d chrome                   # запуск в браузере
cd avtozabota && python -m unittest discover -s tests -t .   # тесты прототипа
```

## Правила
- Material подключается через `import 'package:material_ui/material_ui.dart';` (Flutter 3.47+), Cupertino — через `package:cupertino_ui`. Старый `package:flutter/material.dart` устарел.
- Логика — только в `lib/core/`, без зависимостей от Flutter, с тестами. Экраны не считают сроки сами, а берут готовые `ScheduleItem` из `AppStore.scheduleFor(car)`.
- Логика продублирована в Python-прототипе: если меняется правило расчёта, поменяй его в обеих версиях и прогони оба набора тестов (цифры в тестах совпадают).
- Даты — «только дата» в UTC (`day()`, `dateOnly()` из `core/models.dart`), чтобы разница в днях не ломалась на переходе на летнее время.
- Дизайн-правки — в `lib/ui/` и теме в `lib/main.dart`; `core/`, `data/`, `assets/data/` дизайн не трогает.
- Если меняются тексты на экранах, поправь `test/app_test.dart`, он ищет надписи.
- Сеть у разработчиков может требовать VPN/прокси для github.com и pub.dev. Кэш пакетов удобно держать вне диска C: (`PUB_CACHE`).
