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

Gelesen wird über einen **Datenstrom**, nicht über `TextFile`. FPC legt den
Dateinamen eines `TextFile` in einem `array[0..255] of char` ab; ein längerer
Pfad passt dort nicht hinein und `Reset` scheitert — lautlos, denn die Datei
ist ja lesbar. In der Sammlung hier betraf das genau die sechs Lieder mit
Pfaden ab 257 Zeichen, meist lange Interpretennamen aus Film-Soundtracks. Sie
fehlten ohne jede Meldung.

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

Die Note selbst wird **nicht** anteilig eingefärbt. Das war sie einmal, und
zwar mit dem Verhältnis Treffer zu Versuchen — ein Verhältnis, das sinken
kann: Wer erst traf und dann danebenlag, sah den Balken schrumpfen, obwohl er
weitersang. Was tatsächlich gesungen wurde, zeigen die Balken, und die
wachsen nur.

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

Ein abgedunkelter Streifen, nach oben auslaufend, damit keine harte Kante
quer durchs Bild geht. Darin stehen der Zeilenanzeiger und **zwei Zeilen**:
die aktuelle und, gedämpft darunter, die nächste — wie im Spiel, wo man
ebenfalls sieht, was als Nächstes kommt.

Wo es liegt, hängt davon ab, ob zwei verschiedene Texte gesungen werden:

- **Kein Duett** — auch wenn zwei Menschen mitsingen: Der Text steht **einmal
  unten**. Zweimal derselbe Text wäre nur Platzverschwendung.
- **Duett** — jede Stimme bekommt ihren eigenen: der oberen **über** ihre
  Noten, der unteren darunter. So liegen die Texte außen und die Notenflächen
  in der Mitte beieinander; dieselbe Aufteilung wie im Spiel, wo die
  Textleisten oben und unten sitzen.

Auf der Bühne gibt es **keine Fußzeile** und keine Punktzahl in der
Kopfleiste — beides nahm Platz weg, den die Noten brauchen. Die Punktzahl
steht in der Bahn, der Name daneben nur dann, wenn es mehrere Bahnen gibt.
Ein Hinweis oder das Ergebnis blendet sich nur ein, wenn es etwas zu sagen
gibt.

Beide Zeilen sind weiß; die nächste wird über die kleinere Schrift abgesetzt,
nicht über blasse Farbe — man liest sie im Voraus, um vorbereitet zu sein,
und dafür muss sie gut lesbar sein.

Abgedunkelt wird immer, nicht nur über Video: Auch die Notenfläche ist
unruhig genug, dass Text darauf schlecht zu lesen ist. Passt eine Zeile nicht
in die Breite, wird sie gestaucht statt abgeschnitten — eine halbe Silbe am
Rand hilft niemandem.

### Wenn niemand gewertet wird

Hat keiner der Sänger ein Mikrofon, bleiben Notenlinien und Balken weg: Es
kann nichts getroffen und nichts verfehlt werden, die Fläche gehört dann
Text und Video. Sobald **auch nur einer** gewertet wird, sind sie wieder da.

### Spulen

Doppeltippen springt fünf Sekunden — links zurück, rechts vor. Erkannt wird
der Doppeltipp selbst statt über `dblclick`: Auf Berührbildschirmen kommt der
spät oder gar nicht.

Angezeigt wird dabei nichts. Ein eingeblendetes Zeichen legte sich über das
Bild und verdeckte genau das, wohin man gerade springt — dass der Sprung
angekommen ist, sieht man ohnehin am Fortschrittsbalken und am Liedtext.

Die Wertung zieht mit. Übersprungene Zeilen werden beim nächsten Bild als
beendet verbucht und bringen keinen Bonus — was richtig ist, gesungen wurde
dort nichts. Zurückgespulte Zeilen bleiben verbucht; ihren Bonus gibt es kein
zweites Mal.

### Der Fortschrittsbalken

Am unteren Rand liegt eine Leiste über die ganze Länge des Liedes, nachgebaut
nach `DrawInfoLyricBar` (`UScreenSingView.pas`): darin je Zeile ein Kästchen
von der ersten Note bis zum Ende der letzten. Man sieht damit auf einen Blick,
**wann gesungen wird und wann Pause ist** — und wie lange es noch dauert.

Das bereits Gesungene wird abgedunkelt, nicht nur die Marke gesetzt: Sonst
ließe sich der Fortschritt nicht ablesen, wenn die Marke gerade in einer
Pause steht. Die Leiste ist bewusst schmal — sie soll ablesbar sein, nicht
auffallen.

Beim Duett kommen die Abschnitte beider Stimmen zusammen; dass sie sich
teils überschneiden, stört beim Zeichnen nicht.

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
läuft es; sonst steht das Hintergrundbild aus `#BACKGROUND`; sonst — eine
Erweiterung gegenüber dem Original — das Titelbild aus `#COVER`, falls eines
da ist; sonst bleibt es dunkel. Alle drei werden geladen, in dieser
Reihenfolge als **Rückfall**, nicht als zweite Wahl.

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

### Zu zweit

Auch bei einem **Sololied** können zwei Menschen mitsingen. Dann singen beide
dieselbe Spur und werden getrennt gewertet — wie im Spiel. Jeder bekommt
seine eigene Bahn, seine eigene Farbe und seine eigenen Balken.

Der zweite Platz ist freiwillig und bleibt vorbelegt leer. Ohne Mikrofon
bekommt er gar keine Bahn: Eine zweite, stumme Anzeige derselben Noten wäre
nur Platzverschwendung. Beim Duett ist das anders — dort gehören beide
Stimmen zum Lied und werden auch dann gezeigt, wenn eine ungewertet
mitläuft.

