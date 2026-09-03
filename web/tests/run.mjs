// Prueft den Kern der Weboberflaeche ohne Browser: Parser, Tonhoehe, Wertung.
// Zeichnen und Mikrofon bleiben aussen vor - dafuer braucht es einen Browser.

import { parseSong, NOTE_FREESTYLE, NOTE_GOLDEN } from '../js/song.js';
import { detectFrequency, freqToMidi, sameTone, toneDistance, rms } from '../js/pitch.js';
import { Scorer, MAX_SCORE } from '../js/score.js';

let bestanden = 0, fehlgeschlagen = 0;

function check(was, bedingung, detail = '') {
  if (bedingung) { bestanden++; console.log('  OK   ' + was); }
  else { fehlgeschlagen++; console.log('  FEHL ' + was + '   ' + detail); }
}

function ton(freq, { sr = 44100, n = 4096, oberton = 0.4, pegel = 0.4 } = {}) {
  const b = new Float32Array(n);
  for (let i = 0; i < n; i++)
    b[i] = (Math.sin(2*Math.PI*freq*i/sr) + oberton*Math.sin(4*Math.PI*freq*i/sr)) * pegel;
  return b;
}

console.log('Liedformat');
const s = parseSong(`#TITLE:Test
#ARTIST:Jemand
#BPM:120
#GAP:1000
#MP3:a.mp3
: 0 4 60 Hal
: 4 4 62 lo~
- 8
* 8 8 64 Welt
F 16 4 0 hey
: 20 0 60 nulllang
E
diese Zeile wird ignoriert`);

check('Kopfdaten gelesen', s.title === 'Test' && s.artist === 'Jemand');
check('Audiodatei gefunden', s.audio === 'a.mp3');
check('BPM wird mit vier multipliziert', s.bpm === 480, String(s.bpm));
check('GAP in Millisekunden', s.gap === 1000);
check('zwei Zeilen', s.lines.length === 2, String(s.lines.length));
check('fuenf Noten', s.notes.length === 5, String(s.notes.length));
check('goldene Note erkannt', s.notes[2].type === NOTE_GOLDEN);
check('Text mit Tilde bleibt', s.notes[1].text === 'lo~', s.notes[1].text);
check('Laenge 0 wird Freestyle', s.notes[4].type === NOTE_FREESTYLE);
check('nach E wird nichts mehr gelesen', !s.notes.some(n => n.text.includes('ignoriert')));

console.log('Zeitrechnung');
check('Schlag 0 liegt beim GAP', s.beatToTime(0) === 1);
check('Schlag 480 bei 61 s', Math.abs(s.beatToTime(480) - 61) < 1e-9, String(s.beatToTime(480)));
check('Rueckrechnung stimmt', Math.abs(s.timeToBeat(s.beatToTime(123)) - 123) < 1e-9);

console.log('Punktwert');
// normal 4 + 4, golden 8*2 = 16, Freestyle zaehlt nicht
check('Freestyle zaehlt nicht, Golden doppelt', s.maxNoteValue === 24, String(s.maxNoteValue));

console.log('Tonhoehe');
for (const f of [82.4, 110, 220, 261.6, 440, 880]) {
  const ab = Math.abs(freqToMidi(detectFrequency(ton(f), 44100)) - freqToMidi(f));
  check(`${f} Hz auf unter 0,2 Halbtoene genau`, ab < 0.2, ab.toFixed(3));
}
// Der Fehler, der im ersten Entwurf drin war: 220 und 440 wurden als 110
// erkannt, weil das globale Maximum statt des ersten Gipfels genommen wurde.
check('kein Oktavfehler nach unten',
      detectFrequency(ton(440), 44100) > 400, String(detectFrequency(ton(440), 44100)));

const stille = new Float32Array(4096);
check('Stille ergibt keinen Ton', detectFrequency(stille, 44100) === -1);
const rauschen = new Float32Array(4096).map(() => (Math.random() - 0.5) * 0.6);
check('Rauschen ergibt keinen Ton', detectFrequency(rauschen, 44100) === -1,
      String(detectFrequency(rauschen, 44100)));
check('zu kurzer Block ergibt -1', detectFrequency(new Float32Array(64), 44100) === -1);
check('Pegel wird gemessen', rms(ton(440)) > 0.1 && rms(stille) === 0);

