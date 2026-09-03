// Prueft den Kern der Weboberflaeche ohne Browser: Parser, Tonhoehe, Wertung.
// Zeichnen und Mikrofon bleiben aussen vor - dafuer braucht es einen Browser.

import { parseSong, noteProgress, secondsUntilLine, lineAt, nextLineAt,
         NOTE_FREESTYLE, NOTE_GOLDEN } from '../js/song.js';
import { detectFrequency, freqToMidi, sameTone, toneDistance, rms } from '../js/pitch.js';
import { Scorer, MAX_SCORE, inOktave } from '../js/score.js';
import { lyricHelper, helferBahn,
         HELFER_MIN_VORLAUF, HELFER_GRENZE } from '../js/render.js';
import { istHandy, HANDY_BREITE } from '../js/vollbild.js';
import { Renderer } from '../js/render.js';

// Aufzeichnender Ersatz fuer den Zeichenkontext. Zeichnen laesst sich hier
// nicht pruefen - WAS gezeichnet wird und WIE GROSS aber schon, und genau
// daran lag es zuletzt zweimal.
function stubKontext() {
  const ops = [];
  const c = { ops, globalAlpha: 1, fillStyle: '', strokeStyle: '', lineWidth: 1,
              font: '', textAlign: 'left', textBaseline: 'top', lineJoin: '' };
  for (const m of ['clearRect', 'fillRect', 'beginPath', 'moveTo', 'lineTo',
                   'stroke', 'fill', 'save', 'restore', 'clip', 'rect',
                   'translate', 'scale', 'strokeText', 'setTransform'])
    c[m] = (...a) => ops.push([m, ...a]);
  c.roundRect = (...a) => ops.push(['roundRect', ...a]);
  c.fillText = (t, x, y) => ops.push(['fillText', t, x, y]);
  c.measureText = (t) => ({ width: t.length * 10 });
  c.createLinearGradient = () => ({ addColorStop() {} });
  return c;
}

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

// Im Format gehoert das Leerzeichen zur Silbe: ": 0 12 12 Bye " heisst "Bye"
// mit folgendem Abstand. Wer die Zeile am Ende kuerzt, klebt den ganzen
// Liedtext zusammen - in einer echten Datei betraf das 133 Zeilen.
{
  const l = parseSong('#TITLE:x\n#BPM:120\n: 0 4 60 Bye \n: 4 4 62 bye\nE');
  check('Leerzeichen am Silbenende bleibt erhalten',
        l.notes[0].text === 'Bye ', '[' + l.notes[0].text + ']');
  check('Zeile ergibt lesbaren Text',
        l.notes.map((n) => n.text).join('') === 'Bye bye',
        l.notes.map((n) => n.text).join(''));
}
{
  // Fuehrende Leerzeichen kommen ebenfalls vor - dann steht ein zweites
  // Leerzeichen in der Datei, und genau eines davon trennt die Felder.
  const l = parseSong('#TITLE:x\n#BPM:120\n: 0 4 60 Hal\n: 4 4 62  lo\nE');
  check('fuehrendes Leerzeichen bleibt erhalten',
        l.notes[1].text === ' lo', '[' + l.notes[1].text + ']');
}
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
console.log('Silbenfortschritt');
{
  const n = { start: 10, length: 4 };
  check('vor der Silbe null', noteProgress(n, 9) === 0);
  check('am Anfang null', noteProgress(n, 10) === 0);
  check('in der Mitte die Haelfte', noteProgress(n, 12) === 0.5,
        String(noteProgress(n, 12)));
  check('am Ende eins', noteProgress(n, 14) === 1);
  check('danach bleibt es eins', noteProgress(n, 99) === 1);
  // Freestyle-Noten haben Laenge 0 - ohne Abfangen kaeme hier Unendlich
  // heraus und der Text wuerde entweder ganz oder gar nicht eingefaerbt.
  check('Laenge null ergibt null statt Unendlich',
        noteProgress({ start: 0, length: 0 }, 5) === 0);
  check('ohne Note null', noteProgress(null, 5) === 0);
}