Weil beide Bahnen bei einem Sololied denselben Spurnamen trügen, kommt die
Beschriftung in diesem Fall aus der Zuordnung („Sänger 1"/„Sänger 2") statt
aus dem Lied.

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

### Drei Schritte

Lied wählen, singen, Ergebnis. Dazwischen liegt die Zuordnung der
Mikrofone — die braucht Ruhe und Platz, und auf der Bühne ist beides weg.

### Die Ergebnisseite

Sie erscheint am Ende des Liedes **und** wenn das Vollbild verlassen wird —
wer es verlässt, will aufhören, und dann soll das Ergebnis kommen statt das
Lied im Fenster weiterzulaufen. „Zurück" bricht dagegen ohne Ergebnis ab.

Die Seite zeigt, wie gut es war — je Sänger eine Karte mit
Punktzahl, Bewertung und Sternen. Die Punktzahl zählt hoch, wie im Spiel.

Stufen und Schwellen sind aus `ShowRating` in `src/screens/UScreenScore.pas`
übernommen, die Bezeichnungen aus `game/languages/German.ini`:

| Punkte | Stufe |
| --- | --- |
| 0–2009 | Nichtskönner |
| 2010–4009 | Amateur |
| 4010–5009 | Möchtegern |
| 5010–6009 | Fortgeschritten |
| 6010–7509 | Sternchen |
| 7510–8509 | Hit-Künstler |
| 8510–9009 | Superstar |
| 9010–10000 | UltraStar |

Die Grenzen sind krumm, weil sie es im Original sind; ein glattes Nachbauen
hätte die Stufen verschoben. Tests prüfen jede Grenze von beiden Seiten.

Aufgeschlüsselt wird nach gewöhnlichen Noten, goldenen Noten und
Zeilenbonus — dieselbe Dreiteilung wie im Spiel.

### Zeilenbonus

Von den 10000 Punkten sind **1000 für den Zeilenbonus** reserviert; aus den
Noten kommen höchstens 9000 (`MAX_SONG_SCORE`, `MAX_SONG_LINE_BONUS` in
`UNote.pas`). Gerechnet wird wie in `UScreenSingController.pas`:

```
MaxLineScore   = 9000 · (Zeilenwert / Gesamtwert)
LineScore      = seit der letzten Zeile erreichte Punkte
LinePerfection = LineScore / (MaxLineScore − 2),  begrenzt auf 0…1
ScoreLine     += LineBonus · LinePerfection
```

Der Bonus je Zeile ist **für jede Zeile gleich groß**, egal wie lang sie ist:
`1000 / Anzahl Zeilen mit Noten`. Wer eine kurze Zeile trifft, bekommt also
genauso viel wie für eine lange.

Die zwei Punkte Nachlass in `MaxLineScore − 2` sind im Original ausdrücklich
als kleine Zugabe gedacht, damit man für die volle Stufe nicht ganz perfekt
sein muss — deshalb hier ebenso.

Zeilen **ohne** wertbare Noten zählen nicht mit. Im Spiel werden sie
übersprungen (`Line.ScoreValue <= 0`), und sie dürfen den Bonus je Zeile
nicht verwässern.

Gutgeschrieben wird beim **Ende** der Zeile, nicht währenddessen.

### Bewertung je Zeile

Nach jeder Zeile blendet sich kurz ein Urteil ein — das Popup des Spiels.
`Rating = round(LinePerfection · 8)`, die Bezeichnungen aus `German.ini`:

| Stufe | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| | Grausam! | Grausam! | Mies! | Schlecht! | O.K.! | Gut! | Toll! | Cool! | Perfekt! |

Dass Stufe 1 denselben Text hat wie Stufe 0, ist kein Versehen: So steht es
in `UThemes.pas` (`LineBonusText[1] := LineBonusText[0]`).

Gestartet wird **nicht automatisch**: Auf der Bühne liegt ein „Los geht's".
Der Browser blendet beim Wechsel ins Vollbild unten einen Hinweis ein, der
genau über dem Liedtext liegt; er verschwindet nach ein paar Sekunden von
selbst, und bis dahin wartet man.

Vollbild wird auf **jedem** Gerät angefordert; das Festhalten des Querformats
ist eine Handysache. Im Vollbild fällt die Kopfleiste weg — dort zählt jeder
Millimeter für die Noten. Herauskommt man mit Escape oder der Zurück-Geste,
danach ist sie wieder da. Am Ende des Liedes wird das Vollbild von selbst
verlassen, wenn die Ergebnisseite erscheint.
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
sehen und Lieder auswählen. Ton, Video und Noten gehen nur verschlüsselt und
nur gegen eine Sitzung heraus (siehe unten) — das ist eine Hürde, keine
Mauer. Für ein Heimnetz ist das gewollt; offen ins Internet gehört dieser
Port nicht.

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

### Lieddateien werden verschlüsselt ausgeliefert

Ton, Video und Noten (`/api/song/N/audio`, `/video`, `/txt`) gehen **nur
verschlüsselt** hinaus und **nur gegen eine Sitzung**. Ohne `?sid=` kommt
403 — es gibt bewusst keinen Rückfall auf die offene Datei, sonst genügte
das Weglassen des Parameters.

Der Grund: Vorher lag hinter `/api/song/N/audio` eine fertige MP3. Wer die
Adresse kannte, lud mit einer Zeile `wget` die ganze Sammlung herunter; die
Anmeldung am Vorschalt-Server schützt die Liste, nicht die Dateien dahinter,
sobald ein Zugang einmal vergeben ist.

