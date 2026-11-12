// Точка входа: загружаем справочники и сохранённые машины, затем показываем список машин.
// С Flutter 3.47 Material и Cupertino — отдельные пакеты (material_ui, cupertino_ui);
// оттуда же их локализации. Из flutter_localizations нужна только общая для виджетов.
import 'package:cupertino_ui/cupertino_ui.dart' show GlobalCupertinoLocalizations;
import 'package:flutter_localizations/flutter_localizations.dart' show GlobalWidgetsLocalizations;
import 'package:material_ui/material_ui.dart';

import 'data/store.dart';
import 'ui/cars_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await AppStore.load();
  runApp(AvtoZabotaApp(store: store));
  store.start(); // в фоне: перепланировать уведомления и обновить прогноз погоды
}

class AvtoZabotaApp extends StatelessWidget {
  const AvtoZabotaApp({super.key, required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'АвтоЗабота',
      debugShowCheckedModeBanner: false,
      // Временная тема на стандартных компонентах — заменится макетами дизайнера.
      theme: ThemeData(colorSchemeSeed: const Color(0xFF1565C0), useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF1565C0), brightness: Brightness.dark, useMaterial3: true),
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: CarsScreen(store: store),
    );
  }
}
