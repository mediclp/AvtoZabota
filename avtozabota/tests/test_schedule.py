import os
import unittest
from datetime import date, timedelta

from core.models import (Action, Car, Consumable, OdometerReading, Regulation, RegulationItem,
                         ServiceRecord, TireSeason, TireSetup)
from core.cities import apply_city, load_cities, parse_geocoding, search_cities, search_online
from core.tires import CLIMATE_ZONES, tire_item
from core.weather import DailyTemp, covers, fetch_daily_temps, parse_open_meteo, swap_signal
from core.regulations import catalog, find_regulation, load_regulations
from core.schedule import (DEFAULT_KM_PER_DAY, RateSource, Status, Trigger, add_months,
                           build_schedule, estimate_km_per_day, last_service, schedule_item)

OIL = Consumable.ENGINE_OIL
OIL_ITEM = RegulationItem(OIL, Action.REPLACE, interval_km=15000, interval_months=12)
TODAY = date(2026, 11, 12)


def make_car(baseline_on, baseline_km, readings=(), declared=None, consumables=(OIL,)):
    car = Car(id="c1", make="Lada", model="Vesta", year=2020, regulation_id="test",
              km_per_month_declared=declared)
    car.add_service(ServiceRecord(baseline_on, baseline_km, frozenset(consumables), is_baseline=True))
    for on, km in readings:
        car.add_reading(OdometerReading(on, km))
    return car


class AddMonthsTest(unittest.TestCase):
    def test_end_of_month(self):
        self.assertEqual(add_months(date(2026, 1, 31), 1), date(2026, 2, 28))
        self.assertEqual(add_months(date(2024, 1, 31), 1), date(2024, 2, 29))

    def test_across_years(self):
        self.assertEqual(add_months(date(2026, 11, 15), 14), date(2028, 1, 15))


class KmPerDayTest(unittest.TestCase):
    def test_default_when_nothing_known(self):
        car = make_car(date(2026, 11, 1), 1000)
        self.assertEqual(estimate_km_per_day(car, TODAY), (DEFAULT_KM_PER_DAY, RateSource.DEFAULT))

    def test_declared_by_user(self):
        car = make_car(date(2026, 11, 1), 1000, declared=1522)
        rate, src = estimate_km_per_day(car, TODAY)
        self.assertEqual(src, RateSource.DECLARED)
        self.assertAlmostEqual(rate, 50.0, places=1)

    def test_from_readings_beats_declared(self):
        car = make_car(date(2026, 10, 1), 1000, [(date(2026, 10, 31), 1900)], declared=5000)
        self.assertEqual(estimate_km_per_day(car, TODAY), (30.0, RateSource.READINGS))

    def test_short_span_is_ignored(self):
        car = make_car(date(2026, 11, 1), 1000, [(date(2026, 11, 10), 2000)])
        self.assertEqual(estimate_km_per_day(car, TODAY)[1], RateSource.DEFAULT)