**Was das nicht leistet:** Der Browser muss den Schlüssel haben, sonst könnte
er nichts abspielen — `POST /api/session` gibt ihn heraus. Wer die
Entwicklerwerkzeuge aufmacht, kommt also heran. Das Ziel ist die Hürde, nicht
die Unmöglichkeit: aus „Adresse aufrufen" wird „Sitzung anfordern, ChaCha20
nachbauen, den Strom je Datei richtig aufsetzen".

Titelbilder und Hintergründe bleiben **offen**. Sie hängen in der Liste an
tausenden `<img>`-Elementen; die über den Dienstarbeiter zu schleusen würde
das Blättern durch neuntausend Lieder zäh machen — für Dateien, die niemand
herunterladen will.

#### Warum ChaCha20 und warum ein Stromverfahren

FPC 3.2.2 bringt kein brauchbares AES mit (`blowfish` ist alles, was in
`fcl-base` steht), und eine weitere Bibliothek wollen wir hier so wenig wie
den HTTP-Server oder das JSON. ChaCha20 ist in hundert Zeilen vollständig
hinzuschreiben — im Server (`UWebCrypto`) wie im Browser (`web/js/krypto.js`).

Entscheidend ist aber die **Betriebsart**: Bei einem Stromverfahren hängt das
Byte an Stelle N nur von N ab, von keinem anderen Byte. Damit bleibt `Range`
genau so, wie es war — der Server verschlüsselt ab Stelle N weiter, ohne dass
der Browser je den Anfang der Datei gesehen haben muss, und die Länge ändert
sich nicht, also stimmen `Content-Length` und `Content-Range` weiterhin. Mit
CBC oder ähnlichem wäre Springen im Lied nicht mehr möglich, und ohne Springen
gibt es weder Dauer-Anzeige noch Vorschau ab der Mitte.

Der Einmalwert wird **nicht übertragen**, sondern auf beiden Seiten aus
Liednummer und Dateiart gerechnet (`NonceForFile` / `nonceForFile`). Er muss
je Schlüssel eindeutig sein, geheim muss er nicht sein. Dass Ton und Noten
desselben Liedes verschiedene bekommen, ist wichtig: Sonst verriete der
bekannte Klartext einer `.txt` den Strom für die Tondatei daneben.

Die Schlüssel kommen aus `/dev/urandom` bzw. der CryptoAPI — ausdrücklich
**nicht** aus `Random()`. Das ist ein Mersenne-Twister mit der Uhrzeit
angestoßen; für einen Lobby-Code recht, als Schlüssel in Minuten
durchprobiert. Lässt sich keine Quelle öffnen, fliegt eine Ausnahme: lieber
keine Sitzung als eine mit vorhersagbarem Schlüssel.

Eine Sitzung gilt eine Stunde, jeder Zugriff verlängert sie (ein Lied kann
länger dauern als die Frist, und mitten im Refrain den Ton zu verlieren wäre
die ärgerlichste Art abzulaufen). Sie leben nur im Speicher des Servers; ein
Neustart macht alle ausgegebenen Schlüssel ungültig.

#### Warum ein Dienstarbeiter (Service Worker)

Taktgeber des ganzen Spiels ist die Abspielposition des `<audio>`-Elements.
Daran hängen Springen, Dauer, Pause und der Gleichlauf in der Lobby. Würde
die Seite den Ton selbst entschlüsseln, müsste sie ihn auch selbst abspielen
— und damit fiele genau dieser Taktgeber weg.

`web/sw.js` fängt die Anfrage stattdessen ab, holt die verschlüsselten Bytes,
entschlüsselt sie **stückweise im Durchlauf** (`TransformStream`) und gibt
eine ganz gewöhnliche Tonantwort zurück. `<audio>.src` zeigt weiter auf
`/api/song/N/audio`, das Element merkt nichts davon, und das ganze Lied liegt
nie am Stück im Speicher. Woher ein Stück kommt, steht in `Content-Range` der
**Antwort** — nicht in der Anfrage, denn der Server darf weniger schicken als
gefragt (siehe `WEB_MAX_STUECK`).

Der Dienstarbeiter liegt an der **Wurzel** (`/sw.js`), nicht unter `js/`: Sein
Geltungsbereich reicht nur so weit wie sein eigener Ordner, von `/js/` aus
sähe er `/api/song/…` gar nicht.

Der Schlüssel liegt nur im Speicher des Dienstarbeiters. Der Browser darf ihn
jederzeit beenden und neu starten — dann fragt er bei der Seite nach
(`schluessel-bitte`), statt stumm Rauschen durchzureichen.

**Ohne sicheren Kontext geht nichts.** Dienstarbeiter gibt es nur über HTTPS
(oder auf `localhost`). Das ist keine neue Einschränkung: `getUserMedia`
verlangt denselben sicheren Kontext, über einfaches HTTP bliebe das Mikrofon
ohnehin stumm und es ließe sich nichts werten. Die Seite sagt es an, statt
das Lied stumm scheitern zu lassen; die Liederliste bleibt bedienbar, damit
sich am Gerät weiterhin ein Lied auswählen lässt.

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

# Wohin gezählt wird. systemd legt /var/lib/ultrastar-web an und gibt den
# Ordner als $STATE_DIRECTORY mit; der Dienst findet ihn von selbst. Ohne
# das landete die Zählung in ~/.ultrastardx, und das ist wegen
# ProtectHome=read-only nicht beschreibbar.
StateDirectory=ultrastar-web

# Beschreibbar, NICHT ReadOnlyPaths: Die Vorschau-Schnipsel werden beim
# Start neben die Tondateien geschnitten. Bleibt der Ordner nur lesbar,
# entsteht kein einziger und die Liedauswahl bleibt stumm.
ReadWritePaths=/pfad/zu/den/liedern

