#!/usr/bin/env python3
"""Builds Nomorediet's large food database (SQLite) from open sources.

Sources (both free to reuse):
- Open Food Facts: every product sold in Italy with nutrition facts (ODbL; attribution in the app).
- USDA FoodData Central: Foundation, SR Legacy and FNDDS survey foods, i.e. generic foods and mixed dishes
  (public domain). Names are in English; the app searches them with the English names the AI provides.

Output table `foods`: one row per food with values per 100 g and a normalised search column.
Run weekly by .github/workflows/food-db.yml.
"""
import csv, gzip, io, json, os, re, sqlite3, sys, unicodedata, urllib.request, zipfile, datetime

OUT = sys.argv[1] if len(sys.argv) > 1 else "foods.sqlite"
UA = {"User-Agent": "Nomorediet-food-db/1.0 (personal app; weekly build)"}
OFF_CSV = "https://static.openfoodfacts.org/data/en.openfoodfacts.org.products.csv.gz"
FDC_PAGE = "https://fdc.nal.usda.gov/download-datasets"
csv.field_size_limit(1 << 30)

# FoodData Central nutrient ids
N = {"kcal": ("1008", "2047", "2048"), "protein": ("1003",), "fat": ("1004",), "carbs": ("1005",),
     "fiber": ("1079",), "calcium": ("1087",), "iron": ("1089",), "zinc": ("1095",), "b12": ("1178",)}


def norm(s):
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9%]+", " ", s).strip()


def num(v):
    try:
        x = float(str(v).replace(",", "."))
        return x if x == x and abs(x) < 1e6 else None
    except (TypeError, ValueError):
        return None


def plausible(kcal, p, c, f):
    return kcal is not None and 0 <= kcal <= 950 and all(x is None or 0 <= x <= 100 for x in (p, c, f)) \
        and (p or 0) + (c or 0) + (f or 0) <= 105


def setup(db):
    db.executescript("""
        DROP TABLE IF EXISTS foods; DROP TABLE IF EXISTS meta;
        CREATE TABLE foods (norm TEXT NOT NULL, name TEXT NOT NULL, brand TEXT, code TEXT, src TEXT NOT NULL,
            kcal REAL, protein REAL, carbs REAL, fat REAL, fiber REAL, iron REAL, calcium REAL, b12 REAL, zinc REAL,
            portion REAL, portion_name TEXT);
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
    """)


def open_food_facts(db):
    print("Open Food Facts: downloading", flush=True)
    rows, seen = 0, set()
    with urllib.request.urlopen(urllib.request.Request(OFF_CSV, headers=UA), timeout=600) as resp:
        text = io.TextIOWrapper(gzip.GzipFile(fileobj=resp), encoding="utf-8", errors="replace", newline="")
        reader = csv.DictReader(text, delimiter="\t", quoting=csv.QUOTE_NONE)
        batch = []
        for r in reader:
            if "en:italy" not in (r.get("countries_tags") or ""):
                continue
            name = (r.get("product_name") or "").strip()
            kcal = num(r.get("energy-kcal_100g"))
            if kcal is None and num(r.get("energy_100g")) is not None:
                kcal = num(r.get("energy_100g")) / 4.184
            p, c, f = num(r.get("proteins_100g")), num(r.get("carbohydrates_100g")), num(r.get("fat_100g"))
            if not name or not plausible(kcal, p, c, f):
                continue
            brand = (r.get("brands") or "").split(",")[0].strip()
            key = (norm(name), norm(brand))
            if key in seen:
                continue
            seen.add(key)
            g = lambda k, scale=1.0: (num(r.get(k)) or 0) * scale
            serving = num(r.get("serving_quantity"))
            batch.append((norm(f"{name} {brand}"), name[:120], brand[:60], r.get("code"), "OFF",
                          round(kcal, 1), p or 0, c or 0, f or 0, g("fiber_100g"), g("iron_100g", 1000),
                          g("calcium_100g", 1000), g("vitamin-b12_100g", 1e6), g("zinc_100g", 1000),
                          serving if serving and 0 < serving < 2000 else 100, "1 porzione" if serving else "100 g"))
            if len(batch) >= 5000:
                db.executemany("INSERT INTO foods VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", batch)
                rows += len(batch); batch = []
                print(f"  {rows} prodotti", flush=True)
        db.executemany("INSERT INTO foods VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", batch)
        rows += len(batch)
    print(f"Open Food Facts: {rows} prodotti venduti in Italia", flush=True)
    return rows


