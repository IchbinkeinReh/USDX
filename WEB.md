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
ultrastardx --web-only --webhost 127.0.0.1
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
- Das **Leerzeichen gehört zur Silbe**: `: 0 12 12 Bye ` heißt „Bye" mit
  folgendem Abstand. Wer die Zeile am Ende kürzt, klebt den ganzen Liedtext
  zusammen — in einer echten Datei betraf das 133 Zeilen.

Beides steht in `web/js/song.js` und wird in `web/tests/run.mjs` gegen
gerechnete Werte geprüft.

Taktgeber ist die Abspielposition des `<audio>`-Elements, **nicht** ein
Zeitgeber. Timer schwanken, und schon ein halber Schlag Versatz macht das
Singen unmöglich.

Die Tonhöhenerkennung ist **dasselbe Verfahren wie im Spiel**, portiert aus
`src/base/URecord.pas`: die zirkulare mittlere Betragsdifferenz (CAMDF) über
eine feste Tabelle von 49 Halbtönen, C2 bis C6.

```
D(τ) = 1/N · Σ |x((n+τ) mod N) − x(n)|
```

Für jeden Halbton wird die zugehörige Verschiebung geprüft, der kleinste Wert
gewinnt. Auflösung ist damit der Halbton — genau wie im Spiel, und mehr
braucht die Wertung nicht, die ohnehin in Halbtönen denkt.

**Entscheidend ist, was NICHT geprüft wird.** Der erste Entwurf benutzte
stattdessen die normierte Quadratdifferenz (McLeod/NSDF) mit einer Schranke
für die Eindeutigkeit des Fundes. Genau daran scheiterte die Erkennung im
Betrieb: An nachgebauten Aufnahmen gemessen fand das Verfahren den richtigen
Ton, verwarf ihn aber — eine Stimme über laufender Musik kam auf eine
Eindeutigkeit von 0,51, eine verrauschte auf 0,71, beides unter der Schranke.

USDX kennt so eine Schranke gar nicht. Dort entscheidet **allein die
Lautstärke**, ob ausgewertet wird; danach gibt es immer einen Ton. Das ist
großzügiger und gelegentlich falsch — aber ein gelegentlich falscher Balken
ist beim Singen deutlich besser als gar keiner. Ein Test hält fest, dass
lautes Rauschen jetzt bewusst einen Ton ergibt.

Gemessen wird die Lautstärke wie dort am **größten Betrag** im Fenster
(`MaxSampleVolume`), nicht am Effektivwert.

### Pegeln

Die Aufbereitung des Browsers ist abgeschaltet — `echoCancellation`,
`noiseSuppression` und `autoGainControl` verbiegen die Tonhöhe und sind fürs
Singen unbrauchbar. Damit fehlt aber auch die Pegelregelung, und die Pegel
gehen weit auseinander: ein Headset dicht am Mund liefert leicht das
Zehnfache eines Laptopmikrofons quer durchs Zimmer.

`pegel.js` baut sie nach — als glatter Faktor, ohne Kompression oder
Rauschunterdrückung, also ohne den Ton zu verbiegen. Betrachtet werden die
letzten **fünf Sekunden**; kürzer wäre zappelig (eine Atempause zöge den
Pegel hoch), länger zu träge.

Daraus zwei Werte, und beide werden gebraucht:

| | |
| --- | --- |
| Rauschboden (20. Rangwert) | was im Raum ohnehin klingt |
| Spitze (90. Rangwert) | wie laut gesungen wird |

Gerechnet wird in Spitzenwerten, demselben Maß wie die Lautstärkeschranke des
Spiels.

**Rangwerte, nicht Extremwerte.** Ein einmaliges Klopfen auf den Tisch würde
die Spitze sonst fünf Sekunden lang verderben und die Verstärkung
zusammenbrechen lassen.

