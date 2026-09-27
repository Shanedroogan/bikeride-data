# Bike share

`bikeshare.json` and `valet.csv`: the `bikeShare` section of the `config` artifact.

## bikeshare.json

- `regions`: Citi Bike's GBFS `region_id`s of the service area: New York City 71 ("NYC
  District"), 185 ("Bronx") and 158 ("8D"); Jersey City 70 ("JC District") and Hoboken 311
  ("Hoboken District"), one system with one price list since 2026-05-29. Names from the live
  `system_regions` feed (checked 2026-09-27; it lists exactly these seven regions with the two
  below); the ids are the app's `StationFilter` literals. The pinned `station_information`
  (static-20260926) uses 71 (2,401 stations), 70 (78), 311 (28) and no region (13). The stations
  compiler keeps the same five regions (`StationSelection.regionIDs`); the config compiler warns
  if the two lists ever differ.
- `excludedRegions`: 189 ("IC HQ") and 190 ("testzone"), not in service. The filter admits only
  `regions`; this list is for builds that start from the whole feed (the flows universe drops
  these).
- `vehicleTypes`: `vehicle_type_id` 1 is a classic bike, 2 an e-bike (GBFS `vehicle_types`, checked
  2026-09-27: 1 `human`, 2 `electric_assist` propulsion).
- `maxStatusAgeSeconds`: 600. A station whose status is older than 10 minutes is not used.

## valet.csv

`station_id,lat_e6,lon_e6,name,hours,valid_until_date,source_note`: valet stations by GBFS
`station_id`, with the coordinate (microdegrees) they were matched at, and when they are valet.
The compiler also reads the format-1 header without the two optional columns
(`station_id,lat_e6,lon_e6,name,source_note`), as older pinned sources have it.

- `hours`: weekly windows in local time, separated by `|`, each `<ISO weekday digits>
  <HH:MM>-<HH:MM>` (Monday is 1, Sunday 7; the end is excluded; `24:00` ends the day), e.g.
  `12345 07:00-19:00|67 10:00-16:00`. Empty: never valet.
- `valid_until_date`: `YYYYMMDD`, the last date the hours apply. Required whenever `hours` is
  filled (the build fails otherwise), so a weekly schedule that stops being updated lapses instead
  of applying silently; empty when `hours` is.

**Empty for now**: M2c ships with valet off. The GBFS feed has no valet field (checked on the
pinned `station_information`: its keys are capacity, is_charging, lat, lon, name, region_id,
rental_uris, short_name and station_id), and Citi Bike's valet schedule changes weekly. If the
list is maintained (not decided yet), it is filled from Citi Bike's Service page (web-published
facts, not feed or trip data), cross-checked against GBFS history (bikes + docks above
capacity). The compiler checks every row: the id must be in `stations.bin` and within 50 m of the
listed coordinate.
