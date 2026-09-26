#!/usr/bin/env python3
"""Build LIRR station->zone and zone-pair fare CSVs from official MTA PDFs.

Inputs (raw/ is gitignored; download the PDFs from the URLs in SOURCES.md):
  raw/doc194866.pdf  MTA/LIRR Station Fares, effective 2026-01-04 (adopted fare chart + zone map)
  raw/doc186866.pdf  LIRR Proposed Fares, Zones & Stations (2026 fare change, Sep 2025)
  $LIRR_GTFS_ZIP     the LIRR GTFS gtfslirr.zip the station list comes from (read-only)

Usage: LIRR_GTFS_ZIP=path/to/gtfslirr.zip python3 build.py
The Belmont Park row (no service in feed GO202_26, so this script skips it) is appended by hand;
see SOURCES.md.
"""
import csv, io, os, re, subprocess, sys, zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
RAW = HERE / "raw"
if "LIRR_GTFS_ZIP" not in os.environ:
    sys.exit("set LIRR_GTFS_ZIP to the LIRR GTFS zip (see the docstring)")
GTFS = Path(os.environ["LIRR_GTFS_ZIP"])
ZONES = [1, 3, 4, 7, 9, 10, 12, 14]


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout


def cents(s):
    d, c = s.split(".")
    return int(d) * 100 + int(c)


# ---------------------------------------------------------------- 1. fare matrix (doc 194866)
layout = sh("pdftotext", "-layout", str(RAW / "doc194866.pdf"), "-")
assert "Effective: January 4, 2026" in layout
peak_rows, off_rows = [], []
for line in layout.splitlines():
    m = re.search(r"(?<!Onboard )One-Way (Peak|Off-Peak)\s+((?:\$?\d+\.\d\d\s+){7}\$?\d+\.\d\d)\s*$", line)
    if not m or "Onboard" in line[: m.start() + 1]:
        continue
    vals = [cents(v.lstrip("$")) for v in m.group(2).split()]
    (peak_rows if m.group(1) == "Peak" else off_rows).append(vals)
assert len(peak_rows) == 8 and len(off_rows) == 8, (len(peak_rows), len(off_rows))
PEAK = {(ZONES[r], ZONES[c]): peak_rows[r][c] for r in range(8) for c in range(8)}
OFF = {(ZONES[r], ZONES[c]): off_rows[r][c] for r in range(8) for c in range(8)}
for a in ZONES:
    for b in ZONES:
        assert PEAK[a, b] == PEAK[b, a] and OFF[a, b] == OFF[b, a], ("asymmetric", a, b)
        if a >= 4 and b >= 4:
            assert PEAK[a, b] == OFF[a, b], ("zones 4-14 peak != offpeak", a, b)

# cross-check vs doc 186866 "Proposed" columns (zone-1 column, intermediate fares)
prop = sh("pdftotext", "-layout", str(RAW / "doc186866.pdf"), "-")
checked = 0
sec = prop.split("Fares to/from Zone 1")[1].split("Senior/Disabled")[0]
for m in re.finditer(r"^\s*(\d+)\s+\$[\d.]+\s+\$[\d.]+\s+\$[\d.]+\s+\$[\d.]+\s+\$[\d.]+\s+\$([\d.]+)\s+\$[\d.]+\s+\$([\d.]+)\s*$", sec, re.M):
    z = int(m.group(1))
    assert (PEAK[1, z], OFF[1, z]) == (cents(m.group(2)), cents(m.group(3))), ("zone1 mismatch", z)
    checked += 1
inter = prop.split("Intermediate Fares")[1]
for m in re.finditer(r"^\s*(\d+)\s+(\d+)\s+\$[\d.]+\s+\$[\d.]+\s+\$[\d.]+\s+\$[\d.]+\s+\$[\d.]+\s+\$([\d.]+)\s+\$[\d.]+\s+\$([\d.]+)\s*$", inter, re.M):
    a, b = int(m.group(1)), int(m.group(2))
    assert (PEAK[a, b], OFF[a, b]) == (cents(m.group(3)), cents(m.group(4))), ("intermediate mismatch", a, b)
    checked += 1