class ScheduleItemTest(unittest.TestCase):
    def item(self, car):
        rate, _ = estimate_km_per_day(car, TODAY)
        return schedule_item(car, OIL_ITEM, TODAY, rate)

    def test_time_comes_first_for_low_mileage(self):
        car = make_car(date(2026, 1, 10), 50000, [(date(2026, 11, 1), 55000)])
        s = self.item(car)
        self.assertEqual(s.trigger, Trigger.TIME)
        self.assertEqual(s.due_date, date(2027, 1, 10))
        self.assertEqual(s.due_km, 65000)
        self.assertEqual(s.status, Status.OK)
        self.assertEqual(s.reminders, (date(2027, 1, 3), date(2027, 1, 9)))

    def test_km_comes_first_for_high_mileage(self):
        car = make_car(date(2026, 6, 1), 100000, [(date(2026, 11, 1), 112000)])
        s = self.item(car)
        self.assertEqual(s.trigger, Trigger.KM)
        self.assertEqual(s.due_date, date(2026, 12, 10))   # 3000 км / 78.4 км/день = 39 дней
        self.assertEqual(s.remaining_km, 2137)
        self.assertEqual(s.remaining_days, 28)
        self.assertEqual(s.status, Status.OK)

    def test_overdue_by_km_even_if_date_not_passed(self):
        car = make_car(date(2026, 6, 1), 100000, [(date(2026, 11, 10), 116000)])
        s = self.item(car)
        self.assertEqual(s.status, Status.OVERDUE)
        self.assertLess(s.remaining_km, 0)
        self.assertEqual(s.reminders, ())

    def test_soon_and_past_reminders_dropped(self):
        car = make_car(date(2025, 11, 15), 10000, declared=300)
        s = self.item(car)
        self.assertEqual(s.due_date, date(2026, 11, 15))
        self.assertEqual(s.status, Status.SOON)
        self.assertEqual(s.reminders, (date(2026, 11, 14),))   # «за 7 дней» уже прошло

    def test_new_service_resets_schedule(self):
        car = make_car(date(2026, 6, 1), 100000, [(date(2026, 11, 10), 116000)])
        car.add_service(ServiceRecord(date(2026, 11, 11), 116100, frozenset({OIL}), cost_rub=4500,
                                      receipt_photos=["receipts/2026-11-11.jpg"]))
        s = self.item(car)
        self.assertEqual(s.due_km, 131100)
        self.assertEqual(s.status, Status.OK)

    def test_same_day_same_km_later_record_wins(self):
        car = make_car(TODAY, 50000)
        car.add_service(ServiceRecord(TODAY, 50000, frozenset({OIL}), cost_rub=4500))
        self.assertEqual(last_service(car, OIL, TODAY).cost_rub, 4500)

    def test_parked_car_uses_time_only(self):
        car = make_car(date(2026, 1, 1), 20000, [(date(2026, 11, 1), 20000)])
        s = self.item(car)
        self.assertIsNone(s.due_by_km_estimated)
        self.assertEqual(s.trigger, Trigger.TIME)
        self.assertEqual(s.due_date, date(2027, 1, 1))

    def test_unknown_without_last_service(self):
        car = make_car(date(2026, 1, 1), 20000, consumables=(Consumable.AIR_FILTER,))
        self.assertEqual(self.item(car).status, Status.UNKNOWN)


class BuildScheduleTest(unittest.TestCase):
    def test_overdue_first(self):
        reg = Regulation("test", "Lada", "Vesta", None, None, (
            RegulationItem(Consumable.SPARK_PLUGS, Action.REPLACE, interval_km=30000),
            RegulationItem(OIL, Action.REPLACE, interval_km=15000, interval_months=12),
        ))
        car = make_car(date(2026, 6, 1), 100000, [(date(2026, 11, 10), 116000)],
                       consumables=(OIL, Consumable.SPARK_PLUGS))
        result = build_schedule(car, reg, TODAY)
        self.assertEqual([s.consumable for s in result], [OIL, Consumable.SPARK_PLUGS])
        self.assertEqual(result[0].status, Status.OVERDUE)

    def test_wrong_regulation(self):
        reg = Regulation("other", "Kia", "Rio", None, None, (OIL_ITEM,))
        with self.assertRaises(ValueError):
            build_schedule(make_car(date(2026, 1, 1), 1000), reg, TODAY)


class ValidationTest(unittest.TestCase):
    def test_odometer_cannot_go_back(self):
        car = make_car(date(2026, 6, 1), 100000)
        with self.assertRaises(ValueError):
            car.add_reading(OdometerReading(date(2026, 7, 1), 99000))

    def test_same_day_readings_allowed(self):
        car = make_car(date(2026, 6, 1), 100000)
        car.add_reading(OdometerReading(date(2026, 6, 1), 100050))

    def test_item_needs_interval(self):
        with self.assertRaises(ValueError):
            RegulationItem(OIL, Action.REPLACE)


class RegulationsJsonTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.regs = load_regulations()

    def test_every_regulation_has_oil(self):
        for reg in self.regs.values():
            self.assertIn(OIL, {i.consumable for i in reg.items}, reg.id)

    def test_find_by_model_case_insensitive(self):
        self.assertEqual(find_regulation(self.regs, "KIA", "rio", 2019).id, "kia_rio")
        self.assertEqual(find_regulation(self.regs, "Chery", "Tiggo 7 Pro Max", 2024).id,
                         "chery_tiggo_7_pro_max")

    def test_fallback_to_generic(self):
        self.assertEqual(find_regulation(self.regs, "Moskvich", "3", 2023).id, "generic")
        self.assertEqual(find_regulation(self.regs, "Kia", "Rio", 2008).id, "generic")

    def test_models_have_all_consumables_and_source(self):
        full = {c for c in Consumable if c is not Consumable.TIRES}
        for reg in self.regs.values():
            self.assertEqual({i.consumable for i in reg.items}, full, reg.id)
            self.assertTrue(reg.source, reg.id)

    def test_oil_interval_is_sourced_and_plausible(self):
        for reg in self.regs.values():
            if reg.id == "generic":
                continue
            oil = next(i for i in reg.items if i.consumable is OIL)
            self.assertTrue(oil.sourced, reg.id)
            self.assertIn(oil.interval_km, range(5000, 20001), reg.id)
            self.assertIn(oil.interval_months, range(6, 25), reg.id)

    def test_intervals_plausible(self):
        for reg in self.regs.values():
            variants = [i for it in reg.items for i in (it, *(o for _, o in it.by_engine))]
            for i in variants:
                if i.interval_km is not None:
                    self.assertIn(i.interval_km, range(5000, 150001), f"{reg.id} {i.consumable}")
                if i.interval_months is not None:
                    self.assertIn(i.interval_months, range(6, 121), f"{reg.id} {i.consumable}")

    def test_no_overlapping_years_for_same_model(self):
        regs = [r for r in self.regs.values() if r.id != "generic"]
        for a in regs:
            for b in regs:
                if a.id >= b.id or (a.make, a.model) != (b.make, b.model):
                    continue
                a_from, a_to = a.year_from or 0, a.year_to or 9999
                b_from, b_to = b.year_from or 0, b.year_to or 9999
                self.assertTrue(a_to < b_from or b_to < a_from, f"{a.id} и {b.id} пересекаются")

    def test_catalog_for_picker(self):
        cat = catalog(self.regs)
        self.assertIn("Granta", cat["Lada"])
        self.assertNotIn("*", cat)