console.log('Tonvergleich');
check('gleicher Ton trifft', sameTone(60, 60));
check('Oktave gilt als gleich', sameTone(60, 72) && sameTone(60, 48));
check('Halbton daneben trifft nicht', !sameTone(60, 61));
check('nichts erkannt trifft nie', !sameTone(-1, 60));
check('Abstand ist der kuerzere Weg', toneDistance(60, 71) === 1, String(toneDistance(60, 71)));

console.log('Wertung');
const w = new Scorer(s);
check('ohne Eingabe null Punkte', w.score === 0);
// Note 0: Schlaege 0..4, Tonhoehe 60 -> MIDI 120; Oktave egal
for (let i = 0; i < 10; i++) w.feed(s.beatToTime(1), 120);
check('richtig gesungen gibt Punkte', w.score > 0, String(w.score));

const w2 = new Scorer(s);
for (let i = 0; i < 10; i++) w2.feed(s.beatToTime(1), 121);   // Halbton daneben
check('falsch gesungen gibt nichts', w2.score === 0, String(w2.score));

const w3 = new Scorer(s);
// Alle wertbaren Noten voll treffen
for (const n of s.notes) {
  if (n.type === NOTE_FREESTYLE) continue;
  for (let i = 0; i < 5; i++) w3.feed(s.beatToTime(n.start + 0.5), n.pitch + 60);
}
check('alles richtig ergibt die Hoechstpunktzahl', w3.score === MAX_SCORE, String(w3.score));

const w4 = new Scorer(s);
check('in der Pause gibt es nichts zu treffen', w4.feed(s.beatToTime(1000), 60) === null);
check('Freestyle wird nicht gewertet', w4.feed(s.beatToTime(17), 60) === null);

console.log();
console.log('Video und Hintergrund');
const v = parseSong(`#TITLE:Mit Bild
#ARTIST:Wer
#BPM:120
#VIDEO:clip.mp4
#BACKGROUND:bild.jpg
#VIDEOGAP:1,5
: 0 4 60 a
E`);
check('Videodatei aus dem Kopf', v.video === 'clip.mp4', v.video);
check('Hintergrundbild aus dem Kopf', v.background === 'bild.jpg', v.background);
// Kommazahlen stehen mal mit Punkt, mal mit Komma - beim VIDEOGAP wuerde
// ein Punkt-Komma-Fehler das Bild um Sekunden verschieben.
check('VIDEOGAP mit Komma', v.videoGap === 1.5, String(v.videoGap));

const v2 = parseSong('#TITLE:x\n#BPM:120\n#VIDEOGAP:-2.25\n: 0 4 60 a\nE');
check('VIDEOGAP mit Punkt und Vorzeichen', v2.videoGap === -2.25,
      String(v2.videoGap));

const v3 = parseSong('#TITLE:x\n#BPM:120\n: 0 4 60 a\nE');
check('ohne Angabe ist der Versatz null', v3.videoGap === 0, String(v3.videoGap));
check('ohne Angabe kein Video und kein Bild',
      v3.video === '' && v3.background === '');

console.log('Duett');

const d = parseSong(`#TITLE:Zusammen
#BPM:120
#P1:Anna
#P2:Bert
P1
: 0 4 60 Ich
: 4 4 62 sing
- 8
: 8 4 64 mit
P2
: 0 4 67 Und
: 4 4 69 ich
- 8
: 8 4 71 auch
E`);

check('als Duett erkannt', d.isDuet === true);
check('zwei Stimmen', d.tracks.length === 2, String(d.tracks.length));
check('Namen aus #P1/#P2', d.singerNames.join(',') === 'Anna,Bert',
      d.singerNames.join(','));
check('erste Stimme hat ihre Noten',
      d.tracks[0].notes.map((n) => n.text).join(' ') === 'Ich sing mit',
      d.tracks[0].notes.map((n) => n.text).join(' '));
check('zweite Stimme hat ihre Noten',
      d.tracks[1].notes.map((n) => n.text).join(' ') === 'Und ich auch',
      d.tracks[1].notes.map((n) => n.text).join(' '));
check('Zeilen bleiben je Stimme getrennt',
      d.tracks[0].lines.length === 2 && d.tracks[1].lines.length === 2);
check('beide Stimmen zaehlen gleich viel',
      d.tracks[0].maxNoteValue === 12 && d.tracks[1].maxNoteValue === 12,
      d.tracks[0].maxNoteValue + '/' + d.tracks[1].maxNoteValue);

