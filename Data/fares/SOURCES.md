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
| `transferTable` | The engine's OMNY rules (`FareEngine.swift`, M2a): subway↔bus and bus↔bus free; express bus on a base fare's transfer pays the step-up; subway→subway only inside fare control or between `outOfSystemTransfers`. MTA Passenger Tariff (NYCTA, MTA Bus, MaBSTOA, SIRTOA), effective 2026-01-04 (https://www.mta.info/document/195636), §V: "Express Bus to Express Bus — One free transfer from express bus to express bus on a different route within two hours of initial fare payment"; express bus → local bus or subway free; local bus or subway → express bus pays the difference | Verified 2026-09-29 against the tariff, express bus → express bus included. Not modeled: the tariff's same-route exclusion (no free transfer back onto the route of the paid fare, express or local) |
| `outOfSystemTransfers`: Lexington Av/59 St (4 5 6 and N R W) ↔ Lexington Av/63 St, Junius St ↔ Livonia Av | MTA out-of-system transfer list (plan facts: "except at Lex/59–63 and Junius–Livonia") | Ids are parent stations of the supplemented subway feed; `bikeride-data config` checks each resolves to a station (`ReferenceChecks`) |
| `inSystemTransfers`: South Ferry (1) ↔ Whitehall St (R W) | One complex since 2009; the 2026 subway `transfers.txt` leaves it out | The reference check fails once `transfers.txt` lists the pair, so it is dropped here then |
| `statenIslandRailway`: route `S:SI`, fare stations St George (`S:S31`) and Tompkinsville (`S:S30`) | MTA: SIR fares are collected only at St George and Tompkinsville. Tariff §VI (above): "SIR to and from Subway: Free transfer within two hours of SIR or subway fare payment" (across the ferry, both ways); SIR ↔ local bus free; SIR → express bus pays the difference, express bus → SIR free | Checked against the subway feed by the reference checks. Not modeled: the Special Transfer Rules supplement's two-transfer chains through St George (Appendix IV, https://www.mta.info/document/195641) |

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
| `dayPass` | $25 pass for 24 hours; unlimited 30-minute classic rides, then $0.41/min; e-bike $0.41/min; no unlock fee | https://citibikenyc.com/pricing/day ("$25/day", "24 hours", "Unlimited 30-minute rides on a classic Citi Bike", "an additional $0.41 per minute" over 30 minutes and for e-bikes) and https://citibikenyc.com/pricing, checked 2026-09-29 | true |
| `reducedFare` | Classic 45 min included, then $0.27/min; e-bike $0.14/min; no unlock fee; no Manhattan cap; no plan price (the $5 is monthly) | https://citibikenyc.com/community-programs/reducedfare ("$5 monthly", "Unlimited free 45-min classic rides", "$0.27/minute after 45 minutes", "$0.14/min ebike rides", "No bike unlock fees") and https://citibikenyc.com/pricechange2026 (Reduced Fare: "Ebike fees: Increase to $0.14 per minute", classic overage $0.27), checked 2026-09-29 | false: whether the member's $5.40 Manhattan e-bike cap also applies is not published (pricechange2026 states it under annual members only, the Reduced Fare pages don't mention it), so it is left out and the price is an upper bound |

`taxConfirmed` is false: GBFS marks the single ride `is_taxable: true`, but what the rider pays
with tax has not been checked, so every Citi Bike cost stays "est.". The compiler compares the
non-member e-bike price with `system_pricing_plans` on every build and warns on drift.

Still to look up: whether the Manhattan e-bike cap applies to Reduced Fare Bike Share. Also
noted on 2026-09-29: https://citibikenyc.com/pricechange2026 still lists the January 2026 New
Jersey rates ($0.35/min non-member, $0.23/min annual member), while /pricing and /pricing/day
show one list; the Day Pass is marked verified on the single-list reading above.
