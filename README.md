# ConkyBar 0.4.1 — DMS 1.6.3

- Ein einziger Graph in der oberen Leiste: vier physische Kerne als
  unterschiedlich gefärbte Linien (Farben aus dem DMS-Theme).
- Direkt sichtbar: CPU-Gesamtauslastung, RAM (8.8/15.3G), freier Platz
  unter /home (244.8G), CPU-Package-Temperatur. Keine Akkuanzeige.
- Beim Anklicken: acht logische CPU-Threads mit Einzelverlauf,
  Auslastung in Prozent und aktueller GHz-Anzeige.
- Im Klickfenster: aktuelle Kernel-Obergrenze der Taktfrequenz und
  ggf. Intel-P-State-Maximalprozent; diese Werte können durch TLP beeinflusst sein.
- Intel-Thermal-Throttle-Zähler: wenn sich ein Core-/Package-Zähler
  seit Pluginstart erhöht, wird das CPU-Icon etwa 30 Sekunden rot und
  das Klickfenster meldet das Ereignis. Fehlt die Schnittstelle, wird
  **nicht** "kein Throttling" behauptet.
- DMS zeichnet als `BasePill` die Hintergrundfarbe, Rundung und Transparenz.
- Der Python-Collector arbeitet rein lesend mit `/proc` und `/sys`.
- Die vier farbigen Linien stellen die **Auslastung**, nicht die Frequenz dar.
  Die Farbe identifiziert den Kern; daraus lässt sich Thermal-Throttling
  nicht ableiten. Intel-Thermal-Zähler erlauben eine bessere Aussage
  über thermische Ereignisse. Niedrige Takte sind im Leerlauf normal.

## Änderungen in 0.4.1

- Alle vier Zahlenfelder in der horizontalen Leiste haben jetzt feste,
  anhand der aktuellen DMS-Schrift vermessene Breiten und rechtsbündige
  Ausrichtung. Die Icons und Trennlinien bleiben dadurch beim Wechsel
  zwischen 8%, 99% und 100% sowie bei RAM-/Temperaturänderungen stehen.
- Doppelte CPU-Taktabfragen entfernt. Falls `/sys` keine Frequenz liefert,
  wird `/proc/cpuinfo` nur einmal je Messintervall gelesen.
  Der Collector bleibt ein einzelner dauerhaft laufender Python-Prozess.
- Richtwert für die Kontrolle des Collector-Prozesses auf dem eigenen Gerät:

  ```sh
  ps -eo pid,pcpu,rss,args | grep '[c]onkyBar/collector.py'
  ```

  `%CPU` ist ein durchschnittlicher Anteil eines logischen CPU-Threads,
  `RSS` der belegte Hauptspeicher in KiB. Der Verbrauch von QML/Canvas
  ist im DMS/Quickshell-Prozess enthalten und nicht separat ausgewiesen.

## Aktualisieren

Vorhandene `settings.json` wird nicht überschrieben. Das ZIP in das
bestehende Plugin-Verzeichnis entpacken und DMS neu starten:

```sh
bsdtar -xf ~/Downloads/dms-conkybar-v0.4.1.zip -C ~/.config/DankMaterialShell/plugins/
dms restart
```

Test des Collectors:

```sh
python3 ~/.config/DankMaterialShell/plugins/conkyBar/collector.py --once
```

## Einschränkungen

Die CPU-Frequenzen stammen aus `scaling_cur_freq` und sind keine exakt
zeitgleich gemessenen effektiven Kerntakte. Das ausgelesene
`scaling_max_freq` zeigt ein cpufreq-Policy-Limit, nicht zwingend alle
zugrundeliegenden effektiven TLP-/Hardwarebegrenzungen. Temperaturbedingtes
Throttling wird durch Intel-`thermal_throttle`-Zähler sichtbar, wenn der
Kernel diese bereitstellt; andere Leistungsbegrenzungen nicht automatisch.

Das QML konnte in dieser Umgebung nicht in einer laufenden DMS-Sitzung
ausgeführt werden. Das Plugin wurde anhand der DMS-1.6.3-Quellen erstellt.