def fdc_links():
    try:
        html = urllib.request.urlopen(urllib.request.Request(FDC_PAGE, headers=UA), timeout=120).read().decode("utf-8", "replace")
    except Exception as e:
        print("Pagina USDA non raggiungibile:", e, flush=True)
        html = ""
    links = set(re.findall(r'href="([^"]+?_csv_[^"]+?\.zip)"', html))
    def pick(kind):
        found = sorted(l for l in links if kind in l)
        return None if not found else (found[-1] if found[-1].startswith("http") else "https://fdc.nal.usda.gov" + found[-1])
    found = [u for u in (pick("foundation_food"), pick("sr_legacy_food"), pick("survey_food")) if u]
    # SR Legacy is frozen since 2018, so its address is stable even if the page layout changes
    return found or ["https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_sr_legacy_food_csv_2018-04.zip"]


def usda(db):
    total = 0
    for url in fdc_links():
        print("USDA:", url, flush=True)
        data = urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=600).read()
        z = zipfile.ZipFile(io.BytesIO(data))
        def table(name):
            path = next((n for n in z.namelist() if n.endswith("/" + name) or n == name), None)
            return csv.DictReader(io.TextIOWrapper(z.open(path), encoding="utf-8", errors="replace")) if path else []
        foods = {r["fdc_id"]: r["description"] for r in table("food.csv")}
        values = {}
        wanted = {nid: key for key, ids in N.items() for nid in ids}
        for r in table("food_nutrient.csv"):
            key = wanted.get(r.get("nutrient_id"))
            if key and r["fdc_id"] in foods:
                values.setdefault(r["fdc_id"], {}).setdefault(key, num(r.get("amount")))
        portions = {}
        for r in table("food_portion.csv"):
            w = num(r.get("gram_weight"))
            if w and r["fdc_id"] not in portions:
                desc = " ".join(x for x in (r.get("amount"), r.get("modifier") or r.get("portion_description")) if x)
                portions[r["fdc_id"]] = (w, desc[:40] or "1 porzione")
        batch = []
        for fid, name in foods.items():
            v = values.get(fid, {})
            if not plausible(v.get("kcal"), v.get("protein"), v.get("carbs"), v.get("fat")):
                continue
            w, desc = portions.get(fid, (100.0, "100 g"))
            batch.append((norm(name), name[:120], "", None, "USDA", v["kcal"], v.get("protein") or 0, v.get("carbs") or 0,
                          v.get("fat") or 0, v.get("fiber") or 0, v.get("iron") or 0, v.get("calcium") or 0,
                          v.get("b12") or 0, v.get("zinc") or 0, w, desc))
        db.executemany("INSERT INTO foods VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", batch)
        total += len(batch)
        print(f"  {len(batch)} alimenti", flush=True)
    return total


def main():
    if os.path.exists(OUT):
        os.remove(OUT)
    db = sqlite3.connect(OUT)
    setup(db)
    off = usda_n = 0
    try:
        usda_n = usda(db)
    except Exception as e:  # the build continues with what it has
        print("USDA non disponibile:", e, flush=True)
    off = open_food_facts(db)
    db.execute("CREATE INDEX foods_code ON foods(code)")
    meta = {"built": datetime.date.today().isoformat(), "off": off, "usda": usda_n, "count": off + usda_n}
    db.executemany("INSERT INTO meta VALUES (?,?)", [(k, str(v)) for k, v in meta.items()])
    db.commit()
    db.execute("VACUUM")
    db.close()
    print(json.dumps(meta), flush=True)
    if off + usda_n < 1000:
        sys.exit("Database troppo piccolo: qualcosa non ha funzionato")


if __name__ == "__main__":
    main()