console.log('Vorlauf einer Zeile');
{
  // 120 BPM in der Datei sind intern 480; ein Schlag ist damit 0,125 s.
  const z = parseSong(`#TITLE:x
#BPM:120
#GAP:0
- 0
: 16 4 60 spaet
E`);
  const zeile = z.lines[0];
  check('vor der Zeile bleibt Zeit',
        Math.abs(secondsUntilLine(z, zeile, 0) - 2) < 1e-9,
        String(secondsUntilLine(z, zeile, 0)));
  check('genau beim Einsatz null',
        Math.abs(secondsUntilLine(z, zeile, 2)) < 1e-9);
  check('danach negativ', secondsUntilLine(z, zeile, 3) < 0);
  check('ohne Zeile kein Wert', secondsUntilLine(z, null, 0) === null);
  check('leere Zeile ergibt keinen Wert',
        secondsUntilLine(z, { notes: [] }, 0) === null);
}

console.log('Welche Zeile gilt gerade');
{
  const z = parseSong(`#TITLE:x
#BPM:120
#GAP:0
- 0
: 0 4 60 eins
- 20
: 24 4 62 zwei
E`);
  const [a, b] = z.lines;
  check('vor allem die erste Zeile', lineAt(z.tracks[0], -5) === a);
  check('waehrend der ersten die erste', lineAt(z.tracks[0], 2) === a);
  // Der Kern: Ist die Zeile ausgesungen, wird weitergeschaltet - auch wenn
  // die naechste erst spaeter einsetzt. Sonst bliebe der alte Text stehen
  // und der Vorlauf zaehlte auf einen Einsatz herunter, der vorbei ist.
  check('nach der ersten schon die zweite', lineAt(z.tracks[0], 6) === b,
        'blieb auf der ersten stehen');
  check('waehrend der zweiten die zweite', lineAt(z.tracks[0], 25) === b);
  check('nach der letzten bleibt die letzte', lineAt(z.tracks[0], 999) === b);
  // Zwei Zeilen werden angezeigt: die aktuelle und die naechste.
  check('naechste Zeile waehrend der ersten', nextLineAt(z.tracks[0], 2) === b);
  check('nach dem Weiterschalten gibt es keine mehr',
        nextLineAt(z.tracks[0], 25) === null);
  check('ohne Spur keine naechste Zeile', nextLineAt(null, 0) === null);

  check('ohne Zeilen kein Absturz', lineAt({ lines: [] }, 0) === null);
  check('ohne Spur kein Absturz', lineAt(null, 0) === null);

  // Und daraus folgt, was der Indikator zeigt: nach der ersten Zeile zaehlt
  // er auf die zweite herunter, nicht auf etwas Vergangenes.
  const rest = secondsUntilLine(z, lineAt(z.tracks[0], 6), z.beatToTime(6));
  check('der Vorlauf zeigt in die Zukunft', rest > 0, String(rest));
}

