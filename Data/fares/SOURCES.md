# Fares: MTA, PATH, Citi Bike

Reviewed inputs of the `config` artifact (`fares.mta`, `fares.path`, `fares.citiBike`); the LIRR
tables are in `lirr/`. `bikeride-data config` reads these files strictly: an unknown or misspelled
key, a missing key or a wrong type fails the build. Keys and units: "config" in
`docs/formats.md`. Values are whole cents and seconds.

The values were transcribed on 2026-09-27 from the app's 2026 literals (`FareConfig.swift`,
`CitiBikePricing.swift` in BikeRideKit), which were taken from the plan's "Fares (2026)" and
"Citi Bike pricing (2026)" facts, researched 2026-09-24. They are unchanged by the move.

## mta.json

| Value | Source | State |
|---|---|---|
| Base fare $3.00 (subway, local bus, SBS), express bus $7.25, step-up $4.25 | MTA fares (plan facts, 2026) | Verified |
| One free transfer within 2 h (`transferWindowSeconds` 7200) | MTA OMNY rules (plan facts) | Verified |
| `transferTable` | The engine's OMNY rules (`FareEngine.swift`, M2a): subway↔bus and bus↔bus free; express bus on a base fare's transfer pays the step-up; subway→subway only inside fare control or between `outOfSystemTransfers` | Express bus → express bus `free` is **not verified** (TASKS.md: "Verify MTA express bus ↔ express bus transfer rule"). It stays free until checked |
| `outOfSystemTransfers`: Lexington Av/59 St (4 5 6 and N R W) ↔ Lexington Av/63 St, Junius St ↔ Livonia Av | MTA out-of-system transfer list (plan facts: "except at Lex/59–63 and Junius–Livonia") | Ids are parent stations of the supplemented subway feed; `bikeride-data config` checks each resolves to a station (`ReferenceChecks`) |
| `inSystemTransfers`: South Ferry (1) ↔ Whitehall St (R W) | One complex since 2009; the 2026 subway `transfers.txt` leaves it out | The reference check fails once `transfers.txt` lists the pair, so it is dropped here then |
| `statenIslandRailway`: route `S:SI`, fare stations St George (`S:S31`) and Tompkinsville (`S:S30`) | MTA: SIR fares are collected only at St George and Tompkinsville | Checked against the subway feed by the reference checks |

## path.json

$3.25 per entry since 2026-05-04 (PANYNJ; plan facts). No MTA transfer credit and no cap: those
are engine rules, not values. The reduced fare ($1.60) is not carried: nothing prices it yet.

## citibike.json

One price list for New York City, Jersey City and Hoboken since 2026-05-29. `verified` is per
plan; an unverified plan's prices are shown as estimates.

| Plan | Values | Source | `verified` |
|---|---|---|---|
| `nonMember` | $4.99 unlock with 30 classic minutes, then $0.41/min; e-bike $4.99 + $0.41/min | Plan facts; Citi Bike GBFS `system_pricing_plans` (`EBIKE_SINGLE_RIDE`: price "4.99", 0.41 per minute, checked 2026-09-27) | true |
| `member` | $239/yr; classic 45 min included, then $0.27/min; e-bike $0.27/min, capped at $5.40 for rides of 45 min or less entering or leaving Manhattan (NYC only) | Plan facts | true |
| `dayPass` | $25 pass. Ride terms (30 classic minutes, non-member per-minute rates) are **assumed** | Only the pass price is in the verified list | false |
| `reducedFare` | Mirrors the member plan (an upper bound), without a plan price | Reduced Fare Bike Share prices are not in the verified list | false |

`taxConfirmed` is false: GBFS marks the single ride `is_taxable: true`, but what the rider pays
with tax has not been checked, so every Citi Bike cost stays "est.". The compiler compares the
non-member e-bike price with `system_pricing_plans` on every build and warns on drift.

Still to look up (TASKS.md, M1): the published Day Pass ride terms and the Reduced Fare Bike
Share prices.