# Damit der Eigentümer der Sammlung die erzeugten Schnipsel noch lesen kann.
UMask=0027

# Während des Bauens läuft ein ffmpeg daneben und zählt in dieselbe
# Speichergruppe.
MemoryMax=2048M
```

Und der Dienstbenutzer muss in die Liederordner schreiben dürfen. Wenn er
bereits in der Gruppe des Sammlungsbesitzers ist (`SupplementaryGroups=`),
genügt Schreibrecht für die Gruppe — **nur auf den Ordnern**, die Lieder
selbst werden nicht angefasst:

```sh
find /pfad/zu/den/liedern -type d -exec chmod g+ws {} +
```

Das `s` ist das setgid-Bit: Neu erzeugte Schnipsel erben damit die Gruppe des
Ordners, und zusammen mit `UMask=0027` bleiben sie für die Gruppe lesbar.

Wer die Sammlung unangetastet lassen will, kann das — dann gibt es eben keine
Vorschau. Der Dienst sagt es beim Start und läuft normal weiter.

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

	# Diese beiden MUESSEN ohne Anmeldung ladbar sein - siehe unten.
	<Location "/sw.js">
		Require all granted
	</Location>
	<Location "/js/krypto.js">
		Require all granted
	</Location>
</VirtualHost>
```

### Der Dienstarbeiter darf nicht hinter der Anmeldung stehen

Die zwei `Require all granted` oben sind kein Schönheitsfehler, sondern
Bedingung. `navigator.serviceWorker.register(…, { type: 'module' })` holt das
Worker-Skript **ohne Zugangsdaten** — anders als bei einem klassischen
Worker, wo der Browser sie mitschickt. Steht die Anmeldung davor, antwortet
der Vorschalt-Server mit **401**, der Dienstarbeiter wird nie angemeldet, und
weil Ton, Video und Noten nur verschlüsselt herausgehen, kommt danach auf
jede Lieddatei ein **403**.

Im Browser sieht das nicht nach einem Rechteproblem aus, sondern nach einem
kaputten Lied: *„Lied lässt sich nicht laden"*. Die Titelbilder laden weiter,
weil sie gar nicht verschlüsselt sind — die Liste wirkt also halb lebendig.
Genau so ist es im Betrieb passiert. Im Zugriffsprotokoll steht es
unmissverständlich:

```
200  GET  /js/sitzung.js     aus der Seite heraus: Zugangsdaten dabei
200  POST /api/session
401  GET  /sw.js             als Worker-Skript: keine Zugangsdaten
403  GET  /api/song/2/txt    also fehlt danach ueberall die Sitzung
```

Preisgegeben wird durch die Ausnahme nichts: In beiden Dateien stehen nur
ChaCha20 und die Wegewahl, kein Schlüssel. Die Lieder bleiben hinter der
Anmeldung — und zusätzlich hinter der Sitzung, die es nur über
`/api/session` gibt. Die eigenen Abrufe des Dienstarbeiters tragen die
Zugangsdaten übrigens weiterhin; nachgemessen mit einem
Basic-Auth-Vorschaltserver davor.

Wer das nicht will, muss den Dienstarbeiter als **klassisches** Skript
anmelden statt als Modul — dann schickt der Browser die Zugangsdaten von
selbst. Das setzt voraus, dass `js/krypto.js` ohne ES-Module auskommt, und
die Tests laden es genau so.

Alle Adressen im Browser werden gegen eine **bereinigte Basis** aufgelöst.
Wer die Seite mit Zugangsdaten in der Adresse aufruft — also
`https://name:wort@rechner/` —, vererbt sie sonst an jede relative Adresse,
und Chrome verweigert dann sowohl `fetch` als auch das Laden von Ton, Video
und Bild: *„Request cannot be constructed from a URL that includes
credentials."* Die Seite bleibt dabei leer.

Der Dienst setzt an jede Antwort **`Connection: close`**. Er kann keine
Wiederverwendung, und sagt er das nicht dazu, gilt bei HTTP/1.1 das
Gegenteil: Der Vorschalt-Server legt die Verbindung in seinen Vorrat,
schreibt beim nächsten Mal in einen längst geschlossenen Anschluss und meldet
dem Browser einen Serverfehler. Genau das ist im Betrieb passiert —
vereinzelte 500er beim Laden der Seite, im Apache-Protokoll
`AH01102: error reading status line from remote server`.

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
| `UWebCrypto` | ChaCha20 und die Sitzungsschlüssel |
| `UWebVorschau` | Vorschau-Schnipsel schneiden (ffmpeg) |
| `UWebZaehler` | wann welches Lied gesungen wurde |
| `UWebApi` | Wegewahl, JSON, Zuordnung Index → Datei |
| `UWebPage` | die Fernbedienung als eingebettete Zeichenkette |
| `UWebServer` | HTTP-Thread, Ausliefern der Dateien |
| `USongHeader` | Kopfdaten einer `.txt` lesen, ohne SDL |
| `USongScan` | Liederordner finden und durchsuchen, ohne SDL |
| `UWebHeadless` | der Betrieb ohne Spiel: `--web-only` |

| Datei in `web/` | Aufgabe |
| --- | --- |
| `index.html` | Seite, Liedauswahl |
| `sw.js` | Dienstarbeiter: entschlüsselt Lieddateien im Durchlauf |
| `js/krypto.js` | ChaCha20 im Browser, Einmalwerte, geschützte Adressen |
| `js/sitzung.js` | Sitzung holen, Dienstarbeiter aufstellen |
| `js/song.js` | `.txt` einlesen, Spuren, Schlag ↔ Zeit |
| `js/pitch.js` | Tonhöhe aus dem Mikrofon |
| `js/score.js` | Wertung, je Stimme eine |
| `js/render.js` | Noten und Text auf Canvas, eine Bahn je Stimme |
| `js/game.js` | Schleife, Ton, Video, Mikrofone, Besetzung |