// Alte Zugriffe zeigen weiter auf die erste Stimme - sonst braeche jeder
// bestehende Aufruf, der noch nichts von Spuren weiss.
check('song.notes meint weiterhin die erste Stimme',
      d.notes.length === 3 && d.notes[0].text === 'Ich');

const alt = parseSong(`#BPM:120
#DUETSINGERP1:Alt1
#DUETSINGERP2:Alt2
P 1
: 0 4 60 a
P 2
: 0 4 60 b
E`);
check('alte Kopfzeilen DUETSINGERP1/2 gelten auch',
      alt.singerNames.join(',') === 'Alt1,Alt2', alt.singerNames.join(','));
check('"P 1" mit Leerzeichen wird erkannt',
      alt.tracks.length === 2 && alt.tracks[1].notes[0].text === 'b');

const ohneNamen = parseSong(`#BPM:120
P1
: 0 4 60 a
P2
: 0 4 60 b
E`);
check('ohne Kopfzeilen heissen die Stimmen P1 und P2',
      ohneNamen.singerNames.join(',') === 'P1,P2');

// Ein Spurwechsel in einem Sololied ist in USDX ein Fehler. Still
// weiterzulesen wuerde die Noten in der falschen Stimme ablegen.
let gemeckert = false;
try {
  parseSong(`#BPM:120
: 0 4 60 a
P2
: 4 4 60 b
E`);
} catch (e) { gemeckert = true; }
check('Spurwechsel im Sololied wird abgelehnt', gemeckert);

gemeckert = false;
try {
  parseSong(`#BPM:120
P1
: 0 4 60 a
P3
: 4 4 60 b
E`);
} catch (e) { gemeckert = true; }
check('unbekannte Spurnummer wird abgelehnt', gemeckert);

const leer = parseSong(`#BPM:120
P1
: 0 4 60 a
P2
E`);
check('Duett ohne zweite Stimme gilt als Solo',
      leer.isDuet === false && leer.tracks.length === 1);

// Der Versatz im Relativmodus zaehlt je Spur. Mit einem gemeinsamen Zaehler
// wandert die zweite Stimme mit jeder Zeile der ersten weiter weg.
const relativ = parseSong(`#BPM:120
#RELATIVE:yes
P1
: 0 4 60 a
- 4 4
: 0 4 60 b
P2
: 0 4 60 c
- 4 4
: 0 4 60 d
E`);
check('Relativmodus: erste Stimme zaehlt fuer sich',
      relativ.tracks[0].notes.map((n) => n.start).join(',') === '0,4',
      relativ.tracks[0].notes.map((n) => n.start).join(','));
check('Relativmodus: zweite Stimme faengt wieder bei null an',
      relativ.tracks[1].notes.map((n) => n.start).join(',') === '0,4',
      relativ.tracks[1].notes.map((n) => n.start).join(','));

console.log('Wertung im Duett');
const wA = new Scorer(d, 0);
const wB = new Scorer(d, 1);
check('jede Wertung kennt ihren Namen',
      wA.name === 'Anna' && wB.name === 'Bert');
check('und ihre eigene Hoechstsumme',
      wA.maxValue === 12 && wB.maxValue === 12);

// Anna singt ihre Noten, Bert schweigt.
for (const n of d.tracks[0].notes)
  for (let i = 0; i < 5; i++) wA.feed(d.beatToTime(n.start + 0.5), n.pitch + 60);
for (const n of d.tracks[1].notes)
  for (let i = 0; i < 5; i++) wB.feed(d.beatToTime(n.start + 0.5), -1);
check('wer singt, bekommt die volle Punktzahl', wA.score === MAX_SCORE,
      String(wA.score));
check('wer schweigt, bekommt keine', wB.score === 0, String(wB.score));

// Die Stimmen liegen zeitlich uebereinander. Bert darf nicht dafuer Punkte
// bekommen, dass Anna ihre Toene trifft - das ist der Fehler, den ein
// gemeinsamer Notenvorrat machen wuerde.
const wC = new Scorer(d, 1);
for (const n of d.tracks[0].notes)
  for (let i = 0; i < 5; i++) wC.feed(d.beatToTime(n.start + 0.5), n.pitch + 60);
check('Toene der anderen Stimme zaehlen nicht', wC.score === 0, String(wC.score));

console.log();
console.log(`${bestanden} bestanden, ${fehlgeschlagen} fehlgeschlagen`);
if (fehlgeschlagen > 0) process.exit(1);