console.log('Zeichnen');
{
  const lied = parseSong(`#TITLE:x
#BPM:120
#GAP:0
- 0
: 40 4 60 hallo
E`);

  const male = (cssB, cssH, dpr) => {
    const ctx = stubKontext();
    const r = new Renderer({ width: 0, height: 0, getContext: () => ctx });
    r.passeGroesseAn(cssB, cssH, dpr);
    r.draw([{ line: lied.lines[0], nextLine: null, bars: [],
              anteile: new Map(), name: '', score: 0 }], 5);
    return ctx;
  };

  const rechner = male(1280, 480, 1);
  const handyBild = male(844, 340, 3);

  // Der Fehler, der den Anzeiger unsichtbar machte: Der Canvas wird mit
  // devicePixelRatio vergroessert, feste Masse schrumpfen dadurch auf einem
  // Handy auf ein Drittel. 24 muss ueberall 24 heissen.
  const schrift = (c) => parseFloat(c.font.match(/(\d+(?:\.\d+)?)px/)[1]);
  check('Schrift ist auf dem Rechner 24 Punkte', schrift(rechner) === 24,
        rechner.font);
  check('und auf dem Handy trotz dreifacher Aufloesung ebenso',
        schrift(handyBild) === 24, handyBild.font);

  const anzeiger = (c) => {
    const rr = c.ops.filter((o) => o[0] === 'roundRect');
    return rr[rr.length - 1];
  };
  check('der Anzeiger wird ueberhaupt gezeichnet', !!anzeiger(rechner));
  check('und ist auf dem Handy hoch genug zum Sehen',
        anzeiger(handyBild)[4] >= 8,
        'Hoehe ' + Math.round(anzeiger(handyBild)[4]));
  check('und breit genug', anzeiger(handyBild)[3] >= 30,
        'Breite ' + Math.round(anzeiger(handyBild)[3]));
  // Er muss im Bild liegen, nicht links daneben.
  check('und liegt im Bild',
        anzeiger(handyBild)[1] >= 0 &&
        anzeiger(handyBild)[1] + anzeiger(handyBild)[3] <= 844,
        'x ' + Math.round(anzeiger(handyBild)[1]));

  // Ohne passeGroesseAn muss es weiter gehen - sonst waeren diese Tests
  // nicht dieselbe Zeichenlogik wie im Browser.
  const ctx3 = stubKontext();
  const r3 = new Renderer({ width: 800, height: 300, getContext: () => ctx3 });
  r3.draw([{ line: lied.lines[0], nextLine: null, bars: [],
             anteile: new Map(), name: '', score: 0 }], 5);
  check('ohne Groessenangabe wird trotzdem gezeichnet',
        ctx3.ops.some((o) => o[0] === 'fillText'));
}

console.log('Handy erkennen');
{
  // Bewusst nicht an der Browserkennung festgemacht - die luegen seit jeher.
  // Gefragt wird nach grobem Zeiger und kleinem Bildschirm.
  const bau = (grob, breite, hoehe) => ({
    matchMedia: (q) => ({ matches: q.includes('coarse') ? grob : false }),
    screen: { width: breite, height: hoehe },
  });

  check('Handy hochkant', istHandy(bau(true, 390, 844)) === true);
  check('Handy quer', istHandy(bau(true, 844, 390)) === true);
  // Tablets sind bewusst nicht gemeint: Dort ist genug Platz, und ein
  // erzwungenes Vollbild samt festgehaltenem Querformat stoert nur.
  check('kleines Tablet quer', istHandy(bau(true, 1024, 768)) === false);
  check('kleines Tablet hochkant', istHandy(bau(true, 768, 1024)) === false);
  check('grosses Tablet', istHandy(bau(true, 1366, 1024)) === false);
  // Aufklappbares Geraet zugeklappt - noch Handy.
  check('schmales Klappgeraet', istHandy(bau(true, 400, 900)) === true);
  // Ein Rechner mit Maus soll nie ins Vollbild gezwungen werden, auch wenn
  // das Fenster klein ist.
  check('Rechner mit Maus', istHandy(bau(false, 1920, 1080)) === false);
  check('kleines Fenster mit Maus', istHandy(bau(false, 400, 800)) === false);
  // Beruehrbildschirm am Rechner: grosser Schirm, also nein.
  check('Beruehrbildschirm am Rechner', istHandy(bau(true, 1920, 1080)) === false);

  // Kennt der Browser matchMedia nicht, wird auf maxTouchPoints
  // zurueckgegriffen statt abzustuerzen.
  check('ohne matchMedia kein Absturz',
        istHandy({ navigator: { maxTouchPoints: 5 }, screen: { width: 390, height: 844 } }) === true);
  check('ohne alles kein Absturz', istHandy({}) === false);
  check('genau an der Grenze noch Handy',
        istHandy(bau(true, HANDY_BREITE, 1200)) === true);
  check('einen Punkt darueber nicht mehr',
        istHandy(bau(true, HANDY_BREITE + 1, 1200)) === false);
}

