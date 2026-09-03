# Weboberfläche (`--web`)

Startet das Spiel zusätzlich mit einer Weboberfläche im Browser.

```
ultrastardx --web
```

Danach im selben Netz `http://<Rechner>:8080` aufrufen.

Es gibt sie in zwei Ausbaustufen:

- **Fernbedienung** — die Sammlung durchsuchen und im Spiel ein Lied
  auswählen. Braucht nichts außer dem Spiel.
- **Singen im Browser** — Lied, Noten und Wertung laufen im Browser selbst.
  Dafür muss der Ordner `web/` neben der ausführbaren Datei liegen; fehlt er,
  liefert der Server stillschweigend nur die Fernbedienung aus.

## Ohne Bildschirm: `--web-only`

```
ultrastardx --web-only --songpath ~/Lieder
ultrastardx --web-only --webport 9000
```

Startet **nur** die Weboberfläche: kein Fenster, kein OpenGL, kein SDL.
Gedacht für einen Rechner ohne Grafikausgabe — ein kleiner Server im
Heimnetz, an dem gar kein Bildschirm hängt. Gesungen wird dann im Browser.

Beendet wird mit Strg-C oder `SIGTERM`; der Server schließt dabei ordentlich,
statt mitten in einer Antwort abzubrechen.

Die Abzweigung liegt in `ultrastardx.dpr` **vor** `Main`. Das ist der ganze
Trick: `Main` baut Fenster, OpenGL-Kontext und Tonausgabe auf und scheitert
ohne Bildschirm, bevor irgendetwas Nützliches passiert wäre. Alles, was im
kopflosen Zweig aufgerufen wird, kommt ohne SDL aus.

### Woher die Lieder kommen

In dieser Reihenfolge:

1. `--songpath <Ordner>` (mehrfach möglich)
2. `[Directories] SongDir*` aus der `config.ini` des Spiels
3. `songs/` neben der ausführbaren Datei bzw. in `~/.ultrastardx/`

Punkt 2 ist der Grund, warum überhaupt eine Ini gelesen wird: So sieht der
kopflose Server **dieselbe** Sammlung wie das Spiel auf demselben Rechner,
ohne dass man die Ordner doppelt pflegen muss. Findet sich gar nichts, sagt
das Programm das und beendet sich mit Code 1, statt eine leere Liste
auszuliefern.

### Warum ein zweiter Leser für die Kopfdaten

`TSongs` ist hier nicht zu gebrauchen: Es hängt über `USong` an `URenderer`
und `UMusic`, also an der Grafik- und Tonkette — schon das Übersetzen
scheitert an `sdl2_image`. `USongHeader` liest deshalb selbst, was in einer
Liederliste sichtbar ist: Titel, Interpret, Genre, Sprache, Edition, Jahr,
Tondatei, Duett-Kennzeichen. **Nichts davon betrifft Noten** — die liest der
Browser aus derselben `.txt`, es gibt also keinen zweiten Notenparser.

Die eine Regel, die dabei übereinstimmen muss: Ob ein Lied ein Duett ist,
entscheidet die **erste** Zeile des Notenteils. Eine Kopfzeile dazu gibt es
nicht. `testsongscan` hält das fest, samt Gegenprobe mit einem `P` weiter
unten.

## Fernbedienung

- Die Sammlung durchsuchen — mit derselben Syntax wie im Spiel:
  `abba OR queen`, `!live`, `(abba OR queen) AND 1990-1999`
- Nach Titel, Interpret, Genre, Sprache, Edition oder Jahr einschränken
- Ein Lied antippen: Es wird im Spiel **ausgewählt**

**Sie startet kein Lied im Spiel.** Zum Singen gehören Spielerzahl und Namen;
das aus der Ferne zu entscheiden führt nur dazu, dass jemand mitten im Raum
überrascht wird. Die Auswahl springt auf das Lied, gestartet wird am Gerät.

## Singen im Browser