Die Verstärkung zieht die Spitze auf `ZIEL_PEGEL = 0,20` — nicht auf 1, denn
Gesang schwankt, und wer bis an den Rand verstärkt, übersteuert bei der
nächsten lauten Stelle. Abgeschwächt wird nie; dafür ist die Erkennung nicht
der richtige Ort. Nach oben wird langsam nachgeführt, nach unten schneller:
Übersteuern soll kurz bleiben.

Der zweite Gewinn ist die **Schwelle**: Sie liegt beim 1,5-fachen des
gemessenen Rauschbodens statt bei einem festen Wert. Genau das entscheidet,
ob Gesang durchkommt — die Verstärkung allein tut das nicht, das Verfahren
ist gegen die Lautstärke unempfindlich. Der Faktor ist knapp bemessen, weil
bei laufender Musik der „Rauschboden" das Lied selbst ist: Wer mehr verlangt,
verlangt, dass der Sänger die Anlage übertönt.

Geprüft wird die Schwelle am **rohen** Signal, nicht am verstärkten. Die
Verstärkung wird gedämpft nachgezogen und hinkt dem berechneten Faktor
hinterher — man verglich sonst gegen eine Lautstärke, die noch gar nicht
anliegt, und verwarf zu viel.

Der Rohpegel wird an einem **zweiten Abgriff vor der Verstärkung** gemessen.
Am verstärkten Signal ließe sich der Faktor nicht bestimmen — man regelte
gegen die eigene Regelung.



### Liedtext

Die gerade zu hörende Silbe wird nicht nur hervorgehoben, sondern **während
des Singens von links nach rechts eingefärbt** — derselbe Effekt wie
`lfxSlide` in `ULyrics.pas`: Die Silbe wird bei ihrem Fortschritt geteilt,
links „schon gesungen", rechts „kommt noch". Der Fortschritt ist die Formel
von dort, `(Beat - Start) / Länge`, begrenzt auf 0…1. Ohne das springt die
Farbe silbenweise und man sieht nicht, wo im Wort man gerade ist.

Freestyle-Noten haben Länge 0 — ungeprüft käme dabei Unendlich heraus und die
Silbe wäre entweder ganz oder gar nicht gefärbt. `noteProgress` fängt das ab,
ein Test hält es fest.

### Was gesungen wurde

Statt einer Linie, die die Spielstelle anzeigt, stehen Balken auf der
erkannten Tonhöhe — wie `SingDrawPlayerLine` in `src/base/UDraw.pas`. Der
letzte Balken steht ohnehin genau an der Spielstelle, und zwar mitsamt der
Auskunft, ob es gesessen hat; eine zusätzliche Linie sagt nichts weiter.

**Balken gibt es nur dort, wo im Lied auch Noten stehen.** In USDX ist das
die Bedingung `ToneValid and NoteAvailable` in `UNote.pas`; hier hält der
Scorer schlicht nichts fest, solange keine wertbare Note läuft. In Pausen und
auf Freestyle-Noten bleibt es also leer.

Drei Regeln, die man beim Nachbauen verliert:

- Der gesungene Ton wird in die **Oktave der Zielnote** geholt (solange der
  Abstand größer als eine halbe Oktave ist, um zwölf verschieben). Ohne das
  läge der Balken meterweit über oder unter der Note, obwohl richtig gesungen
  wurde — wer tief singt, träfe optisch nie.
- Bei einem Treffer **rastet der Balken auf der Zielnote ein**
  (`ActualTone := Tone`). Sonst sähe ein Treffer aus wie ein knapper
  Fehlgriff, nur weil die Messung ein Achtel daneben lag.
- Ein Fehlgriff wird **flacher** gezeichnet, im Spiel 65 %. Das unterscheidet
  Treffer und Fehlgriff ohne zweite Farbe.

Aufeinanderfolgende Schläge mit demselben Ton verlängern den Balken, statt
einen zweiten danebenzusetzen — gerechnet wird in ganzen Schlägen wie im
Spiel, sonst entstünden bei jedem Bild Splitter.

