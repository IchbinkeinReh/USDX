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
console.log(`${bestanden} bestanden, ${fehlgeschlagen} fehlgeschlagen`);
if (fehlgeschlagen > 0) process.exit(1);