Das Spiel selbst ist Pascal, SDL2, OpenGL, ffmpeg und PortAudio — davon läuft
im Browser nichts. Eine Übersetzung nach WebAssembly scheidet aus, weil FPCs
WASM-Ziel keine dieser Bibliotheken unterstützt. Der Kern ist deshalb in
JavaScript **neu geschrieben**, mit den Entsprechungen, die der Browser
mitbringt:

| im Spiel | im Browser |
| --- | --- |
| OpenGL | Canvas 2D |
| PortAudio (Aufnahme) | `getUserMedia` + `AnalyserNode` |
| ffmpeg (Wiedergabe) | `<audio>` |
| `UMain`-Schleife | `requestAnimationFrame` |

Gemeinsam bleibt das **Dateiformat**: Der Browser liest dieselben `.txt`, die
das Spiel liest — dieselbe Sammlung, keine Umwandlung, kein zweiter Bestand.

### Was übereinstimmen muss

Zwei Stellen im Format sind leicht zu übersehen, und beide verschieben alles
gegeneinander, wenn man sie falsch nachbaut:

- `#BPM` wird intern **mal vier** genommen (`USong.pas`), Schläge sind also
  Viertel-Beats.
- Zeit und Schlag hängen so zusammen: `t = GAP/1000 + Beat * 60 / BPM`.

Beides steht in `web/js/song.js` und wird in `web/tests/run.mjs` gegen
gerechnete Werte geprüft.

Taktgeber ist die Abspielposition des `<audio>`-Elements, **nicht** ein
Zeitgeber. Timer schwanken, und schon ein halber Schlag Versatz macht das
Singen unmöglich.

Die Tonhöhenerkennung ist dieselbe Idee wie im Spiel (NSDF/McLeod). Wichtig
ist dabei die Spitzenauswahl: Nimmt man schlicht das globale Maximum, landen
220, 440 und 880 Hz alle bei 110 Hz. Ein Test hält genau diesen Fehler fest.

### Video und Hintergrundbild

Dieselbe Reihenfolge wie im Spiel (`UScreenSingController`): Ist ein Video da,
läuft es; sonst steht das Hintergrundbild aus `#BACKGROUND`; sonst bleibt es
dunkel. Beides wird geladen — das Bild ist der **Rückfall**, nicht die
zweite Wahl.

Der Rückfall wird öfter gebraucht, als es klingt: In vielen älteren Liedern
steht ein `.avi`, `.mpg` oder `.divx`, und das spielt **kein Browser** ab.
Der Server liefert die Datei trotzdem mit dem richtigen Typ aus — nur so kann
der Browser sauber abwinken, statt an geratenen Daten zu würgen. Erst sein
`error` verrät, dass es nicht geht; vorher lässt sich das nicht feststellen.
Dann übernimmt das Bild. Zuverlässig laufen `.mp4`, `.webm` und `.ogv`.

Der Gleichlauf folgt dem Spiel: **Videoposition = `#VIDEOGAP` + Tonzeit**.
Maßgeblich ist also die Tonzeit, nicht das Video. Nachgezogen wird nur bei
mehr als 0,3 s Abweichung — jedes Bild neu zu setzen ließe das Video ruckeln,
gar nicht nachzuziehen ließe es davonlaufen. Ein negativer `#VIDEOGAP`
bedeutet, dass das Video später einsetzt als der Ton; bis dahin steht es auf
dem ersten Bild.

Das Video läuft **stumm**. Das ist keine Bequemlichkeit: Der Ton kommt aus
der Tondatei, und liefe die Tonspur des Videos mit, hörte man alles doppelt
und leicht versetzt.

Der Canvas mit Noten und Text liegt darüber und ist dann durchsichtig — er
legt nur einen Schleier darüber und setzt den Text mit einem Rand ab. Ohne
das verschwinden einzelne Silben in hellen Bildstellen genau dann, wenn man
sie braucht.