Die Trefferentscheidung ist dieselbe wie bei der Wertung, damit Bild und
Punktzahl sich nicht widersprechen.

### Schwierigkeitsstufen

Wie im Spiel: `Range = 2 − Schwierigkeit` (`UNote.pas`).

| Stufe | Spielraum |
| --- | --- |
| Leicht (Voreinstellung) | zwei Halbtöne |
| Mittel | ein Halbton |
| Schwer | auf den Punkt |

**Leicht ist die Voreinstellung**, und das ist keine Bequemlichkeit: Mit
einem Raummikrofon und laufender Musik ist der Halbton auf den Punkt kaum zu
treffen, und wer nichts trifft, hört auf zu singen. Die erste Fassung wertete
fest ohne Spielraum — also auf der schwersten Stufe.

Verglichen wird **nach** der Oktavverschiebung; wer eine Oktave tiefer
mitsingt, trifft also weiterhin. Rap-Noten treffen wie im Spiel **immer** —
dort geht es um den Rhythmus, nicht um die Tonhöhe.

### Das Textband

Unten liegt ein abgedunkelter Streifen, nach oben auslaufend, damit keine
harte Kante quer durchs Bild geht. Darin stehen der Zeilenanzeiger und
**zwei Zeilen**: die aktuelle und, gedämpft darunter, die nächste — wie im
Spiel, wo man ebenfalls sieht, was als Nächstes kommt.

Beide Zeilen sind weiß; die nächste wird über die kleinere Schrift abgesetzt,
nicht über blasse Farbe — man liest sie im Voraus, um vorbereitet zu sein,
und dafür muss sie gut lesbar sein.

Abgedunkelt wird immer, nicht nur über Video: Auch die Notenfläche ist
unruhig genug, dass Text darauf schlecht zu lesen ist. Passt eine Zeile nicht
in die Breite, wird sie gestaucht statt abgeschnitten — eine halbe Silbe am
Rand hilft niemandem.

### Wann die Zeile losgeht

Vor dem Einsatz fährt ein Balken von links auf den Anfang des Liedtextes zu
und ist genau dann dort, wenn die erste Note fällig ist. Dabei pulsiert er im
Takt.

Das ist `SingDrawLyricHelper` aus `src/base/UDraw.pas`, portiert samt seiner
Regeln — die sind in **Schlägen** gemessen, nicht in Sekunden, und passen
sich damit dem Tempo des Liedes an:

| Wert im Spiel | Bedeutung |
| --- | --- |
| `FirstNoteDelta > 8` | erst ab so viel Vorlauf erscheint er überhaupt |
| `BarMoveLimit = 40` | ab so viel Wartezeit bleibt er zunächst links stehen |
| `BarProgress = 1 - BarMoveDelta / FirstNoteDelta` | wo er steht |
| `BarAlpha = 0,75 + cos(BarMoveDelta/2) · 0,25` | das Pulsieren |

Zwei Feinheiten, die man beim Nachbauen verliert: Bei kurzen Pausen zwischen
zwei Zeilen erscheint er **gar nicht** — er wäre nur ein Zucken und störte
mehr, als er hilft. Und das Pulsieren rechnet mit dem *ungekürzten* Rest, weil
es am Takt hängt und nicht am Weg des Balkens.

Gezeichnet wird in **CSS-Punkten**, nicht in Gerätepunkten: `passeGroesseAn`
vergrößert den Canvas um `devicePixelRatio` und rechnet den Kontext
entsprechend um. Ohne das bedeutet jedes feste Maß hier etwas anderes je
Gerät — auf einem Handy mit dreifacher Auflösung wären eine Schriftgröße von
24 acht CSS-Punkte und der Anzeiger ein Haarstrich von drei. Genau daran war
er zunächst nicht zu sehen.

