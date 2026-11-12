# Testalarme wie Alamos FE2

`testalarm.py` sendet Einsätze im **Datenformat V2** (wie das FE2-JSON-Plugin) – wahlweise
über den MQTT-Broker wie FE2 selbst (`--weg mqtt`, braucht `mosquitto_pub`) oder direkt an
die Debug-Schnittstelle des Backends (`--weg http`). Nur Python-Standardbibliothek.

```sh
./testalarm.py liste                         # Beispiele und Änderungen
./testalarm.py senden vu                     # neuer Einsatz → Einsatznummer wird ausgegeben
./testalarm.py aendern <nummer> stichwort    # stichwort | patient | fahrzeug | nachmeldung | ort
./testalarm.py schliessen <nummer>
./testalarm.py ablauf bus --pause 20         # neu → Stichwort → Fahrzeug → Patient → Nachmeldung → schließen
```

Standard ist der Entwicklungs-Broker aus `backend/docker-compose.dev.yml`
(`localhost:1883`, Benutzer `test-rd` / `entwicklung-fe2`, Topic `elrd/test-rd/alarm`).
Dafür im Backend die Organisation **`test-rd`** anlegen. Für einen echten Broker:

```sh
./testalarm.py senden vu --host mqtt.example.de --tls --org brk-schweinfurt \
  --benutzer brk-schweinfurt --passwort '…'
```

Die Dateien in `beispiele/` lassen sich auch von Hand senden (Platzhalter `{{ID}}` und
`{{TIMESTAMP}}` vorher ersetzen):

```sh
sed -e 's/{{ID}}/4711/' -e "s/{{TIMESTAMP}}/$(date -Iseconds)/" beispiele/vu.json \
  | mosquitto_pub -h localhost -u test-rd -P entwicklung-fe2 -t elrd/test-rd/alarm -q 1 -s
```

Alle Angaben sind erfunden; die Funkrufnamen stammen aus den mitgelieferten Stammdaten
(Schweinfurt), damit die App sie beim Übernehmen zuordnen kann. Testeinsätze tragen
`custom.elrdTest = "true"` und erscheinen in der App mit dem Hinweis „Test“.