class EngineTest(unittest.TestCase):
    PLUGS = Consumable.SPARK_PLUGS

    @classmethod
    def setUpClass(cls):
        cls.regs = load_regulations()
        cls.sportage = cls.regs["kia_sportage"]

    def plugs(self, engine_id):
        return next(i for i in self.sportage.items_for(engine_id) if i.consumable is self.PLUGS)

    def test_unknown_engine_uses_most_frequent_interval(self):
        self.assertEqual(self.plugs(None).interval_km, 40000)

    def test_engine_overrides_only_its_items(self):
        self.assertEqual(self.plugs("2.0_mpi").interval_km, 150000)
        self.assertIsNone(self.plugs("2.0_mpi").interval_months)
        oil = next(i for i in self.sportage.items_for("2.0_mpi") if i.consumable is OIL)
        self.assertEqual(oil.interval_km, 10000)

    def test_wrong_engine_rejected(self):
        with self.assertRaises(ValueError):
            self.sportage.items_for("1.5_tsi")

    def test_schedule_uses_car_engine(self):
        car = Car(id="s", make="Kia", model="Sportage", year=2019, regulation_id="kia_sportage",
                  engine_id="2.0_mpi")
        car.add_service(ServiceRecord(date(2026, 1, 1), 30000, frozenset(Consumable), is_baseline=True))
        plugs = next(s for s in build_schedule(car, self.sportage, TODAY) if s.consumable is self.PLUGS)
        self.assertEqual(plugs.due_km, 180000)
        car.engine_id = None
        plugs = next(s for s in build_schedule(car, self.sportage, TODAY) if s.consumable is self.PLUGS)
        self.assertEqual(plugs.due_km, 70000)

    def test_base_interval_is_most_frequent(self):
        for reg in self.regs.values():
            for item in reg.items:
                for eid, o in item.by_engine:
                    for base, var in ((item.interval_km, o.interval_km),
                                      (item.interval_months, o.interval_months)):
                        if base is not None and var is not None:
                            self.assertLessEqual(base, var, f"{reg.id} {item.consumable} {eid}")

    def test_loader_rejects_unknown_engine(self):
        import json, tempfile, os
        bad = {"regulations": [{
            "id": "generic", "make": "*", "model": "*", "engines": [{"id": "a", "title": "A"}],
            "items": [{"consumable": "engine_oil", "action": "replace", "interval_km": 10000,
                       "by_engine": {"b": {"interval_km": 15000}}}]}]}
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as f:
            json.dump(bad, f)
        try:
            with self.assertRaises(ValueError):
                load_regulations(f.name)
        finally:
            os.unlink(f.name)