Der Anzeiger sitzt **auf der Höhe der ersten Textzeile** und wird **vor** dem
Text gezeichnet: Er zeigt auf den Punkt, an dem der Text anfängt, und das
liest sich nur, wenn beide auf einer Linie liegen. Füllt eine Zeile fast die
ganze Breite, überlappen beide — dann steht der Text obenauf und bleibt
lesbar. Im Spiel fährt er bis kurz vor den Textanfang; bei mittig gesetztem,
breitem Text bleibt links davon aber kein Platz, und dann landet er außerhalb
des Bildes — genau daran war er zunächst nicht zu sehen. Ziel bleibt der
Textanfang, nur nie näher als ein Mindestweg. `helferBahn` rechnet das, und
Tests prüfen es für Textbreiten bis über die Bildbreite hinaus.

Die Größe ist angepasst: Im Spiel sind es feste 50 × 30 in einem
800 × 600-Raster, was hier nichts hieße.

Dazu gehört, welche Zeile überhaupt gilt: Ist eine Zeile ausgesungen, wird
sofort auf die nächste umgeschaltet, auch wenn deren Einsatz noch bevorsteht.
Nähme man schlicht „die letzte, die begonnen hat", bliebe der ausgesungene
Text stehen und der Anzeiger zeigte auf einen Einsatz, der längst vorbei ist.
Weil dadurch — anders als im Spiel — der Balken kurz vor seinem Startpunkt
liegen kann, wird der Fortschritt auf 0…1 begrenzt.

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

### Zwei Schritte

Erst das Lied wählen, dann singen. Dazwischen liegt die Zuordnung der
Mikrofone — die braucht Ruhe und Platz, und auf der Bühne ist beides weg.

Gestartet wird **nicht automatisch**: Auf der Bühne liegt ein „Los geht's".
Der Browser blendet beim Wechsel ins Vollbild unten einen Hinweis ein, der
genau über dem Liedtext liegt; er verschwindet nach ein paar Sekunden von
selbst, und bis dahin wartet man.

Auf dem **Handy** wird beim Wechsel Vollbild angefordert und, wenn möglich,
das Querformat festgehalten; am Ende des Liedes wird beides wieder gelöst.
Im Hochformat bleiben je Notenzeile ein paar Zentimeter, auf denen weder
Noten noch Text zu erkennen sind.

Beides muss **aus der Klickbehandlung heraus** angefordert werden — später
fehlt die Nutzergeste und der Browser lehnt ab. Und beides ist abgesichert,
nichts davon ist Voraussetzung: Klappt es nicht, wird trotzdem gesungen, nur
eben im Fenster. Lässt sich das Drehen nicht festhalten, erscheint stattdessen
ein Hinweis, das Gerät quer zu halten.

Was wo geht:

| | Vollbild | Querformat festhalten |
| --- | --- | --- |
| Chrome/Firefox auf Android | ja | ja |
| Safari auf dem iPhone | nein — nur für Videos | nein — API fehlt |
| Rechner | ja, wird aber nicht erzwungen | — |

Erkannt wird das Gerät **nicht an der Browserkennung** — die lügen seit
jeher — sondern an grobem Zeiger (Finger statt Maus) und kleiner
Bildschirmseite. Tablets sind bewusst ausgenommen (`HANDY_BREITE = 540`):
Dort ist genug Platz, und ein erzwungenes Vollbild stört mehr, als es hilft.

### Grenzen

- Videoformate, die der Browser nicht kennt (`.avi`, `.mpg`, `.divx`), fallen
  auf das Hintergrundbild zurück.
- Ohne Mikrofonfreigabe läuft das Lied, es wird nur nicht gewertet.
- Die Punkte bleiben im Browser und wandern nicht in die Bestenliste.
- Mehr als zwei Stimmen gibt es nicht — wie in USDX.

## Sicherheit