console.log('Gesungene Balken');
{
  // 120 BPM in der Datei sind intern 480, ein Schlag also 0,125 s.
  const b = parseSong(`#TITLE:x
#BPM:120
#GAP:0
: 0 8 0 la
: 8 4 0 pause
F 12 4 0 frei
E`);
  // Note mit pitch 0 entspricht MIDI 60.

  // Die Oktavverschiebung: eine Oktave zu tief ist derselbe Ton.
  check('eine Oktave tiefer wird herangeholt', inOktave(48, 60) === 60);
  check('eine Oktave hoeher ebenso', inOktave(72, 60) === 60);
  check('knapp daneben bleibt knapp daneben', inOktave(62, 60) === 62);
  check('genau eine halbe Oktave bleibt stehen', inOktave(66, 60) === 66);

  const w = new Scorer(b);
  check('anfangs keine Balken', w.bars.length === 0);

  // In einer Pause darf nichts entstehen - der Kern der Anforderung.
  w.feed(b.beatToTime(100), 60);
  check('ohne Note entsteht kein Balken', w.bars.length === 0);

  // Freestyle zaehlt nicht und darf deshalb auch keinen Balken erzeugen.
  w.feed(b.beatToTime(13), 60);
  check('bei Freestyle entsteht kein Balken', w.bars.length === 0);

  // Ohne erkannten Ton ebenfalls nichts.
  w.feed(b.beatToTime(1), -1);
  check('ohne erkannten Ton kein Balken', w.bars.length === 0);

  // Jetzt richtig gesungen.
  w.feed(b.beatToTime(1), 60);
  check('auf einer Note entsteht ein Balken', w.bars.length === 1);
  check('er sitzt auf dem richtigen Schlag',
        w.bars[0].startBeat === 1 && w.bars[0].endBeat === 2,
        JSON.stringify(w.bars[0]));
  check('und ist als Treffer vermerkt', w.bars[0].hit === true);

  // Anschliessender Schlag mit gleichem Ton verlaengert, statt einen zweiten
  // Balken danebenzusetzen.
  w.feed(b.beatToTime(2), 60);
  check('naechster Schlag verlaengert den Balken',
        w.bars.length === 1 && w.bars[0].endBeat === 3,
        JSON.stringify(w.bars));

  // Eine Oktave tiefer ist derselbe Ton - USDX wertet die Tonstufe.
  w.feed(b.beatToTime(3), 48);
  check('eine Oktave tiefer verlaengert weiter',
        w.bars.length === 1 && w.bars[0].endBeat === 4,
        JSON.stringify(w.bars));
  check('und rastet auf der Zielnote ein', w.bars[0].tone === 60,
        String(w.bars[0].tone));

  // Danebengesungen: eigener Balken, nicht als Treffer, auf der gemessenen
  // Hoehe statt auf der Note.
  const w2 = new Scorer(b);
  w2.feed(b.beatToTime(1), 62);
  check('Fehlgriff gibt einen eigenen Balken', w2.bars.length === 1);
  check('nicht als Treffer vermerkt', w2.bars[0].hit === false);
  check('und auf der gesungenen Hoehe', w2.bars[0].tone === 62,
        String(w2.bars[0].tone));

  // Wechsel von daneben auf getroffen trennt die Balken.
  w2.feed(b.beatToTime(2), 60);
  check('Wechsel trennt die Balken', w2.bars.length === 2,
        JSON.stringify(w2.bars));

  // Und die Wertung bleibt davon unberuehrt.
  check('Balken aendern die Punkte nicht', w2.score >= 0);
}