class TiresTest(unittest.TestCase):
    T = Consumable.TIRES

    def car(self, mounted_on, season, zone="center", studded=False, setup=TireSetup.SEASONAL):
        car = make_car(date(2025, 1, 1), 1000)
        car.tire_setup, car.climate_zone, car.winter_studded = setup, zone, studded
        km = 1000 + (mounted_on - date(2025, 1, 1)).days * 30
        car.add_service(ServiceRecord(mounted_on, km, frozenset({self.T}), tires_mounted=season))
        return car

    def test_summer_to_winter_ok(self):
        s = tire_item(self.car(date(2026, 4, 20), TireSeason.SUMMER), date(2026, 9, 1))
        self.assertEqual(s.status, Status.OK)
        self.assertEqual(s.tires_to_mount, TireSeason.WINTER)
        self.assertEqual((s.window_start, s.due_date), (date(2026, 10, 15), date(2026, 10, 31)))
        self.assertEqual(s.legal_deadline, date(2026, 12, 1))
        self.assertEqual(s.reminders, (date(2026, 10, 8), date(2026, 10, 15), date(2026, 11, 24)))

    def test_soon_a_week_before_window(self):
        s = tire_item(self.car(date(2026, 4, 20), TireSeason.SUMMER), date(2026, 10, 10))
        self.assertEqual(s.status, Status.SOON)

    def test_overdue_keeps_legal_reminder(self):
        s = tire_item(self.car(date(2026, 4, 20), TireSeason.SUMMER), TODAY)
        self.assertEqual(s.status, Status.OVERDUE)
        self.assertEqual(s.reminders, (date(2026, 11, 24),))

    def test_summer_on_when_car_added_late_autumn(self):
        # при добавлении авто 12 ноября сказали «стоят летние» — менять надо сейчас, а не через год
        s = tire_item(self.car(TODAY, TireSeason.SUMMER), TODAY)
        self.assertEqual(s.status, Status.OVERDUE)
        self.assertEqual(s.due_date, date(2026, 10, 31))

    def test_winter_to_summer_next_spring(self):
        s = tire_item(self.car(date(2026, 10, 20), TireSeason.WINTER), TODAY)
        self.assertEqual(s.status, Status.OK)
        self.assertEqual(s.tires_to_mount, TireSeason.SUMMER)
        self.assertEqual(s.window_start, date(2027, 4, 1))
        self.assertIsNone(s.legal_deadline)   # нешипованные летом не запрещены
        self.assertEqual(s.reminders, (date(2027, 3, 25), date(2027, 4, 1)))

    def test_studded_have_legal_deadline(self):
        s = tire_item(self.car(date(2026, 10, 1), TireSeason.WINTER, zone="north_east", studded=True), TODAY)
        self.assertEqual(s.window_start, date(2027, 4, 25))
        self.assertEqual(s.legal_deadline, date(2027, 6, 1))
        self.assertIn(date(2027, 5, 25), s.reminders)

    def test_summer_tires_in_february_are_illegal(self):
        s = tire_item(self.car(date(2026, 2, 10), TireSeason.SUMMER, zone="south"), date(2026, 2, 20))
        self.assertEqual(s.status, Status.OVERDUE)

    def test_zones_shift_windows(self):
        south = tire_item(self.car(date(2026, 4, 20), TireSeason.SUMMER, zone="south"), date(2026, 9, 1))
        north = tire_item(self.car(date(2026, 4, 20), TireSeason.SUMMER, zone="north_east"), date(2026, 9, 1))
        self.assertEqual(south.window_start, date(2026, 11, 1))
        self.assertEqual(north.window_start, date(2026, 9, 20))
        for zone in CLIMATE_ZONES.values():   # окна не выходят за законные сроки
            self.assertLess(zone.autumn[1], (12, 1))
            self.assertLess(zone.spring[1], (6, 1))

    def test_same_day_swap_later_record_wins(self):
        # при добавлении: «стоят летние», и в тот же день отметили «поставили зимние»
        car = self.car(TODAY, TireSeason.SUMMER)
        km = car.observations()[-1].km
        car.add_service(ServiceRecord(TODAY, km, frozenset({self.T}), tires_mounted=TireSeason.WINTER))
        s = tire_item(car, TODAY)
        self.assertEqual((s.tires_to_mount, s.status), (TireSeason.SUMMER, Status.OK))

    def test_no_reminders_when_not_needed(self):
        self.assertIsNone(tire_item(self.car(TODAY, TireSeason.WINTER, setup=TireSetup.ALL_SEASON), TODAY))
        self.assertIsNone(tire_item(make_car(date(2026, 1, 1), 1000), TODAY))   # не спрашивали

    def test_unknown_which_tires_are_on(self):
        car = make_car(date(2026, 1, 1), 1000)
        car.tire_setup = TireSetup.SEASONAL
        self.assertEqual(tire_item(car, TODAY).status, Status.UNKNOWN)

    def test_bad_input(self):
        with self.assertRaises(ValueError):
            ServiceRecord(TODAY, 1000, frozenset({OIL}), tires_mounted=TireSeason.WINTER)
        with self.assertRaises(ValueError):
            tire_item(self.car(TODAY, TireSeason.WINTER, zone="mars"), TODAY)

    def test_included_in_full_schedule(self):
        reg = Regulation("test", "Lada", "Vesta", None, None, (OIL_ITEM,))
        car = self.car(date(2026, 4, 20), TireSeason.SUMMER)
        result = build_schedule(car, reg, TODAY)
        self.assertEqual({s.consumable for s in result}, {OIL, self.T})
        self.assertTrue(all(s.status is Status.OVERDUE for s in result))
        self.assertEqual(result[0].consumable, OIL)   # среди просроченных — по дате срока


def temps(start, means, mins=None):
    mins = mins or [m - 3 for m in means]
    return [DailyTemp(start + timedelta(days=i), float(m), float(n)) for i, (m, n) in enumerate(zip(means, mins))]


