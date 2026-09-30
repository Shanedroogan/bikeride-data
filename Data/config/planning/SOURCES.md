# Bike planning (M2c)

The six optional bike-planning sections of the `config` artifact: `availability`, `rules`,
`weather`, `pace`, `speeds` and `overheads` (keys, units and comparisons: "config" in
`docs/formats.md`). Each section comes from its own file here and is in the document exactly
when the file exists: nothing is compiled in, so config sources from before M2c (such as a pinned
Tier B fixture's) still compile to the bytes they always did. The app plans bikes only when all
six are present. The files are read strictly, like every config source. Nothing else may be in
this directory (names starting with `.`, such as Finder's `.DS_Store`, are ignored): a misspelled
file name fails the build instead of quietly dropping its section and with it bike planning.

| File | Artifact key |
|---|---|
| `availability.json` | `availability` |
| `rules.json` | `rules` |
| `weather.json` | `weather` (all but `alertKeywords`) |
| `weather-alert-keywords.csv` | `weather.alertKeywords` (read only when `weather.json` exists, and then required) |
| `pace.json` | `pace` |
| `speeds.json` | `speeds` |
| `overheads.json` | `overheads` |

The values are the M2c plan's, written 2026-09-27: the app plan's "Citi Bike availability",
"Weather gate", "Planner rules, ranking, output" and "Speed learning" sections, the M2c
availability audit's config design (§H), the weather-and-rules audit's config design (§C), the
recommended defaults of the M2c review, and the rider decisions of 2026-09-27. None is measured
yet: M6's backtest and ride logs tune them.

## availability.json

- A station passes at P ≥ 90%; an itinerary at a product ≥ 80%; "Tight" is 70–90%.
- Bands by τ (time to arrival plus the station report's age), the plan's threshold table: under
  2 min, P(≥ 1 bike) and P(≥ 1 dock), with at least 1 open dock reported now (d0 ≥ 1); 2–5 min,
  P(≥ 1 bike) with at least 1 bike of the chosen type reported now (b0 ≥ 1), and P(≥ 2 docks)
  with at least 2 docks reported now (d0 ≥ 2); 5–20 min, P(≥ 1 bike) and P(≥ 2 docks), no floor.
  Staleness comes from each station's last_reported, and the pickup floor counts the requested
  bike type (M2c review).
- The 2–5 min pickup was P(≥ 2 bikes) with b0 ≥ 2 (the plan's table) until the user's decision of
  2026-09-29: a station with exactly one bike of the rider's type, 1–3 minutes away, is accepted.
  With a report about a minute old (the feed's usual age), 1–3 min away is τ 2–4 min, this band,
  whose b0 ≥ 2 floor refused it (and P(≥ 2) could not reach 90% with one bike). So the band now
  asks one bike, like the bands on either side; P(≥ 1) ≥ 90% still applies. The drop-off side of
  the band (d0 ≥ 2, P(≥ 2 docks)) is unchanged: the decision was about bikes.
  The band is τ_eff 120–300 s, so the rule reaches up to 4:59 away with a fresh report (3:59 with
  one a minute old); from 5 min the next band already asked one bike with no floor, so before
  this a lone bike failed at 4:59 and could pass at 5:00.
  What it does to plans (am-peak capture, 160 ODs × 3 riders, 17 recommendations changed): a lone
  bike now passing also changes the leg's type, since the per-leg rule only compares types that
  both pass. A lone e-bike beside classics now replaces the classic where it saves ≥ 2 min within
  the $2/min allowance (faster, pricier: od071, od098). New one-bike pickups also take places
  among the search's kept alternatives, and a cheaper option can drop out (od077's bus + classic
  different option). A lone classic beside e-bikes ends the "standalone" e-bike: on a short leg
  the e-bike saves < 2 min, so the leg rides the slower classic, which can miss a connection or
  lose to another dock. That made three plans worse: od080 (the −8 min bike + D option is gone),
  od089 member (−5 min $2.16 became −4 min $3.24) and od008 (same arrival, +$0.81–1.23, lowest P
  100% → 91.7%, via a one-bike pickup that took the search's slot). The engine answers them (the
  app's b3-engine, 2026-09-30): the e-bike rule now weighs the whole trip (rules.json below), so
  od080's −8 min e-bike + D is back, and od089 member rides the lone classic (−4 min, $0.00: the
  e-bike to its own nearest dock is under 2 min sooner); od008 was the direct bike's one slot, not
  the type rule, and other direct rides within a minute of it are now offered too, so its P 100%
  ride is recommended again.
- Past 20 min (and for depart-at), pooled: the target plus up to 2 more filtered stations within
  300 m, discounted 30%, with the 5–20 min band's counts (pickup ≥ 1, drop-off ≥ 2).
- During a ride, re-route when P < 70% with τ ≥ 2 min.
- Trend blend after 10 min of watching, over a 20-min window, weight 50%, ignoring jumps over
  4 (rebalancing, valet), gaps up to 3 min.
- Variance: independent bins (ρ 0), no inflation (100); both to be tuned by the M6 backtest.
- Cold start: 8 nearest neighbours within 1 km; a station with none that close is capped at 89%,
  so it is never "Likely".

## rules.json

- Δ = max(3 min, 10% of the baseline's trip time) (`deltaMinSeconds` 180, `deltaPercent` 10).
- Every bike ride is at least 5 min; pickups and docks within a 10-min walk.
- E-bike per leg: saves ≥ 2 min **and** costs at most **$2.00 more per minute saved** than the
  classic (`ebikeAllowanceCentsPerMinute` 200), each type timed at the rider's own learned speed.
  The saving is the whole trip's (the rider's decision of 2026-09-30): how much sooner the journey
  arrives with the e-bike than with the classic in its place (the same pickup at the same time,
  everything after re-timed), so an e-bike that catches a connection the classic misses wins, and
  one that waits for the same train, or docks nearer only to walk further, saves nothing. The
  thresholds are unchanged.
  The rider's decision of 2026-09-27: e-bikes are judged more loosely than the journey guardrail,
  through a key of their own (the plan's text had the guardrail's $1/min; at $1/min an e-bike
  almost never replaced an available classic, M2c review).
- Journey guardrail: $1.00 more per minute saved by default; the rider picks $0.50, $1.00 or
  $2.00, or "No limit" (a rider setting, not a value here).
- Score: 2 min per transfer, 3 min at weather caution; options within 2 min of the best form one
  bucket. 3 bike itineraries kept per bike-leg count, 3 stops per count enriched with real time.

## weather.json and weather-alert-keywords.csv

- 5-min buckets; minute data for the first hour; forecast to 168 h (7 days); 72 h of history;
  cached 10 min per 1 km cell.
- An alert with no onset or end (WeatherKit's) gates rides that start within 12 h; "Leave at …"
  is offered when a block clears within 60 min.
- **Everyday** (the default), the plan's table: rain blocks at a minute ≥ 50% and ≥ 0.02 in/h, or
  an hourly chance ≥ 60%; caution 40–60%. Rain before: ≥ 0.01 in over the last 2 h (3 h when
  humidity is above 85%, below 50°F, or at night) is caution. Thunderstorm, freezing rain, sleet,
  hail or falling snow blocks (snow, sleet, hail or mixed precipitation at ≥ 50% chance). Snow
  cover: ≥ 2 in over 72 h with a max ≤ 36°F since the last snowfall blocks. Ice: ≤ 34°F with
  precipitation in the last 12 h blocks. Wind: sustained ≥ 20 or gusts ≥ 35 mph block; ≥ 12 is
  caution. Feels-like below 25°F or ≥ 103°F blocks; ≤ 40°F or ≥ 90°F is caution (the plan's
  "25–40°F" includes 40). Alerts: thunderstorm, winter/ice, high wind, extreme heat and tornado
  block; informational allows; unknown is caution.
- **Fair-weather**: every caution blocks; cold and heat limits 40°F and 90°F.
- **Hardy**, as the plan lists it ("blocks only rain ≥ 0.10 in/h, thunder, ice or snow, wind ≥
  25/40 mph, and feels-like < 15°F or ≥ 105°F"): rain blocks need ≥ 0.10 in/h (a minute's
  intensity, or the hour's amount); wind 25/40 mph; feels-like 15°F/105°F; high-wind and
  extreme-heat alerts are caution (the measured wind and feels-like decide), while thunderstorm,
  winter/ice and tornado alerts still block. **Not in the plan, chosen here:** Hardy keeps
  Everyday's cautions (rain 40%, rain before, wind 12 mph, feels-like 40°F/90°F) and its snow
  cover and ice rules.
- `weather-alert-keywords.csv`: `class,keywords`, keywords separated by `|`, rows in priority
  order (the first rule with a keyword the lowercased alert event or summary contains wins; no
  match is `unknown`, which is caution). The compiler checks the keywords like
`alerts/path-keywords.csv`'s: lowercase, no surrounding spaces, each in one row, and none
containing a keyword of an earlier row (it could never decide a match). Names from NWS's event list (api.weather.gov/alerts/types),
  which WeatherKit's summaries follow. Order matters: `winterIce` comes before `highWind`, so a
  Wind Chill alert is cold, not wind; "Extreme Cold" is `winterIce`, "Extreme Wind" `highWind`.
  `informational` (allow): coastal flood, rip current and air quality (the M2c review), plus beach
  hazards, high surf and small craft advisories (marine and beach only; chosen here). Not listed,
  so caution: flood and flash flood (heavy rain blocks through the rain rules anyway), dense fog,
  freeze, special weather statements.

## pace.json, speeds.json, overheads.json

- Default speeds, per bike type, until the rider's own are learned: classic 8 mph, e-bike 10 mph.
- Speed learning, per bike type on its own (the rider's decision of 2026-09-27: the e-bike vs
  classic comparison uses each type's learned speed): an average plus the residual standard
  deviation of the effective speed (planned distance ÷ (unlock-to-dock time − the overheads)),
  clamped to 5–15 mph, used after 3 rides. Before a scheduled boarding, the 60th-percentile ride
  time: the average − 0.25 SD in speed terms.
- Pace presets seed it: Relaxed 85%, Typical 100%, Fast 115% of each type's speed, or a speed the
  rider enters (clamped like a learned one).
- Overheads: unlock 90 s, dock 60 s.
- The average's weight: 25% per ride (`emaWeightPercent`), for the average and for the variance
  of the residuals. The plan says "an EMA" without a weight; 25% follows a rider's change of habit
  within about 4 rides while one unusual ride moves the speed by a quarter of its deviation. Set by
  Claude on 2026-09-27 when M2c took on the per-type tracker; M6 tunes it on real rides.