**Es gibt keine Anmeldung.** Wer den Port erreicht, kann die Liederliste
sehen, Lieder auswählen und alle Lied-, Ton- und Videodateien herunterladen.
Für ein Heimnetz ist das gewollt — offen ins Internet gehört dieser Port
nicht.

Soll er doch von außen erreichbar sein, gehört ein Vorschalt-Server davor,
der die Anmeldung prüft. Dann **muss** `--webhost 127.0.0.1` gesetzt sein:
Ohne das lauscht der Dienst auf allen Adressen, der Port ist am
Vorschalt-Server vorbei direkt erreichbar, und die Anmeldung ist wertlos.
`tests/headless.sh` prüft die Bindung mit.

Ausgeliefert werden nur zwei Arten von Dateien:

- die Oberfläche selbst, und zwar aus einer **abschließenden Liste**
  (`WEB_DATEIEN` in `UWebApi`) statt „alles unter `web/`“;
- Lieddateien, die über ihren **Index** in der veröffentlichten Abschrift
  nachgeschlagen werden.

Aus dem Netz kommt damit nie ein Pfad, sondern immer nur eine Zahl oder ein
Name aus der Liste. Ein `../` kann also gar nicht erst irgendwo ankommen, wo
es wirken könnte. Tests in `testwebapi` und `testwebserver` halten das fest.

## Hinter einem Vorschalt-Server betreiben

Soll die Oberfläche von außen erreichbar sein, gehört ein Server davor, der
die Anmeldung prüft. Der Dienst selbst kennt keine.

**HTTPS ist dabei Pflicht, nicht Kür.** `getUserMedia` gibt es nur im
sicheren Kontext — über einfaches HTTP lädt die Seite zwar, aber das
Mikrofon bleibt stumm und es lässt sich nichts werten.

Als systemd-Dienst:

```ini
[Service]
User=ultrastar
ExecStart=/usr/local/lib/ultrastar-web/ultrastardx --web-only \
    --webhost 127.0.0.1 --webport 8942 --songpath /pfad/zu/den/liedern
ProtectSystem=strict
ProtectHome=read-only
ReadOnlyPaths=/pfad/zu/den/liedern
```

Und davor, hier mit Apache:

```apache
<VirtualHost *:443>
	ServerName ultrastar.example.org

	ProxyPreserveHost On
	ProxyPass        "/" "http://127.0.0.1:8942/" timeout=60
	ProxyPassReverse "/" "http://127.0.0.1:8942/"

	<Location "/">
		AuthType Basic
		AuthName "UltraStar"
		AuthUserFile /etc/apache2/auth/ultrastar.htpasswd
		Require valid-user
	</Location>
</VirtualHost>
```

Zwei Dinge, die dabei leicht untergehen:

- `--webhost 127.0.0.1` ist der eigentliche Schutz. Fehlt es, lauscht der
  Dienst auf allen Adressen und der Port ist an der Anmeldung vorbei direkt
  erreichbar.
- Die Anmeldung gehört an `/`, nicht nur an die Startseite. Sonst sind
  `/api/songs` und die Lieddateien offen — und darüber lässt sich die ganze
  Sammlung herunterladen.

Ein `Range` reicht Apache unverändert durch; das Springen im Lied
funktioniert also auch über den Proxy.

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

Eine Antwort legt höchstens **8 MB** auf einmal in den Speicher
(`WEB_MAX_STUECK`). Ein Lied bringt schnell ein paar hundert MB Video mit;
würde davon jede Anfrage alles auf einmal einlesen, könnte eine Handvoll
gleichzeitiger Zugriffe den Rechner leerräumen — bei einer von außen
erreichbaren Oberfläche ein Hebel, an dem jeder ziehen kann. Wird mehr
angefordert, antwortet der Server mit weniger und sagt das über
`Content-Range`; das ist erlaubt (RFC 7233) und die übliche Arbeitsweise beim
Streamen. Der Browser holt sich den Rest mit der nächsten Anfrage.

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
