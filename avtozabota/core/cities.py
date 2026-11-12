"""Выбор города: откуда брать прогноз погоды и какую климатическую зону ставить по умолчанию.

Два способа:
  * встроенный список крупных городов (data/cities.json) — работает без сети, мгновенно;
  * онлайн-поиск любого населённого пункта через геокодер Open-Meteo (без ключа).

Климатическая зона определяется по координатам, а не по названию региона — так она
работает для любого результата геокодера.
"""
from __future__ import annotations

import json
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from .models import Car

GEOCODING_URL = "https://geocoding-api.open-meteo.com/v1/search"
DEFAULT_PATH = Path(__file__).resolve().parents[2] / "app" / "assets" / "data" / "cities.json"


@dataclass(frozen=True)
class City:
    name: str
    region: str          # для подписи в списке: «Самара, Самарская область»
    lat: float
    lon: float
    population: int | None = None

    @property
    def title(self) -> str:
        return f"{self.name}, {self.region}" if self.region else self.name

    @property
    def climate_zone(self) -> str:
        return zone_for(self.lat, self.lon)


def zone_for(lat: float, lon: float) -> str:
    """Климатическая зона по координатам (id из core.tires.CLIMATE_ZONES).

    south      — южнее 47.5° и западнее 50° в.д.: Крым, Кубань, Ростов, Ставрополь, Кавказ, Астрахань;
    north_east — восточнее 55° в.д. (Урал, Сибирь, Дальний Восток) или севернее 61° (Север);
    center     — всё остальное: Центр, Северо-Запад, Поволжье, Калининград.
    """
    if lat >= 61 or lon >= 55:
        return "north_east"
    if lat < 47.5 and lon < 50:
        return "south"
    return "center"


def in_service_area(lat: float, lon: float) -> bool:
    """Географическая рамка, для которой рассчитаны климатические зоны (Россия с запасом).
    Отсекает тёзок вроде «Сочи» в Мексике или «Казан» в Турции."""
    return 41 <= lat <= 82 and (lon >= 19 or lon <= -168)


def _norm(s: str) -> str:
    return s.casefold().replace("ё", "е").replace("-", " ").strip()


def load_cities(path: Path = DEFAULT_PATH) -> list[City]:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    return [City(c["name"], c["region"], c["lat"], c["lon"], c.get("population")) for c in raw["cities"]]


def search_cities(query: str, cities: list[City], limit: int = 10) -> list[City]:
    """Поиск во встроенном списке: сначала совпадения с начала названия, затем по подстроке;
    внутри — крупные города выше. «орел» находит «Орёл», «ростов на» — «Ростов-на-Дону»."""
    q = _norm(query)
    if not q:
        return []
    starts = [c for c in cities if _norm(c.name).startswith(q)]
    contains = [c for c in cities if q in _norm(c.name) and c not in starts]
    by_pop = lambda c: -(c.population or 0)
    return (sorted(starts, key=by_pop) + sorted(contains, key=by_pop))[:limit]


def parse_geocoding(payload: dict) -> list[City]:
    """Ответ геокодера Open-Meteo → населённые пункты, крупные первыми.

    Мысы, аэропорты, возвышенности и т. п. (feature_code не PPL*) отбрасываются.
    Названия берутся из GeoNames как есть: у части городов они латиницей («Stavropol’»).
    """
    result = [City(r["name"], r.get("admin1") or "", r["latitude"], r["longitude"], r.get("population"))
              for r in payload.get("results", [])
              if r.get("feature_code", "PPL").startswith("PPL") and in_service_area(r["latitude"], r["longitude"])]
    return sorted(result, key=lambda c: -(c.population or 0))


def search_online(query: str, limit: int = 10, timeout: float = 10.0) -> list[City]:
    """Поиск любого населённого пункта. Бросает OSError при сбое сети."""
    query = query.strip()
    if len(query) < 2:
        return []
    params = urllib.parse.urlencode({"name": query, "count": limit, "language": "ru", "format": "json"})
    req = urllib.request.Request(f"{GEOCODING_URL}?{params}", headers={"User-Agent": "AvtoZabota/0.1"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return parse_geocoding(json.load(resp))


def apply_city(car: Car, city: City) -> None:
    """Привязать машину к городу: координаты для прогноза и климатическая зона для календаря."""
    car.city = city.title
    car.location = (round(city.lat, 2), round(city.lon, 2))
    car.climate_zone = city.climate_zone