class WeatherSignalTest(unittest.TestCase):
    W, S = TireSeason.WINTER, TireSeason.SUMMER

    def test_parse_skips_missing_days(self):
        payload = {"daily": {"time": ["2026-11-05", "2026-11-06"], "temperature_2m_mean": [1.8, None],
                             "temperature_2m_min": [-0.2, 0.5]}}
        self.assertEqual(parse_open_meteo(payload), [DailyTemp(date(2026, 11, 5), 1.8, -0.2)])

    def test_stable_cold_gives_winter_signal(self):
        t = temps(date(2026, 10, 20), [9, 8, 6, 5, 6, 4, 3])
        self.assertEqual(swap_signal(t, self.W), date(2026, 10, 22))

    def test_short_cold_snap_is_ignored(self):
        t = temps(date(2026, 10, 20), [6, 5, 8, 6, 5, 4, 9])
        self.assertIsNone(swap_signal(t, self.W))

    def test_summer_waits_for_no_night_frost(self):
        means = [8, 9, 10, 9, 8, 9, 10, 11, 12, 10]
        mins = [1, 2, -1, 2, 3, 2, 3, 4, 5, 4]
        self.assertEqual(swap_signal(temps(date(2026, 4, 10), means, mins), self.S), date(2026, 4, 13))

    def test_out_of_season_anomaly_is_ignored(self):
        self.assertIsNone(swap_signal(temps(date(2026, 5, 10), [4] * 7), self.W))
        self.assertIsNone(swap_signal(temps(date(2027, 1, 10), [9] * 7, [1] * 7), self.S))

    def test_gap_in_data_breaks_series(self):
        t = temps(date(2026, 10, 20), [5, 5, 5]) + temps(date(2026, 10, 24), [5, 5, 5])
        self.assertIsNone(swap_signal(t, self.W))

    def test_not_before(self):
        t = temps(date(2026, 10, 20), [5] * 10)
        self.assertEqual(swap_signal(t, self.W, not_before=date(2026, 10, 23)), date(2026, 10, 23))

    def test_bad_coordinates(self):
        with self.assertRaises(ValueError):
            fetch_daily_temps(120, 30)

    @unittest.skipUnless(os.environ.get("AVTOZABOTA_LIVE"), "живой запрос к Open-Meteo: AVTOZABOTA_LIVE=1")
    def test_live_open_meteo(self):
        t = fetch_daily_temps(55.75, 37.62)   # Москва
        self.assertGreaterEqual(len(t), 20)
        self.assertTrue(covers(t, date.today()))


class TiresByWeatherTest(unittest.TestCase):
    def car(self):
        return TiresTest.car(TiresTest(), date(2026, 4, 20), TireSeason.SUMMER)   # летние, центр

    def test_cold_coming_earlier_than_calendar(self):
        today = date(2026, 10, 5)
        forecast = temps(date(2026, 9, 28), [12] * 11 + [5] * 12)   # с 9 октября холодно
        s = tire_item(self.car(), today, forecast)
        self.assertEqual(s.trigger, Trigger.WEATHER)
        self.assertEqual(s.window_start, date(2026, 10, 9))
        self.assertEqual(s.status, Status.SOON)
        self.assertEqual(s.reminders, (date(2026, 10, 6), date(2026, 10, 9), date(2026, 11, 24)))

    def test_warm_autumn_is_not_overdue_until_law(self):
        car = self.car()
        warm = lambda today: temps(today - timedelta(days=7), [10] * 23)
        s = tire_item(car, date(2026, 11, 5), warm(date(2026, 11, 5)))   # по календарю уже просрочено
        self.assertEqual((s.status, s.due_date, s.reminders), (Status.OK, None, (date(2026, 11, 24),)))
        self.assertEqual(tire_item(car, date(2026, 11, 26), warm(date(2026, 11, 26))).status, Status.SOON)
        self.assertEqual(tire_item(car, date(2026, 12, 2), warm(date(2026, 12, 2))).status, Status.OVERDUE)

    def test_stale_forecast_falls_back_to_calendar(self):
        stale = temps(date(2026, 9, 1), [5] * 10)
        s = tire_item(self.car(), date(2026, 10, 5), stale)
        self.assertEqual(s.trigger, Trigger.TIME)
        self.assertEqual(s.window_start, date(2026, 10, 15))


class CitiesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cities = load_cities()
        cls.by_name = {c.name: c for c in cls.cities}

    def test_zone_by_coordinates(self):
        expected = {"Севастополь": "south", "Сочи": "south", "Ростов-на-Дону": "south",
                    "Москва": "center", "Калининград": "center", "Казань": "center",
                    "Екатеринбург": "north_east", "Новосибирск": "north_east",
                    "Мурманск": "north_east", "Петрозаводск": "north_east", "Владивосток": "north_east"}
        for name, zone in expected.items():
            self.assertEqual(self.by_name[name].climate_zone, zone, name)

    def test_bundled_list_is_sane(self):
        self.assertGreaterEqual(len(self.cities), 70)
        self.assertEqual(len(self.by_name), len(self.cities), "повтор названия")
        for c in self.cities:
            self.assertTrue(41 <= c.lat <= 82 and 19 <= c.lon <= 180, c.name)
            self.assertIn(c.climate_zone, CLIMATE_ZONES)
            self.assertFalse(any("a" <= ch.lower() <= "z" for ch in c.region), f"латиница: {c.title}")

    def test_search(self):
        first = lambda q: search_cities(q, self.cities)[0].name
        self.assertEqual(first("орел"), "Орёл")
        self.assertEqual(first("ростов на"), "Ростов-на-Дону")
        self.assertEqual(first("СЕВАСТ"), "Севастополь")
        self.assertEqual(first("нов"), "Новосибирск")   # самый крупный из начинающихся на «нов»
        names = [c.name for c in search_cities("нов", self.cities, limit=20)]
        self.assertIn("Великий Новгород", names)          # по подстроке — после совпадений с начала
        self.assertLess(names.index("Новороссийск"), names.index("Великий Новгород"))
        self.assertEqual(search_cities("  ", self.cities), [])

    def test_parse_geocoding_keeps_only_settlements(self):
        payload = {"results": [
            {"name": "Мурманский", "latitude": -69.6, "longitude": 13.3, "feature_code": "CAPE"},
            {"name": "Ступино", "admin1": "Архангельская Область", "latitude": 63.9, "longitude": 41.7,
             "feature_code": "PPL"},
            {"name": "Ступино", "admin1": "Московская область", "latitude": 54.9, "longitude": 38.1,
             "population": 60999, "feature_code": "PPLA2"},
            {"name": "Казан", "admin1": "Анкара", "latitude": 40.2, "longitude": 32.7,
             "population": 50000, "feature_code": "PPLA2"},   # вне рамки зон — отбрасывается
        ]}
        self.assertEqual([c.region for c in parse_geocoding(payload)],
                         ["Московская область", "Архангельская Область"])

    def test_apply_city_sets_location_and_zone(self):
        car = make_car(date(2026, 1, 1), 1000)
        apply_city(car, self.by_name["Севастополь"])
        self.assertEqual(car.city, "Севастополь")
        self.assertEqual(car.location, (44.61, 33.52))
        self.assertEqual(car.climate_zone, "south")
        car.tire_setup = TireSetup.SEASONAL
        car.add_service(ServiceRecord(date(2026, 4, 1), 2000, frozenset({Consumable.TIRES}),
                                      tires_mounted=TireSeason.SUMMER))
        self.assertEqual(tire_item(car, date(2026, 9, 1)).window_start, date(2026, 11, 1))   # южное окно

    @unittest.skipUnless(os.environ.get("AVTOZABOTA_LIVE"), "живой запрос к геокодеру: AVTOZABOTA_LIVE=1")
    def test_live_online_search(self):
        self.assertEqual(search_online("Ступино")[0].region, "Московская область")


if __name__ == "__main__":
    unittest.main()
