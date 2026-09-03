// Tonhoehenerkennung aus dem Mikrofon.
//
// Portiert aus src/base/URecord.pas - dasselbe Verfahren wie im Spiel, damit
// sich beide Fassungen gleich verhalten: die zirkulare mittlere
// Betragsdifferenz (CAMDF) ueber eine feste Halbtontabelle.
//
//   D(tau) = 1/N * Summe |x((n+tau) mod N) - x(n)|
//
// Fuer jeden der 49 Halbtoene von C2 bis C6 wird die zugehoerige
// Verschiebung geprueft; der kleinste Wert gewinnt. Trifft die Verschiebung
// die Periode, liegen die Werte uebereinander und die Differenz wird klein.
//
// Der erste Entwurf benutzte stattdessen die normierte Quadratdifferenz
// (McLeod/NSDF) mit einer Schranke fuer die Eindeutigkeit des Fundes. Das
// war der Grund, warum oft kein Balken kam: Gemessen an nachgebauten
// Aufnahmen fand das Verfahren den richtigen Ton, verwarf ihn aber - eine
// Stimme ueber laufender Musik kam auf eine Eindeutigkeit von 0,51, eine
// verrauschte auf 0,71, und beides lag unter der Schranke.
//
// USDX kennt so eine Schranke gar nicht. Dort entscheidet ALLEIN die
// Lautstaerke, ob ausgewertet wird; danach gibt es immer einen Ton. Das ist
// grosszuegiger und gelegentlich falsch - aber ein gelegentlich falscher
// Balken ist beim Singen deutlich besser als gar keiner.

// Kammerton und Umfang wie im Spiel: 49 Halbtoene von C2 (65,4 Hz) bis
// C6 (1046,5 Hz).
export const BASIS_FREQ = 440;
export const HALBTOENE = 49;

// Der Halbton mit dem Index 33 ist der Kammerton a' = MIDI 69. Daraus folgt
// der Versatz zur MIDI-Nummer.
export const MIDI_VERSATZ = 69 - 33;   // = 36, also Index 0 = C2 = MIDI 36

export const MIN_FREQ = frequenzVonIndex(0);
export const MAX_FREQ = frequenzVonIndex(HALBTOENE - 1);

// Lautstaerkeschranke. Im Spiel einstellbar von 0,05 bis 0,60
// (IThresholdVals in UIni.pas); 0,05 ist die empfindlichste Stufe.
// Gemessen wird wie dort der GROESSTE Betrag im Fenster, nicht der
// Effektivwert - ein kurzer lauter Anlaut zaehlt damit schon.
export const MIN_VOLUME = 0.05;

export function frequenzVonIndex(index) {
  return BASIS_FREQ * Math.pow(2, (index - 33) / 12);
}

// Verschiebungen in Abtastwerten, eine je Halbton.
// Wird je Abtastrate einmal gebaut und dann wiederverwendet.
const delayCache = new Map();
export function verschiebungen(sampleRate) {
  let d = delayCache.get(sampleRate);
  if (!d) {
    d = new Int32Array(HALBTOENE);
    for (let i = 0; i < HALBTOENE; i++)
      d[i] = Math.round(sampleRate / frequenzVonIndex(i));
    delayCache.set(sampleRate, d);
  }
  return d;
}

export function rms(buffer) {
  let sum = 0;
  for (let i = 0; i < buffer.length; i++) sum += buffer[i] * buffer[i];
  return Math.sqrt(sum / buffer.length);
}

// Groesster Betrag im Fenster - das ist die Groesse, an der USDX die
// Lautstaerke misst (MaxSampleVolume in URecord.pas).
export function maxVolume(buffer) {
  let m = 0;
  for (let i = 0; i < buffer.length; i++) {
    const v = buffer[i] < 0 ? -buffer[i] : buffer[i];
    if (v > m) m = v;
  }
  return m;
}

// Liefert den Halbtonindex 0..48, oder -1 wenn es zu leise war.
//
// Die zirkulare Fassung (mod N statt Abbruch am Ende) ist bewusst dieselbe
// wie im Spiel: Sie vergleicht bei jeder Verschiebung gleich viele Werte,
// wodurch tiefe Toene nicht dadurch benachteiligt werden, dass fuer sie
// weniger Vergleiche uebrig bleiben.
export function detectToneIndex(buffer, sampleRate, minVolume = MIN_VOLUME) {
  const n = buffer.length;
  if (n < 128) return -1;
  // Muss eine Zweierpotenz sein, sonst greift die Maskierung nicht.
  if ((n & (n - 1)) !== 0) return -1;
  if (maxVolume(buffer) < minVolume) return -1;

  const delays = verschiebungen(sampleRate);
  const maske = n - 1;
  let besterIndex = 0;
  let besterWert = Infinity;

  for (let t = 0; t < HALBTOENE; t++) {
    const tau = delays[t];
    let summe = 0;
    for (let i = 0; i < n; i++) {
      const d = buffer[(i + tau) & maske] - buffer[i];
      summe += d < 0 ? -d : d;
    }
    summe /= n;
    // "<=" wie ArrayIndexOfMinimum im Spiel: Bei Gleichstand gewinnt der
    // spaetere, also hoehere Ton.
    if (summe <= besterWert) {
      besterWert = summe;
      besterIndex = t;
    }
  }
  return besterIndex;
}

// MIDI-Notennummer, oder -1.
export function detectMidi(buffer, sampleRate, minVolume = MIN_VOLUME) {
  const i = detectToneIndex(buffer, sampleRate, minVolume);
  return i < 0 ? -1 : i + MIDI_VERSATZ;
}

// Frequenz in Hz, oder -1. Aufloesung ist der Halbton - genau wie im Spiel,
// und mehr braucht die Wertung auch nicht, die ohnehin in Halbtoenen denkt.
export function detectFrequency(buffer, sampleRate, minVolume = MIN_VOLUME) {
  const i = detectToneIndex(buffer, sampleRate, minVolume);
  return i < 0 ? -1 : frequenzVonIndex(i);
}

// Frequenz -> MIDI-Notennummer (69 = Kammerton a').
export function freqToMidi(freq) {
  if (!(freq > 0)) return -1;
  return 69 + 12 * Math.log2(freq / 440);
}

// USDX wertet nur die Tonstufe, nicht die Oktave: Wer eine Oktave tiefer
// singt, soll trotzdem Punkte bekommen.
export function sameTone(midiA, midiB) {
  if (midiA < 0 || midiB < 0) return false;
  const diff = (((Math.round(midiA) - Math.round(midiB)) % 12) + 12) % 12;
  return diff === 0;
}

// Wie weit daneben, in Halbtoenen innerhalb einer Oktave (0..6).
export function toneDistance(midiA, midiB) {
  if (midiA < 0 || midiB < 0) return 6;
  const diff = (((Math.round(midiA) - Math.round(midiB)) % 12) + 12) % 12;
  return Math.min(diff, 12 - diff);
}
