"""Модель данных АвтоЗаботы.

Сущности:
  Regulation / RegulationItem  - регламент ТО для марки/модели (справочник, только чтение)
  Car                          - автомобиль пользователя
  OdometerReading              - показание пробега на дату
  ServiceRecord                - запись об обслуживании (в т.ч. «последнее ТО» при добавлении авто)
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date
from enum import Enum


class Consumable(str, Enum):
    ENGINE_OIL = "engine_oil"        # масло + масляный фильтр
    AIR_FILTER = "air_filter"
    CABIN_FILTER = "cabin_filter"
    BRAKE_PADS = "brake_pads"
    BRAKE_FLUID = "brake_fluid"
    SPARK_PLUGS = "spark_plugs"
    TIRES = "tires"

    @property
    def title(self) -> str:
        return CONSUMABLE_TITLES[self]


CONSUMABLE_TITLES = {
    Consumable.ENGINE_OIL: "Моторное масло и масляный фильтр",
    Consumable.AIR_FILTER: "Воздушный фильтр",
    Consumable.CABIN_FILTER: "Салонный фильтр",
    Consumable.BRAKE_PADS: "Тормозные колодки",
    Consumable.BRAKE_FLUID: "Тормозная жидкость",
    Consumable.SPARK_PLUGS: "Свечи зажигания",
    Consumable.TIRES: "Шины",
}


class Action(str, Enum):
    REPLACE = "replace"   # заменить
    INSPECT = "inspect"   # проверить (колодки меняют по износу, а не по пробегу)
    SEASONAL_SWAP = "seasonal_swap"   # сезонная смена шин


class TireSetup(str, Enum):
    SEASONAL = "seasonal"        # два комплекта: летний и зимний
    ALL_SEASON = "all_season"    # всесезонные, менять не нужно


class TireSeason(str, Enum):
    SUMMER = "summer"
    WINTER = "winter"


@dataclass(frozen=True)
class RegulationItem:
    consumable: Consumable
    action: Action
    interval_km: int | None = None
    interval_months: int | None = None
    sourced: bool = False   # интервал взят из источника регламента, а не подставлен по умолчанию
    note: str = ""
    # Отличия для конкретных двигателей: (id двигателя, пункт с другими интервалами).
    # Сам пункт — вариант «двигатель не указан», поэтому в нём должен быть самый частый интервал.
    by_engine: tuple[tuple[str, "RegulationItem"], ...] = ()

    def __post_init__(self) -> None:
        if self.interval_km is None and self.interval_months is None:
            raise ValueError(f"{self.consumable.value}: нужен интервал в км или в месяцах")
        for v in (self.interval_km, self.interval_months):
            if v is not None and v <= 0:
                raise ValueError(f"{self.consumable.value}: интервал должен быть > 0")
        for _, override in self.by_engine:
            if (override.consumable, override.action) != (self.consumable, self.action):
                raise ValueError(f"{self.consumable.value}: вариант для двигателя — другой расходник")

    def for_engine(self, engine_id: str | None) -> "RegulationItem":
        for eid, override in self.by_engine:
            if eid == engine_id:
                return override
        return self


@dataclass(frozen=True)
class Engine:
    id: str       # "2.0_mpi"
    title: str    # "2.0 MPI (атмосферный)" — то, что видит пользователь


@dataclass(frozen=True)
class Regulation:
    id: str
    make: str                       # "*" — общий регламент по умолчанию
    model: str
    year_from: int | None
    year_to: int | None
    items: tuple[RegulationItem, ...]
    source: str = ""
    engines: tuple[Engine, ...] = ()   # пусто — двигатель на интервалы не влияет, не спрашиваем

    def __post_init__(self) -> None:
        engine_ids = [e.id for e in self.engines]
        if len(engine_ids) != len(set(engine_ids)):
            raise ValueError(f"{self.id}: двигатель указан дважды")
        for item in self.items:
            for eid, _ in item.by_engine:
                if eid not in engine_ids:
                    raise ValueError(f"{self.id}: неизвестный двигатель '{eid}' у {item.consumable.value}")

    @property
    def fully_sourced(self) -> bool:
        return all(i.sourced for i in self.items)

    def items_for(self, engine_id: str | None) -> tuple[RegulationItem, ...]:
        """Пункты регламента с учётом двигателя; None — «не знаю», берутся интервалы по умолчанию."""
        if engine_id is not None and engine_id not in {e.id for e in self.engines}:
            raise ValueError(f"У {self.make} {self.model} нет двигателя '{engine_id}'")
        return tuple(item.for_engine(engine_id) for item in self.items)

    def matches(self, make: str, model: str, year: int) -> bool:
        if self.make.casefold() != make.casefold() or self.model.casefold() != model.casefold():
            return False
        if self.year_from is not None and year < self.year_from:
            return False
        if self.year_to is not None and year > self.year_to:
            return False
        return True


@dataclass(frozen=True)
class OdometerReading:
    on: date
    km: int


@dataclass
class ServiceRecord:
    on: date
    odometer_km: int
    consumables: frozenset[Consumable]
    is_baseline: bool = False       # «последнее ТО», введённое при добавлении авто
    cost_rub: int | None = None
    comment: str = ""
    receipt_photos: list[str] = field(default_factory=list)   # пути/URL фото чеков
    tires_mounted: TireSeason | None = None   # какой комплект поставили при смене шин

    def __post_init__(self) -> None:
        if self.tires_mounted is not None and Consumable.TIRES not in self.consumables:
            raise ValueError("Смена шин должна быть отмечена расходником «Шины»")


@dataclass
class Car:
    id: str
    make: str
    model: str
    year: int
    regulation_id: str
    engine_id: str | None = None               # None — пользователь не знает или модель без вариантов
    vin: str | None = None
    km_per_month_declared: int | None = None   # «сколько км в месяц вы проезжаете?»
    tire_setup: TireSetup | None = None        # None — не спрашивали, о шинах не напоминаем
    winter_studded: bool = False               # зимние шины с шипами: их нельзя ездить летом
    climate_zone: str = "center"               # id из core.tires.CLIMATE_ZONES
    location: tuple[float, float] | None = None  # (широта, долгота) для прогноза погоды; None — по календарю
    city: str | None = None                      # подпись выбранного города, задаёт core.cities.apply_city
    readings: list[OdometerReading] = field(default_factory=list)
    services: list[ServiceRecord] = field(default_factory=list)

    def add_reading(self, reading: OdometerReading) -> None:
        self._check_monotonic(reading.on, reading.km)
        self.readings.append(reading)

    def add_service(self, record: ServiceRecord) -> None:
        self._check_monotonic(record.on, record.odometer_km)
        self.services.append(record)

    def observations(self) -> list[OdometerReading]:
        """Все известные точки «дата — пробег», включая пробег из записей ТО."""
        points = list(self.readings)
        points += [OdometerReading(s.on, s.odometer_km) for s in self.services]
        return sorted(points, key=lambda p: (p.on, p.km))

    def _check_monotonic(self, on: date, km: int) -> None:
        if km < 0:
            raise ValueError("Пробег не может быть отрицательным")
        for p in self.observations():
            if p.on < on and p.km > km:
                raise ValueError(f"Пробег {km} км на {on} меньше, чем {p.km} км на {p.on}")
            if p.on > on and p.km < km:
                raise ValueError(f"Пробег {km} км на {on} больше, чем {p.km} км на более позднюю дату {p.on}")


# ---------- Результат расчёта графика ----------

class Status(str, Enum):
    OVERDUE = "overdue"
    SOON = "soon"
    OK = "ok"
    UNKNOWN = "unknown"      # нет данных о последней замене — спросить пользователя


class Trigger(str, Enum):
    KM = "km"
    TIME = "time"
    WEATHER = "weather"   # шины: срок по прогнозу погоды


@dataclass(frozen=True)
class ScheduleItem:
    consumable: Consumable
    action: Action
    status: Status
    last_service: ServiceRecord | None = None
    due_km: int | None = None
    due_date: date | None = None          # итоговая дата (раньшая из двух)
    due_by_time: date | None = None
    due_by_km_estimated: date | None = None
    trigger: Trigger | None = None
    remaining_km: int | None = None
    remaining_days: int | None = None
    reminders: tuple[date, ...] = field(default_factory=tuple)
    # только для сезонной смены шин:
    tires_to_mount: TireSeason | None = None
    window_start: date | None = None      # с какого дня советуем менять
    legal_deadline: date | None = None    # с какого дня езда на старом комплекте нарушает закон