Ein Lied ohne Video antwortet auf `/api/song/N/video` mit **404**, nicht mit
einer leeren 200-Antwort: Der Browser fragt immer erst an und fällt genau auf
den 404 zurück; eine leere Antwort verstünde er als kaputtes Video und zeigte
gar nichts.

### Duette

Duette werden ganz gesungen, nicht nur die erste Stimme. Jede Stimme bekommt
eine eigene Bahn, eine eigene Farbe und eine eigene Wertung gegen **ihre**
Noten. Die Bahnen teilen sich die Zeitachse, damit man sieht, wann man dran
ist.

Ob ein Lied ein Duett ist, entscheidet dieselbe Regel wie in USDX: Es ist
eines, wenn schon die **erste** Zeile des Notenteils ein `P` ist. Ein
Spurwechsel mitten in einem Sololied ist in USDX ein Fehler und wird hier
ebenfalls abgelehnt — stillschweigend weiterzulesen legte die Noten in der
falschen Stimme ab. `P1`/`P 1` und `P2`/`P 2` sind erlaubt, andere Nummern
nicht. Die Namen kommen aus `#P1`/`#P2` oder den älteren
`#DUETSINGERP1`/`#DUETSINGERP2`; ohne Angabe heißen sie `P1` und `P2`.

**Jede Stimme braucht ein eigenes Mikrofon.** Zwei Menschen an einem
Mikrofon lassen sich nicht auseinanderhalten — man bekäme zweimal dieselbe
Wertung, nicht zwei. Der Aufbau lässt das deshalb gar nicht erst zu und sagt
es vorher, statt hinterher Punkte zu erklären. Ist nur ein Mikrofon da, läuft
die zweite Stimme mit, wird aber nicht gewertet; angezeigt wird dann „nicht
gewertet" und **nicht** eine 0, denn eine 0 hieße „danebengesungen".

Der Relativmodus (`#RELATIVE`) zählt den Versatz **je Stimme**
(`Rel[CurrentTrack]` in `USong.pas`). Mit einem gemeinsamen Zähler wandert
die zweite Stimme mit jeder Zeile der ersten weiter weg; ein Test hält beide
Fälle fest.

### Grenzen

- Videoformate, die der Browser nicht kennt (`.avi`, `.mpg`, `.divx`), fallen
  auf das Hintergrundbild zurück.
- Ohne Mikrofonfreigabe läuft das Lied, es wird nur nicht gewertet.
- Die Punkte bleiben im Browser und wandern nicht in die Bestenliste.
- Mehr als zwei Stimmen gibt es nicht — wie in USDX.

## Sicherheit

**Es gibt keine Anmeldung.** Wer im selben Netz ist, kann die Liederliste
sehen, Lieder auswählen und die Lieddateien herunterladen. Für ein Heimnetz
ist das gewollt — ins Internet gehört dieser Port nicht, und hinter eine
Portfreigabe erst recht nicht.

Ausgeliefert werden nur zwei Arten von Dateien:

- die Oberfläche selbst, und zwar aus einer **abschließenden Liste**
  (`WEB_DATEIEN` in `UWebApi`) statt „alles unter `web/`“;
- Lieddateien, die über ihren **Index** in der veröffentlichten Abschrift
  nachgeschlagen werden.

Aus dem Netz kommt damit nie ein Pfad, sondern immer nur eine Zahl oder ein
Name aus der Liste. Ein `../` kann also gar nicht erst irgendwo ankommen, wo
es wirken könnte. Tests in `testwebapi` und `testwebserver` halten das fest.

## Aufbau

| Unit | Aufgabe |
| --- | --- |
| `UWebBridge` | Übergabe zwischen Spiel- und Webthread, Pfade zu den Dateien |
| `UWebApi` | Wegewahl, JSON, Zuordnung Index → Datei |
| `UWebPage` | die Fernbedienung als eingebettete Zeichenkette |
| `UWebServer` | HTTP-Thread, Ausliefern der Dateien |
| `USongHeader` | Kopfdaten einer `.txt` lesen, ohne SDL |
| `USongScan` | Liederordner finden und durchsuchen, ohne SDL |
| `UWebHeadless` | der Betrieb ohne Spiel: `--web-only` |