### Reihenfolge und Nachladen

Die Liste ist **alphabetisch nach Interpret und Titel** sortiert, einmal beim
Veröffentlichen. Sortiert wird über die schon umgeschriebenen Suchtexte,
damit „Ärzte" bei „Arzte" steht und nicht hinter „Z" — und damit die
Reihenfolge nicht von der Spracheinstellung des Rechners abhängt. Bei
gleichem Namen entscheidet die ursprüngliche Stelle, damit die Reihenfolge
zwischen zwei Läufen gleich bleibt.

Die Auswahl der Mikrofone liegt als **feste Leiste** am unteren Rand, sobald
ein Lied angetippt wurde. Vorher stand sie hinter der Liederliste — und weil
beim Blättern ständig Lieder nachgeladen werden, rutschte sie sofort wieder
aus dem Bild. Ein Platzhalter hält unten den Raum frei, den die Leiste
verdeckt, damit die letzten Lieder erreichbar bleiben.

Geholt wird **seitenweise**: `GET /api/songs?…&offset=N` überspringt die
ersten N **Treffer** (nicht Lieder). Die Oberfläche lädt 60 auf einmal und
hängt nach, sobald das Ende in Sicht kommt. Bei über neuntausend Liedern
ginge es anders nicht: Der Server liefert höchstens 200 auf einmal, und der
Browser hätte an tausenden Zeilen zu bauen.

Zwei Feinheiten, ohne die es hakt: Jede Suche bekommt eine Nummer, damit eine
verspätete Antwort einer alten Suche verworfen wird statt sich unter die
neuen Treffer zu mischen. Und füllt eine Seite den Bildschirm noch nicht,
wird sofort weitergeladen — sonst gäbe es nichts zu blättern und das
Nachladen käme nie in Gang.

Der `index` eines Liedes zeigt auf seine Stelle in dieser sortierten Liste;
über ihn werden die Dateien nachgeschlagen. Was das **Spiel** zum Auswählen
braucht, steht getrennt in `SelectIndex`. Vorher war beides dasselbe Feld —
sobald die Liederliste des Spiels Kategorieüberschriften enthielt, zeigten
Dateiabruf und Auswahl damit auf verschiedene Lieder.

### Titelbilder in der Liste

Jede Zeile zeigt das Cover aus `#COVER`, sofern eines hinterlegt ist. Ob das
der Fall ist, steht als `cover` in der Liste — sonst müsste die Oberfläche es
bei jedem Lied auf gut Glück anfordern, und bei neuntausend Einträgen wären
das tausende Fehlanfragen.

Geladen wird mit `loading="lazy"`: Der Browser holt nur, was tatsächlich zu
sehen ist. Das ist keine Feinheit — die Bilder sind im Median **249 KB** groß,
das größte in dieser Sammlung 4,7 MB. Ohne das lüde eine Seite von sechzig
Einträgen rund 14 MB.

Der Platz für das Bild steht fest, auch bevor es da ist. Sonst springt die
Liste beim Nachladen und die Zeile rutscht einem unter dem Finger weg.

Lieddateien werden mit `Cache-Control: public, max-age=86400` ausgeliefert,
die Oberfläche dagegen mit `no-cache`. Ohne das holte der Browser jedes
Titelbild beim Zurückblättern erneut; mit einem Cache auf der Oberfläche
liefe nach einer Aktualisierung tagelang die alte Fassung weiter.

### Das Suchregister

Die Suchtexte werden **beim Veröffentlichen** vorbereitet — kleingeschrieben
und ins ASCII-Alphabet umgeschrieben —, nicht bei jeder Anfrage. Bei zwanzig
Liedern fällt der Unterschied nicht auf; bei über neuntausend kostete eine
Suche, die wenig trifft, dreiviertel Sekunden, und beim Tippen merkt man jede
davon. Gemessen an 9146 Liedern: **0,75 s → 0,06 s**.

Das Register liegt **neben** der Liederliste, nicht in `TWebSong`: Das Lied
ist, was die Weboberfläche zu sehen bekommt, das Register ist eine interne
Angelegenheit der Brücke. So bleiben auch die Kopien klein, die `FindSongs`
zurückgibt.

Der Fehler, der dabei droht, ist ein Register, das noch zur alten Liste
gehört — dann fände man Lieder, die es nicht mehr gibt, und die neuen nicht.
`PublishSongs` baut deshalb beides in einem Zug auf; ein Test veröffentlicht
zweimal und prüft, dass die alten Treffer verschwinden.

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

## Vorschau in der Liedauswahl

Die Vorschau hat einen **eigenen Endpunkt** und eine **eigene Datei**:
`/api/song/N/preview` liefert einen fertig geschnittenen Schnipsel von
höchstens **30 Sekunden**, verschlüsselt wie alles andere.

### Warum eine eigene Datei und kein Stück aus dem Lied

Weil sich ein MP4 **nicht byteweise schneiden lässt** — und die Sammlung hier
besteht praktisch vollständig aus `.m4a`. Nachgemessen in Chrome:

| ausgeliefert | spielt |
| --- | --- |
| MP3 ganz | ja |
| **MP3 Stück aus der Mitte** | ja, meldet sogar die richtige Dauer |
| MP3 vorne abgeschnitten | ja |
| M4A ganz | ja |
| **M4A Stück aus der Mitte** | nein, `MEDIA_ERR_SRC_NOT_SUPPORTED` |
| M4A vorne abgeschnitten | nein, dasselbe |
| M4A faststart, Stück aus der Mitte | nein, dasselbe |
| M4A faststart, vorne abgeschnitten | ja, behauptet aber die volle Dauer |

MP3 ist rahmenweise aufgebaut, ein Decoder findet überall wieder hinein. Ein
MP4 braucht `ftyp` und `moov`; ffmpeg legt `moov` standardmäßig **hinter**
`mdat`, also fehlt bei jedem Schnitt das Entscheidende.

Deshalb schneidet **ffmpeg** einmal einen richtigen Schnipsel, und
ausgeliefert wird danach eine ganz gewöhnliche Datei. Damit ist die
Längenbegrenzung auch keine Zusage mehr, auf die man vertrauen muss: Was
nicht im Schnipsel steht, kann niemand abrufen.

### Wann und wo geschnitten wird

Beim Start, in einem **Hintergrund-Thread**. Der erste Lauf über eine große
Sammlung dauert Stunden (gemessen: rund eine halbe Sekunde je Lied); der
Server ist dabei sofort ansprechbar, und die Vorschauen tauchen nach und
nach auf. Beim nächsten Start ist alles schon da und der Durchlauf dauert
Sekunden — vorhandene Schnipsel werden übersprungen, solange sie nicht älter
sind als die Tondatei.

Der Schnipsel liegt **neben der Tondatei**, als `<tondatei>.vorschau.mp3`
(30 s, mono, 44,1 kHz, 96 kbit/s — rund 350 kB). An den ganzen Namen
angehängt und nicht die Endung ersetzt, sonst zeigten `Lied.mp3` und
`Lied.m4a` im selben Ordner auf dieselbe Vorschau.

Zwei Dinge, die dabei leicht untergehen:

- Vor **jedem** Schnitt wird der freie Platz geprüft, nicht nur einmal am
  Anfang. Auf der Platte liegt mehr als die Lieder, und eine volle Platte
  reißt mehr mit als nur die Vorschau. Bleibt weniger als 1 GB, hört der
  Bauer auf und sagt es.
- Steht der Liederordner **nur lesbar** (`ProtectSystem=strict` /
  `ReadOnlyPaths` in der Dienstdatei), scheitert das Schneiden. Dann gibt es
  eben keine Vorschau; alles andere läuft weiter. Wer sie haben will, muss
  den Liederordner beschreibbar machen.

### Ab welcher Stelle

Dieselbe Rechnung wie im Spiel (`TSong.GetPreviewRange`) und im Browser
(`previewRange` in `web/js/song.js`), nachgebaut in
`UWebVorschau.VorschauStelle`: ein eigener `#PREVIEWSTART` gilt, sonst ein
Viertel in das von `#START` und `#END` begrenzte Stück hinein. Die
Sonderregel darin sieht falsch aus und ist trotzdem gewollt: Ab zwei Minuten
Versatz wird **nicht** gedeckelt, sondern auf eine Minute zurückgesetzt.

Dafür liest `USongHeader` jetzt auch `#PREVIEWSTART`, `#START` und `#END`.
Achtung bei den Einheiten: `#START` steht in Sekunden, `#END` in
**Millisekunden**; umgerechnet wird beim Lesen, danach gilt überall Sekunden.

`testwebvorschau` prüft `VorschauStelle` gegen dieselbe Tabelle, die auch in
`web/tests/run.mjs` gegen `previewRange` läuft.

## Zählen, wann welches Lied gesungen wurde

Zwei Textdateien neben der `config.ini`:

```
web-gesungen.tsv    2026-09-21T00:45:46	ABBA	Dancing Queen
web-zaehler.tsv     ABBA	Dancing Queen	3
```

Das Protokoll ist maßgeblich, die Zählerdatei ist daraus ableitbar — sie
steht trotzdem daneben, damit „wie oft" nicht bedeutet, zehntausende Zeilen
zu lesen.

Gezählt wird **beim ersten Byte Ton**, das an einen Sänger geht. Dass das
nicht schon beim Durchblättern der Liste passiert, hat zwei Gründe, und beide
sind Voraussetzung:

- Die Vorschau läuft über einen **eigenen Endpunkt**. Vorher lief sie über
  `/audio`, und jedes Antippen eines Liedes hätte als Aufführung gezählt.
- Ton und Video hängen erst **beim Betreten der Bühne** am Element, nicht
  schon beim Auswählen (`ladeLied` lädt nur die Noten, `bereiteMedien` den
  Rest). Sonst lud jedes Antippen in der Liste ein paar Megabyte — und weil
  beim ersten Byte gezählt wird, galt schon das als gesungen.

Unterschieden werden Aufführungen am **Durchgang** — einer Kennung, die der
Browser beim Beginn des Singens würfelt und in den `sessionStorage` legt.
Daraus ergeben sich die drei Regeln von selbst:

| Fall | warum |
| --- | --- |
| Drei Leute singen dasselbe Lied → **dreimal** | drei Browser, drei Kennungen |
| Einer lädt mitten im Lied neu → **nicht noch einmal** | `sessionStorage` übersteht das Neuladen, die Kennung kommt unverändert wieder |
| Danach noch einmal dasselbe Lied → **wieder** | „Singen"/„Nochmal singen" wirft die alte Kennung weg |

Der Browser holt den Ton in vielen Stücken; gezählt wird nur das erste je
Durchgang. Ohne Kennung wird **gar nicht** gezählt — sonst zählte jedes
einzelne Stück mit.