assert checked == 8 + 10, checked
# CityTicket / Far Rockaway Ticket proposed = 7.25 / 5.25
assert re.search(r"^\s*1\s+\$7\.00\s+\$7\.25\s+\$5\.00\s+\$5\.25", prop, re.M)
assert re.search(r"^\s*3\s+\$7\.00\s+\$7\.25\s+\$5\.00\s+\$5\.25", prop, re.M)
assert re.search(r"^\s*4\s+\$7\.00\s+\$7\.25\s+\$5\.00\s+\$5\.25", prop, re.M)

# ---------------------------------------------------------------- 2. zone list (doc 186866 table)
# -raw keeps the Word table's cell order (zone number, then its station cell) but drops some
# spaces ("HunterspointAvenue", "St.Albans"), so names are compared with whitespace removed.
def key(name):
    return re.sub(r"\s+", "", name.replace("*", "")).lower()


raw1 = sh("pdftotext", "-raw", "-f", "1", "-l", "1", str(RAW / "doc186866.pdf"), "-")
body = raw1.split("Zone Stations", 1)[1].split("Long Island Rail Road", 1)[0]
cells, cur = {}, None
for line in body.strip().splitlines():
    m = re.match(r"^(\d+)(?:\s+(.*))?$", line.strip())
    if m and int(m.group(1)) in ZONES:
        cur = int(m.group(1))
        line = m.group(2) or ""
    cells.setdefault(cur, []).append(line.strip())
zone_of_label = {}  # key(name) -> zone
printed = {}        # key(name) -> name as printed in 186866
for z, ls in cells.items():
    for name in " ".join(ls).split(","):
        name = re.sub(r"\s+", " ", name).strip()
        if not name:
            continue
        assert key(name) not in zone_of_label, name
        zone_of_label[key(name)] = z
        printed[key(name)] = name
counts = {z: sum(1 for v in zone_of_label.values() if v == z) for z in ZONES}
assert counts == {1: 11, 3: 14, 4: 31, 7: 29, 9: 11, 10: 15, 12: 4, 14: 11}, counts

# ---------------------------------------------------------------- 3. map-band check (doc 194866 bbox)
bbox = sh("pdftotext", "-bbox", str(RAW / "doc194866.pdf"), "-")
words = [(float(a), float(b), float(c), float(d), w)
         for a, b, c, d, w in re.findall(r'<word xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">([^<]*)</word>', bbox)]
monthly_y = sorted(y0 for x0, y0, x1, y1, w in words if w == "Monthly")
assert len(monthly_y) == 8
band_top = [y - 4 for y in monthly_y]  # divider lines sit just above each zone's first (Monthly) row
map_words = [w for w in words if w[0] < 800 and w[1] > 145 and w[1] < 1580]


def band(ycenter):
    z = None
    for i, top in enumerate(band_top):
        if ycenter >= top:
            z = ZONES[i]
    return z


def norm(t):
    return t.replace("*", "").strip()


def find_label(label):
    """Center-y of every occurrence of the label's words: same line, or wrapped onto the next.
    Matching is case-sensitive, so the terminal HEMPSTEAD never matches 'Hempstead Gardens'."""
    toks = label.split()
    hits = []
    for w in map_words:
        if norm(w[4]) != toks[0]:
            continue
        ok, prev = True, w
        for t in toks[1:]:
            nxt = [v for v in map_words if norm(v[4]) == t
                   and ((abs(v[1] - prev[1]) < 3 and 0 <= v[0] - prev[2] < 15)          # same line
                        or (0 < v[1] - prev[1] < 25 and abs(v[0] - w[0]) < 120))]     # wrapped
            if not nxt:
                ok = False
                break
            prev = min(nxt, key=lambda v: (abs(v[1] - prev[1]), abs(v[0] - prev[2])))
        if ok:
            hits.append((w[1] + w[3]) / 2)
    return hits


