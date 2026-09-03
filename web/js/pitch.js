// Tonhoehenerkennung aus dem Mikrofon.
//
// Im Spiel macht das PortAudio samt eigener Analyse; im Browser gibt es
// dafuer die Web Audio API. Das Verfahren hier ist die normierte
// Quadratdifferenz (McLeod), eine Autokorrelation mit Normierung - robuster
// gegen Oktavfehler als die reine Autokorrelation und ohne Bibliothek
// umsetzbar.
//
// Gesungen wird zwischen etwa 70 Hz (tiefe Maennerstimme) und 1000 Hz;
// ausserhalb davon wird gar nicht erst gesucht, das spart Rechenzeit und
// verhindert Ausreisser.

export const MIN_FREQ = 70;
export const MAX_FREQ = 1000;

// Unterhalb dieser Lautstaerke ist es Stille oder Raumgeraeusch. Ohne diese
// Schwelle "erkennt" das Verfahren in jedem Rauschen eine Tonhoehe.
export const MIN_RMS = 0.01;

// Wie eindeutig der Fund sein muss. Darunter ist es eher Geraeusch als Ton.
export const MIN_CLARITY = 0.9;

export function rms(buffer) {
  let sum = 0;
  for (let i = 0; i < buffer.length; i++) sum += buffer[i] * buffer[i];
  return Math.sqrt(sum / buffer.length);
}

// Wie nah ein Gipfel am hoechsten liegen muss, um genommen zu werden.
// Der Kern des Verfahrens: Bei einem periodischen Signal ist der Wert bei
// JEDEM Vielfachen der Periode fast gleich hoch. Wer einfach das Maximum
// nimmt, landet zufaellig auf einer tieferen Oktave - im ersten Entwurf
// wurden 220, 440 und 880 Hz allesamt als 110 Hz erkannt. Richtig ist der
// ERSTE Gipfel, der nah genug am hoechsten liegt.
export const PEAK_RATIO = 0.9;

// Liefert die Frequenz in Hz, oder -1 wenn nichts Eindeutiges zu finden war.
export function detectFrequency(buffer, sampleRate) {
  const n = buffer.length;
  if (n < 128) return -1;
  if (rms(buffer) < MIN_RMS) return -1;

  const maxLag = Math.min(n - 1, Math.floor(sampleRate / MIN_FREQ));
  const minLag = Math.max(2, Math.floor(sampleRate / MAX_FREQ));
  if (minLag >= maxLag) return -1;

  // Normierte Quadratdifferenz je Verschiebung.
  const nsdf = new Float32Array(maxLag + 1);
  let hoechster = 0;
  for (let lag = minLag; lag <= maxLag; lag++) {
    let korrelation = 0;
    let energie = 0;
    for (let i = 0; i < n - lag; i++) {
      korrelation += buffer[i] * buffer[i + lag];
      energie += buffer[i] * buffer[i] + buffer[i + lag] * buffer[i + lag];
    }
    nsdf[lag] = energie > 0 ? (2 * korrelation) / energie : 0;
    if (nsdf[lag] > hoechster) hoechster = nsdf[lag];
  }

  if (hoechster < MIN_CLARITY) return -1;

  // Ersten Gipfel suchen, der nah genug am hoechsten liegt.
  const schwelle = hoechster * PEAK_RATIO;
  let bestLag = -1;
  for (let lag = minLag + 1; lag < maxLag; lag++) {
    if (nsdf[lag] > nsdf[lag - 1] && nsdf[lag] >= nsdf[lag + 1] &&
        nsdf[lag] >= schwelle) {
      bestLag = lag;
      break;
    }
  }
  if (bestLag < 0) return -1;

  // Der wahre Gipfel liegt meist zwischen zwei Verschiebungen. Eine Parabel
  // durch die drei Punkte trifft ihn genauer - ohne das ist die Aufloesung
  // bei hohen Toenen zu grob, um Halbtoene zu unterscheiden.
  const y0 = nsdf[bestLag - 1], y1 = nsdf[bestLag], y2 = nsdf[bestLag + 1];
  const nenner = 2 * (2 * y1 - y0 - y2);
  const versatz = nenner !== 0 ? (y2 - y0) / nenner : 0;
  const lag = bestLag + Math.max(-1, Math.min(1, versatz));

  return sampleRate / lag;
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