console.log('Zeilenanzeiger');
{
  // Nachgerechnet gegen SingDrawLyricHelper in src/base/UDraw.pas.
  // Zeile beginnt bei Schlag 0, erste Note bei 20 - also 20 Schlaege Vorlauf.
  const zeile = { startBeat: 0, notes: [{ start: 20, length: 4 }] };

  check('am Zeilenanfang ganz links',
        lyricHelper(zeile, 0).fortschritt === 0);
  check('auf halbem Weg die Haelfte',
        Math.abs(lyricHelper(zeile, 10).fortschritt - 0.5) < 1e-9,
        String(lyricHelper(zeile, 10).fortschritt));
  check('kurz vor der Note fast angekommen',
        lyricHelper(zeile, 19).fortschritt > 0.9);
  // Ist die Note da, hat der Anzeiger seine Aufgabe erfuellt.
  check('bei der Note verschwindet er', lyricHelper(zeile, 20) === null);
  check('danach ebenfalls', lyricHelper(zeile, 30) === null);

  // Unter dem Mindestvorlauf erscheint er gar nicht - bei kurzen Pausen
  // zwischen zwei Zeilen waere er nur ein Zucken.
  const kurz = { startBeat: 0, notes: [{ start: HELFER_MIN_VORLAUF, length: 4 }] };
  check('bei zu kurzem Vorlauf gar nicht', lyricHelper(kurz, 0) === null);
  const knapp = { startBeat: 0,
                  notes: [{ start: HELFER_MIN_VORLAUF + 1, length: 4 }] };
  check('einen Schlag darueber schon', lyricHelper(knapp, 0) !== null);

  // Bei sehr langer Wartezeit bleibt er links stehen, statt sich unmerklich
  // langsam zu bewegen: Beide Werte werden auf die Grenze gekuerzt.
  const lang = { startBeat: 0, notes: [{ start: 400, length: 4 }] };
  check('bei langer Wartezeit steht er links',
        lyricHelper(lang, 0).fortschritt === 0);
  check('und setzt sich erst ab der Grenze in Bewegung',
        lyricHelper(lang, 400 - HELFER_GRENZE).fortschritt === 0);
  check('kurz danach bewegt er sich',
        lyricHelper(lang, 400 - HELFER_GRENZE + 10).fortschritt > 0);
  check('und kommt auch dann an',
        lyricHelper(lang, 399).fortschritt > 0.9);

  // Das Pulsieren haengt am Takt, nicht am Weg - deshalb rechnet es im Spiel
  // mit dem ungekuerzten Rest.
  const a1 = lyricHelper(zeile, 20 - Math.PI * 2).alpha;   // cos = 1
  const a2 = lyricHelper(zeile, 20 - Math.PI * 2 * 0.5).alpha;
  check('Helligkeit bleibt zwischen 0,5 und 1',
        a1 <= 1.0001 && a1 >= 0.4999 && a2 <= 1.0001 && a2 >= 0.4999,
        a1 + '/' + a2);
  check('und schwankt tatsaechlich', Math.abs(a1 - a2) > 0.01,
        String(Math.abs(a1 - a2)));

  // Der Fehler, der ihn unsichtbar machte: Bei breiter, mittig gesetzter
  // Zeile bleibt links vom Text kein Platz - ohne Mindestweg fuhr der Balken
  // aus dem Bild heraus.
  const breit = 1280;
  for (const textbreite of [200, 600, 1000, 1240, 1400]) {
    const textLinks = (breit - textbreite) / 2;
    const { start, ziel, breite } = helferBahn(textLinks, breit);
    check('Anzeiger bleibt im Bild bei Textbreite ' + textbreite,
          start >= 0 && ziel > start && ziel + breite <= breit,
          `start=${Math.round(start)} ziel=${Math.round(ziel)}`);
  }
  {
    // Bei viel Platz zeigt er weiterhin auf den Textanfang und faehrt nicht
    // nur den Mindestweg.
    const { ziel, breite } = helferBahn(540, 1280);
    check('bei Platz endet er kurz vor dem Text',
          Math.abs(ziel - (540 - breite - 8)) < 0.001, String(ziel));
  }

  check('ohne Zeile kein Anzeiger', lyricHelper(null, 0) === null);
  check('ohne Noten kein Anzeiger',
        lyricHelper({ startBeat: 0, notes: [] }, 0) === null);
}

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
