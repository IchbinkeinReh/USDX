# Weboberfläche (`--web`)

Startet das Spiel zusätzlich mit einer kleinen Weboberfläche, mit der sich
vom Handy aus die Liedersammlung durchsuchen und ein Lied auswählen lässt.

```
ultrastardx --web
```

Danach im selben Netz `http://<Rechner>:8080` aufrufen.

## Was sie kann

- Die Sammlung durchsuchen — mit derselben Syntax wie im Spiel:
  `abba OR queen`, `!live`, `(abba OR queen) AND 1990-1999`
- Nach Titel, Interpret, Genre, Sprache, Edition oder Jahr einschränken
- Ein Lied antippen: Es wird im Spiel **ausgewählt**

## Was sie bewusst nicht kann

**Sie startet kein Lied.** Zum Singen gehören Spielerzahl und Namen; das aus
der Ferne zu entscheiden führt nur dazu, dass jemand mitten im Raum
überrascht wird. Die Auswahl springt auf das Lied, gestartet wird am Gerät.

**Sie ist nicht das Spiel im Browser.** Das setzte eine
WebAssembly-Übersetzung voraus, und FPCs WASM-Ziel unterstützt weder SDL2
noch OpenGL, ffmpeg oder PortAudio.

## Sicherheit

**Es gibt keine Anmeldung.** Wer im selben Netz ist, kann die Liederliste
sehen und Lieder auswählen. Für ein Heimnetz ist das gewollt — ins Internet
gehört dieser Port nicht, und hinter eine Portfreigabe erst recht nicht.

## Aufbau

| Unit | Aufgabe |
| --- | --- |
| `UWebBridge` | Übergabe zwischen Spiel- und Webthread |
| `UWebApi` | Wegewahl und JSON |
| `UWebPage` | die Oberfläche als eingebettete Zeichenkette |
| `UWebServer` | HTTP-Thread, dünne Schale um `UWebApi` |

Der Webthread fasst **niemals** die Datenstrukturen des Spiels an.
`CatSongs.Song` wird beim Einlesen, Sortieren und Filtern ständig verändert;
ein Zugriff von außen läse halbfertige Zustände. Stattdessen veröffentlicht
der Spielthread eine Abschrift, und Anforderungen aus dem Netz wandern als
Befehl in eine Schlange, die der Spielthread in seiner Schleife abarbeitet.

`UWebApi` ist von `UWebServer` getrennt, weil letzterer über `ULog` am halben
Spiel hängt und sich ohne SDL nicht einmal übersetzen lässt. So ist jede
Route prüfbar, ohne dass ein Fenster aufgeht.

Die Oberfläche ist eingebettet statt als Datei daneben — so funktioniert sie
auch, wenn das Spiel von einem Stick läuft. Sie lädt nichts aus dem Internet
nach; ein Test prüft das.

HTTP-Server und JSON stammen aus der FPC-Standardbibliothek
(`fphttpserver`, `fpjson`), es kommt keine Abhängigkeit dazu.

## API

| Weg | Zweck |
| --- | --- |
| `GET /` | die Oberfläche |
| `GET /api/status` | Anzahl Lieder, Stand der Abschrift |
| `GET /api/songs?q=&mode=&max=` | Suche, höchstens 200 Treffer |
| `GET /api/select?index=N` | Lied auswählen (reiht einen Befehl ein) |