Warum nicht die Datenbank des Spiels: `UDataBase` hängt über `USong` und
`USongs` an der Grafikkette und lässt sich im kopflosen Betrieb nicht einmal
übersetzen. Außerdem kennt sie nur „wie oft", nicht „wann".

## Mehrspieler-Lobbys

Jeder, der die Seite öffnet, bekommt automatisch eine eigene Lobby — im
Regelfall eine mit nur einem Mitglied, die nie auffällt. Über einen
6-stelligen Code oder einen Teilen-Link (nur auf dem Handy angeboten, per
Web-Share-API) können weitere Geräte beitreten. Nur der **Ersteller** wählt
Lieder aus; alle anderen sehen die Auswahl mit, singen aber selbst mit
eigenem Mikrofon und eigener Wertung — nur ihre **Punktzahl** wird geteilt,
keine Notentreffer. Wer nicht der Ersteller ist, kann stattdessen per
Daumen-Emoji auf die Auswahl reagieren.

### Transport: Abfragen statt WebSocket

Bewusst kein neues Protokoll: Jedes Gerät fragt etwa einmal pro Sekunde
`/api/lobby/<code>/state` ab (`web/js/lobby.js`, `LobbyClient`). FPCs
mitgelieferte `fcl-web`-Bibliothek kennt keine WebSockets — das hätte einen
von Hand geschriebenen RFC-6455-Handshake, unbegrenzt viele offene
Verbindungen (ein Thread je Verbindung, siehe oben) und eine
Apache-Erweiterung gebraucht. Der bestehende `Stand`-Zähler aus
`UWebBridge.pas` zeigte ohnehin schon, dass dieses Muster hier gut passt.

Zwischen zwei Abfragen läuft die Wiedergabe lokal frei weiter. Erst wenn die
eigene Position mehr als 0,75 s von der aus dem Server-Anker berechneten
Sollposition abweicht, wird sanft nachgezogen (`playbackRate` kurz auf
0,97/1,03); erst ab 3 s Abweichung springt die Wiedergabe hart — derselbe
Gedanke wie bei `haltVideoNach()` für das Video, nur mit lockereren Grenzen,
weil ein Sekundentakt keine Zehntelsekunden-Genauigkeit erlaubt. Der
Ankerpunkt selbst (`serverStartMs`) wird vom Ersteller berechnet, sobald er
tatsächlich zu singen beginnt, nicht vom Server — der weiß ohnehin nichts
über Wiedergabe-Latenz.

### Rechte, Kennung, Aufräumen

Ein Token (`crypto.randomUUID()`, in `sessionStorage`) steht für ein
Gerät/einen Tab, nicht für eine Anmeldung — die ganze Seite hängt schon
hinter einem gemeinsamen Passwort. `sessionStorage` statt einer reinen
JS-Variable, damit ein versehentliches Neuladen den Ersteller nicht aus
seiner eigenen Lobby aussperrt. Der Server prüft bei jeder Aktion, die nur
der Ersteller darf, den Token erneut — ein `isHost`-Feld aus der Antwort
wird nie einfach vertraut. Tokens selbst tauchen in keiner Antwort auf, auch
nicht im eigenen `isYou`/`isHost`.

Lobbys räumen sich selbst auf, ohne eigenen Hintergrund-Thread: Jede
öffentliche Methode von `TLobbyRegistry` (`src/base/UWebLobby.pas`) prüft zu
Beginn, ob Mitglieder seit 3 Minuten nicht mehr abgefragt haben. Ein
einzelner abgelaufener Gast fliegt raus, die Lobby bleibt; ist der
**Ersteller** abgelaufen, endet die ganze Lobby — kein Wechsel des
Erstellers in dieser Fassung. Das nächste Poll eines Gasts bekommt dann ein
404 und behandelt das genauso wie die weiter oben beschriebene
`singen`-Rückfallbehandlung: eigene, neue Solo-Lobby.

## API

| Weg | Zweck |
| --- | --- |
| `GET /` | die Oberfläche |
| `GET /api/status` | Anzahl Lieder, Stand der Abschrift |
| `GET /api/songs?q=&mode=&max=` | Suche, höchstens 200 Treffer; `duet` je Eintrag |
| `GET /api/select?index=N` | Lied im Spiel auswählen |
| `POST /api/session` | Sitzung anlegen: `sid`, `key` (Hex), `ttl` |
| `GET /api/song/N/preview?sid=` | Vorschau-Schnipsel (30 s), verschlüsselt; 403 ohne Sitzung |
| `GET /api/song/N/txt?sid=` | die Lieddatei, verschlüsselt; 403 ohne Sitzung |
| `GET /api/song/N/audio?sid=&lauf=` | die Tondatei, verschlüsselt, mit `Range`; 403 ohne Sitzung. `lauf` zählt die Aufführung |
| `GET /api/song/N/video?sid=` | das Video, verschlüsselt, mit `Range`; 404 wenn keins, 403 ohne Sitzung |
| `GET /api/song/N/background` | das Hintergrundbild; 404 wenn keins |
| `POST /api/lobby/create?token=&name=` | eigene Lobby erstellen |
| `POST /api/lobby/<code>/join?token=&name=` | einer Lobby beitreten |
| `POST /api/lobby/<code>/leave?token=` | Lobby verlassen |
| `GET /api/lobby/<code>/state?token=&since=&score=` | Zustand abfragen, eigene Punktzahl melden |
| `POST /api/lobby/<code>/select?token=&index=` | Lied auswählen (nur Ersteller) |
| `POST /api/lobby/<code>/start?token=&serverStartMs=` | Singen beginnen (nur Ersteller) |
| `POST /api/lobby/<code>/react?token=&art=` | Daumen hoch/runter senden |