CHART_LABEL = {  # doc 186866 name -> label as drawn on the 194866 map, when they differ
    "Penn Station": "PENN STATION", "Grand Central": "GRAND CENTRAL", "Atlantic Terminal": "ATLANTIC TERMINAL",
    "Long Island City": "LONG ISLAND CITY", "Hunterspoint Avenue": "HUNTERSPOINT AVENUE", "Jamaica": "JAMAICA",
    "Far Rockaway": "FAR ROCKAWAY", "West Hempstead": "WEST HEMPSTEAD", "Hempstead": "HEMPSTEAD",
    "Port Washington": "PORT WASHINGTON", "Long Beach": "LONG BEACH", "Hicksville": "HICKSVILLE",
    "Oyster Bay": "OYSTER BAY", "Babylon": "BABYLON", "Ronkonkoma": "RONKONKOMA",
    "Port Jefferson": "PORT JEFFERSON", "Montauk": "MONTAUK", "Greenport": "GREENPORT",
}
CHART_LABEL = {key(n): l for n, l in CHART_LABEL.items()}
# 186866's -raw text lost some spaces, so take the spaced spelling from GTFS stops.txt names
_zf = zipfile.ZipFile(GTFS)
_names = [r["stop_name"] for r in csv.DictReader(io.TextIOWrapper(_zf.open("stops.txt"), "utf-8-sig"))]
_ALIAS = {"Elmont-UBS Arena": "Elmont-UBS", "Flushing Main Street": "Flushing", "Yaphank-BNL": "Yaphank"}
spaced = {key(_ALIAS.get(n, n)): _ALIAS.get(n, n) for n in _names}
band_zone = {}
for k, z in zone_of_label.items():
    label = CHART_LABEL.get(k) or spaced[k]
    hits = find_label(label)
    zs = {band(y) for y in hits}
    assert hits and len(zs) == 1, (printed[k], label, hits, zs)
    band_zone[k] = zs.pop()
mismatch = {printed[k]: (zone_of_label[k], band_zone[k]) for k in zone_of_label if zone_of_label[k] != band_zone[k]}
assert not mismatch, mismatch

# ---------------------------------------------------------------- 4. GTFS stations
zf = zipfile.ZipFile(GTFS)
stops = list(csv.DictReader(io.TextIOWrapper(zf.open("stops.txt"), "utf-8-sig")))
assert "parent_station" not in stops[0] and "location_type" not in stops[0]  # every row is a station
public = {}
for r in csv.DictReader(io.TextIOWrapper(zf.open("stop_times.txt"), "utf-8-sig")):
    if r["pickup_type"] != "1" or r["drop_off_type"] != "1":
        public[r["stop_id"]] = True
    else:
        public.setdefault(r["stop_id"], False)
feed_version = next(csv.DictReader(io.TextIOWrapper(zf.open("feed_info.txt"), "utf-8-sig")))["feed_version"]

GTFS_TO_LABEL = {"Elmont-UBS Arena": "Elmont-UBS", "Flushing Main Street": "Flushing", "Yaphank-BNL": "Yaphank"}
BOROUGH = {  # NYC stations; every other station is in Nassau or Suffolk
    "Penn Station": "Manhattan", "Grand Central": "Manhattan",
    "Atlantic Terminal": "Brooklyn", "Nostrand Avenue": "Brooklyn", "East New York": "Brooklyn",
}
for q in ["Long Island City", "Hunterspoint Avenue", "Woodside", "Forest Hills", "Kew Gardens", "Mets-Willets Point",
          "Jamaica", "Locust Manor", "Laurelton", "Rosedale", "St. Albans", "Hollis", "Queens Village", "Flushing",
          "Murray Hill", "Broadway", "Auburndale", "Bayside", "Douglaston", "Little Neck", "Far Rockaway"]:
    BOROUGH[q] = "Queens"