| Datei in `web/` | Aufgabe |
| --- | --- |
| `index.html` | Seite, Liedauswahl |
| `js/song.js` | `.txt` einlesen, Spuren, Schlag ↔ Zeit |
| `js/pitch.js` | Tonhöhe aus dem Mikrofon |
| `js/score.js` | Wertung, je Stimme eine |
| `js/render.js` | Noten und Text auf Canvas, eine Bahn je Stimme |
| `js/game.js` | Schleife, Ton, Video, Mikrofone, Besetzung |

Der Webthread fasst **niemals** die Datenstrukturen des Spiels an.
`CatSongs.Song` wird beim Einlesen, Sortieren und Filtern ständig verändert;
ein Zugriff von außen läse halbfertige Zustände. Stattdessen veröffentlicht
der Spielthread eine Abschrift, und Anforderungen aus dem Netz wandern als
Befehl in eine Schlange, die der Spielthread in seiner Schleife abarbeitet.

`UWebApi` ist von `UWebServer` getrennt, damit jede Route ohne laufendes
Spiel prüfbar ist. `UWebServer` bindet aus demselben Grund **nicht** `ULog`
ein — dessen Implementierung zieht über `UMain` und `UMusic` ganz SDL herein,
und dann ließe sich der Server hier nicht mehr übersetzen. Er meldet über den
Haken `WebLogHandler`, den `UMain` ins Spielprotokoll hängt.

HTTP-Server und JSON stammen aus der FPC-Standardbibliothek
(`fphttpserver`, `fpjson`), es kommt keine Abhängigkeit dazu. Die
Weboberfläche lädt nichts aus dem Internet nach.

### Ton und Video ausliefern

Ton-, Video- und Bilddateien gehen als `ContentStream` hinaus, nicht über `AResponse.Content`:
Letzteres wird intern als Zeilenliste geführt und hängt beim Senden
Zeilenenden an — bei Text fällt das kaum auf, eine MP3 ist danach kaputt. Ein
Test schickt deshalb bewusst eine Datei mit Nullbyte, CR und LF durch und
vergleicht Byte für Byte.

`Range` wird unterstützt. Ohne das zeigt der Browser bei längeren Aufnahmen
keine Dauer an und kann nicht springen.

## API

| Weg | Zweck |
| --- | --- |
| `GET /` | die Oberfläche |
| `GET /api/status` | Anzahl Lieder, Stand der Abschrift |
| `GET /api/songs?q=&mode=&max=` | Suche, höchstens 200 Treffer; `duet` je Eintrag |
| `GET /api/select?index=N` | Lied im Spiel auswählen |
| `GET /api/song/N/txt` | die Lieddatei |
| `GET /api/song/N/audio` | die Tondatei, mit `Range` |
| `GET /api/song/N/video` | das Video, mit `Range`; 404 wenn keins |
| `GET /api/song/N/background` | das Hintergrundbild; 404 wenn keins |

## Tests

`tests/run.sh` baut das Spiel, führt die Pascal-Tests aus, startet dann
`tests/headless.sh` und zuletzt `web/tests/run.mjs` unter node.

`testwebserver` startet einen echten Server auf Port 8099 und spricht ihn
über einen rohen TCP-Anschluss an — mit einer HTTP-Bibliothek prüfte man am
Ende die Bibliothek statt den Server.

`tests/headless.sh` startet die **gebaute Binärdatei** mit `--web-only` auf
Port 8171 und ruft sie über HTTP ab. Das ist der einzige Test, der den ganzen
Weg abdeckt: Befehlszeile, Abzweigung vor `Main`, Ordnersuche, Kopfdaten,
Server, Dateien. Und er zeigt zugleich, was *nicht* passiert — liefe das
Programm doch in die Grafikinitialisierung, käme es hier gar nicht bis zur
ersten Antwort.