## Tests

`tests/run.sh` baut das Spiel, führt die Pascal-Tests aus, startet dann
`tests/headless.sh`, danach `web/tests/run.mjs` unter node und zuletzt
`tests/browser.sh` in einem echten Browser.

### Die Verschlüsselung prüfen vier Stellen

Sie greifen ineinander, und keine ersetzt eine andere:

| wo | was |
| --- | --- |
| `tests/testwebcrypto.pas` | ChaCha20 im **Server** gegen die Werte aus RFC 8439 |
| `web/tests/run.mjs` | ChaCha20 im **Browser** gegen dieselben Werte |
| `web/tests/strom.mjs` | beide **zusammen** über echtes HTTP, ohne Browser |
| `web/tests/browser.mjs` | Dienstarbeiter und `<audio>`, nur im Browser |

Dass Server und Browser dasselbe rechnen, zeigt sich **nicht** daran, dass
sie einander aufrufen — sie tun es nie. Es zeigt sich daran, dass beide
gegen den RFC stimmen. Weicht eine Seite ab, fällt es in ihrem eigenen Test
auf und nicht erst als stummes Lied.

Ein selbstgebautes Stromverfahren ver- und entschlüsselt auch dann
fehlerfrei mit sich selbst, wenn es an einer Drehung oder einer
Bytereihenfolge danebenliegt. Deshalb die festen Werte aus dem RFC, und
deshalb prüft `strom.mjs` zusätzlich, dass über die Leitung **etwas anderes**
geht als die Datei auf der Platte: Ohne diese Gegenprobe bliebe die Sammlung
grün, selbst wenn gar nicht verschlüsselt würde.

### Vorschau und Zählung prüfen

`testwebvorschau` prüft die Startstelle gegen dieselbe Tabelle wie
`web/tests/run.mjs` und schneidet dann wirklich — einmal aus einer `.m4a`,
einmal aus einer `.mp3`, beides mit ffmpeg erzeugt. Fehlt ffmpeg, überspringt
sich der Schneide-Teil, statt fehlzuschlagen.

`testwebzaehler` fährt die drei Regeln einzeln durch: mehrere Stücke
desselben Durchgangs, ein Neuladen mit derselben Kennung, ein zweiter Sänger
und ein zweites Singen.

### Der Browsertest

`tests/browser.sh` startet Server und Browser, `web/tests/browser.mjs`
spricht über CDP mit ihm. Geprüft wird, was sich sonst nirgends zeigt: dass
der Dienstarbeiter die Anfrage wirklich abfängt und `<audio>` mit dem
entschlüsselten Strom Dauer, Springen und Wiedergabe hinbekommt.

Der Nachweis, dass der Dienstarbeiter dazwischensitzt, steckt im Test
selbst: Die Seite fragt **ohne** `sid`. Käme die Anfrage so beim Server an,
wäre sie 403. Ein 200 mit lesbarem Inhalt kann es also nur geben, wenn er die
Sitzung angehängt und entschlüsselt hat.

Dazu gehört ein **eingecheckter Probeton**: `tests/probelied/` mit `ton.mp3`
(6,0 s, mono, 16 kHz, 16 kbit/s — rund 12 kB) und der passenden `lied.txt`.
Erzeugt statt heruntergeladen, damit der Test nichts aus dem Netz braucht;
bewusst nicht 8 kHz, denn das wäre MPEG-2.5 und damit die ausgefallenste
MP3-Spielart, die nicht jeder Decoder mag.

Der Test **überspringt sich selbst**, wenn kein Browser da ist — ein
fehlender Browser ist kein Fehlschlag des Codes. Gesucht wird in dieser
Reihenfolge: `$CHROME`, ein eigenständig geladenes Chrome unter
`~/.cache/puppeteer`, dann das System. Dabei wird nicht geprüft, ob die Datei
existiert, sondern ob sie **startet**: Auf Rechnern, deren `/tmp` ein Symlink
ist, scheitert jeder streng eingesperrte Snap in `snap-confine`
(`cannot create temporary directory for the root file system`), und
`chromium` wie `firefox` sind auf Ubuntu genau das. Einen brauchbaren
Browser holt man sich ohne Root mit:

```
npx -y @puppeteer/browsers install chrome@stable --path "$HOME/.cache/puppeteer"
```

Gesprochen wird über CDP von Hand — node bringt seit Fassung 22 einen
WebSocket-Client mit, und Puppeteer wäre eine Abhängigkeit, die das Projekt
sonst nirgends braucht.

`testwebserver` startet einen echten Server auf Port 8099 und spricht ihn
über einen rohen TCP-Anschluss an — mit einer HTTP-Bibliothek prüfte man am
Ende die Bibliothek statt den Server.

`testweblobby` prüft `TLobbyRegistry` für sich, ohne Sockets: Rechte des
Erstellers, Reaktionsschlange, Aufräumen abgelaufener Mitglieder/Lobbys,
sowie Nebenläufigkeit (ein Thread hämmert auf einer Lobby herum, während der
Haupttest sie gleichzeitig verändert).

`tests/headless.sh` startet die **gebaute Binärdatei** mit `--web-only` auf
Port 8171 und ruft sie über HTTP ab. Das ist der einzige Test, der den ganzen
Weg abdeckt: Befehlszeile, Abzweigung vor `Main`, Ordnersuche, Kopfdaten,
Server, Dateien. Und er zeigt zugleich, was *nicht* passiert — liefe das
Programm doch in die Grafikinitialisierung, käme es hier gar nicht bis zur
ersten Antwort.