assert len(BOROUGH) == 26
BOROUGH = {key(n): b for n, b in BOROUGH.items()}

rows, skipped, used = [], [], set()
for s_ in stops:
    sid, name = s_["stop_id"], s_["stop_name"]
    if sid not in public:
        skipped.append((sid, name, "no stop_times in feed " + feed_version))
        continue
    if not public[sid]:
        skipped.append((sid, name, "every stop_time has pickup_type=1 and drop_off_type=1 (non-public facility)"))
        continue
    label = GTFS_TO_LABEL.get(name, name)
    k = key(label)
    assert k in zone_of_label, ("unplaced", sid, name)
    assert k not in used, label
    used.add(k)
    z = zone_of_label[k]
    boro = BOROUGH.get(k)
    if z in (1, 3):
        assert boro in ("Manhattan", "Brooklyn", "Queens"), name
        cf = "cityTicket"
    elif label == "Far Rockaway":
        assert boro == "Queens"
        cf = "farRockaway"
    else:
        assert boro is None, name
        cf = "none"
    note = f"zone {z} (doc186866 table; doc194866 map band agrees)"
    if label != name:
        note += f"; MTA lists as '{label}'"
    if name == "Yaphank-BNL":
        note += "; UNCONFIRMED: zone of the replaced Yaphank station (chart predates the Jul 2026 relocation)"
    if cf == "cityTicket":
        note += f"; {boro}; CityTicket table covers zones 1 and 3"
    elif cf == "farRockaway":
        note += "; Queens but trips run via Nassau; Far Rockaway Ticket is valid to Zone 1 stations only"
    elif label == "Elmont-UBS":
        note += "; at the Queens/Nassau line; MTA excludes CityTicket here (trips run via Nassau)"
    else:
        note += "; outside NYC"
    rows.append({"stop_id": "L:" + sid, "gtfs_name": name, "zone": z, "city_fare": cf, "source_note": note})

unused = sorted(printed[k] for k in set(zone_of_label) - used)
assert unused == ["Belmont Park"], unused
assert len(rows) == 125, len(rows)
assert sorted(n for _, n, _ in skipped) == ["Belmont Park", "Hillside Facility"], skipped

rows.sort(key=lambda r: (r["zone"], r["gtfs_name"]))
with open(HERE / "lirr-stations-2026.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=["stop_id", "gtfs_name", "zone", "city_fare", "source_note"])
    w.writeheader()
    w.writerows(rows)

used_zones = sorted({r["zone"] for r in rows})
assert used_zones == ZONES
with open(HERE / "lirr-zone-fares-2026.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["from_zone", "to_zone", "peak_cents", "offpeak_cents"])
    n = 0
    for i, a in enumerate(used_zones):
        for b in used_zones[i:]:
            w.writerow([a, b, PEAK[a, b], OFF[a, b]])
            n += 1
assert n == 36

print("stations:", len(rows), {cf: sum(r["city_fare"] == cf for r in rows) for cf in ("cityTicket", "farRockaway", "none")})
print("per zone:", {z: sum(r["zone"] == z for r in rows) for z in ZONES})
print("skipped:", skipped)
print("zone pairs:", n, "fare cross-checks vs 186866:", checked)
print("feed:", feed_version)

if "--margins" in sys.argv:
    edges = band_top + [1580.0]
    out = []
    for k in zone_of_label:
        label = CHART_LABEL.get(k) or spaced[k]
        for y in find_label(label):
            i = ZONES.index(band(y))
            out.append((min(y - edges[i], edges[i + 1] - y), label, round(y, 1), band(y), len(find_label(label))))
    for m in sorted(out)[:8]:
        print("margin %.1f pt  %-22s y=%s zone=%s hits=%d" % m)
    print("labels with >1 hit:", sorted({o[1] for o in out if o[4] > 1}))
