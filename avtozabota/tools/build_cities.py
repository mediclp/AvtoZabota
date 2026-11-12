"""Собирает app/assets/data/cities.json: координаты крупных городов через геокодер Open-Meteo.

Запуск из папки проекта:  python tools/build_cities.py
Чтобы добавить город — допишите его в CITIES и запустите снова.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from core.cities import search_online  # noqa: E402

CITIES = [
    # города-миллионники и крупнейшие
    "Москва", "Санкт-Петербург", "Новосибирск", "Екатеринбург", "Казань", "Нижний Новгород",
    "Красноярск", "Челябинск", "Самара", "Уфа", "Ростов-на-Дону", "Краснодар", "Омск", "Воронеж",
    "Пермь", "Волгоград",
    # региональные центры и крупные города
    "Саратов", "Тюмень", "Тольятти", "Махачкала", "Барнаул", "Ижевск", "Хабаровск", "Ульяновск",
    "Иркутск", "Владивосток", "Ярославль", "Севастополь", "Симферополь", "Ставрополь", "Томск",
    "Кемерово", "Набережные Челны", "Оренбург", "Новокузнецк", "Балашиха", "Рязань", "Чебоксары",
    "Калининград", "Пенза", "Липецк", "Киров", "Астрахань", "Тула", "Улан-Удэ", "Сочи", "Курск",
    ("Мурманск", "Murmansk"), "Архангельск", "Якутск", "Петрозаводск", "Сыктывкар", "Владимир", "Белгород",
    "Тверь", "Смоленск", "Брянск", "Иваново", "Вологда", "Кострома", "Калуга", "Орёл", "Тамбов",
    "Сургут", "Магадан", "Петропавловск-Камчатский", "Южно-Сахалинск", "Нальчик", "Владикавказ",
    "Грозный", "Великий Новгород", "Псков", "Новороссийск", "Таганрог", "Чита", "Абакан",
]


def search_with_retry(name: str, attempts: int = 3):
    for i in range(attempts):
        try:
            return search_online(name, timeout=20)
        except OSError as e:
            if i == attempts - 1:
                raise
            print(f"  {name}: {e}, повтор…")
            time.sleep(2 * (i + 1))


MIN_POPULATION = 50_000   # чтобы не взять одноимённое село
# Геокодер (GeoNames) называет регионы непоследовательно — поправляем подписи.
REGION_OVERRIDES = {
    "Севастополь": "",
    "Тюмень": "Тюменская область",
    "Челябинск": "Челябинская область",
    "Ставрополь": "Ставропольский край",
    "Мурманск": "Мурманская область",
}


def region_label(name: str, region: str) -> str:
    if name in REGION_OVERRIDES:
        return REGION_OVERRIDES[name]
    if region == name:   # Москва, Санкт-Петербург
        return ""
    return region.replace(" Область", " область").replace(" Край", " край")


def main() -> None:
    result, missing = [], []
    for entry in CITIES:
        name, query = entry if isinstance(entry, tuple) else (entry, entry)
        # search_online уже отбрасывает места вне рамки in_service_area (тёзки в Мексике и т. п.)
        found = [c for c in search_with_retry(query) if (c.population or 0) >= MIN_POPULATION]
        if not found:
            missing.append(name)
            continue
        c = found[0]   # самый крупный населённый пункт по запросу
        result.append({"name": name, "region": region_label(name, c.region),
                       "lat": round(c.lat, 4), "lon": round(c.lon, 4), "population": c.population})
        time.sleep(0.2)   # вежливо к бесплатному сервису
    out = ROOT.parent / "app" / "assets" / "data" / "cities.json"
    payload = {"_note": "Сгенерировано tools/build_cities.py из геокодера Open-Meteo (GeoNames).",
               "cities": result}
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{len(result)} городов → {out}")
    if missing:
        print("не найдены:", ", ".join(missing))


if __name__ == "__main__":
    main()
