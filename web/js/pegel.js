// Automatisches Pegeln des Mikrofons.
//
// Mikrofone liefern sehr unterschiedliche Pegel: ein Headset dicht am Mund
// zehnmal so viel wie ein Laptopmikrofon quer durchs Zimmer. Dazu kommt,
// dass die Aufbereitung des Browsers bewusst abgeschaltet ist -
// echoCancellation, noiseSuppression und autoGainControl verbiegen die
// Tonhoehe, sind fuers Singen also unbrauchbar. Genau die Pegelregelung,
// die sonst der Browser macht, fehlt damit und wird hier nachgebaut.
//
// Betrachtet werden die letzten fuenf Sekunden. Kuerzer waere zu zappelig -
// eine Atempause zoege den Pegel sofort hoch; laenger reagierte zu traege
// auf jemanden, der naeher ans Mikrofon geht.
//
// Zwei Werte werden daraus gewonnen, und beide werden gebraucht:
//
//   Rauschboden  das Leise im Fenster. Alles, was kaum darueber liegt, ist
//                Zimmergeraeusch und kein Gesang.
//   Spitze       das Laute im Fenster. Daraus folgt, wie weit verstaerkt
//                werden muss, damit Gesang den Wertebereich ausfuellt.
//
// Gemessen wird der GROESSTE Betrag im Fenster, nicht der Effektivwert -
// dasselbe Mass, an dem USDX seine Lautstaerkeschranke festmacht
// (MaxSampleVolume in URecord.pas). So bedeuten die Zahlen hier dasselbe wie
// dort.
//
// Bewusst NICHT der kleinste und groesste Wert, sondern Rangwerte: Ein
// einzelnes Klopfen auf den Tisch wuerde die Spitze sonst fuer fuenf
// Sekunden verderben und die Verstaerkung zusammenbrechen lassen.

export const FENSTER_SEK = 5;

// Rangwerte statt Extremwerte, siehe oben.
export const RANG_LEISE = 0.20;
export const RANG_LAUT = 0.90;

// Auf diesen Pegel wird hochgeregelt. Nicht auf 1: Gesang schwankt, und wer
// bis an den Rand verstaerkt, uebersteuert bei der naechsten lauten Stelle.
export const ZIEL_PEGEL = 0.45;

// Grenzen der Verstaerkung. Nach oben, damit in einer Pause nicht das
// Zimmerrauschen bis zur Unkenntlichkeit hochgezogen wird; nach unten nie
// abschwaechen, dafuer ist die Erkennung nicht der richtige Ort.
export const MIN_FAKTOR = 1;
export const MAX_FAKTOR = 40;

// Wie weit ueber dem Rauschboden es liegen muss, um als Gesang zu gelten.
// Ueber lauter Musik aus dem Lautsprecher ist der Rauschboden nicht mehr das
// Zimmer, sondern das Lied selbst. Wer da das Zweieinhalbfache verlangt,
// verlangt, dass der Saenger die Anlage uebertoent - deshalb knapp bemessen.
export const UEBER_RAUSCHEN = 1.5;

// Unterste Schwelle, auch wenn es vollkommen still war. Ohne sie wuerde in
// absoluter Stille der Rauschboden zu null und jedes Knistern zaehlte.
export const MIN_SCHWELLE = 0.02;

function rangwert(sortiert, anteil) {
  if (sortiert.length === 0) return 0;
  const i = Math.min(sortiert.length - 1,
                     Math.max(0, Math.round(anteil * (sortiert.length - 1))));
  return sortiert[i];
}

export class Pegel {
  constructor(fensterSek = FENSTER_SEK) {
    this.fenster = fensterSek;
    this.werte = [];        // [{ zeit, pegel }]
    this.faktor = 1;
  }

  // Einen gemessenen Pegel (RMS des Rohsignals) aufnehmen.
  fuettern(pegel, zeit) {
    if (!(pegel >= 0) || !Number.isFinite(zeit)) return;
    this.werte.push({ zeit, pegel });
    const grenze = zeit - this.fenster;
    // Von vorne wegwerfen, was aus dem Fenster gelaufen ist.
    let weg = 0;
    while (weg < this.werte.length && this.werte[weg].zeit < grenze) weg++;
    if (weg > 0) this.werte.splice(0, weg);
  }

  get anzahl() { return this.werte.length; }

  sortierte() {
    return this.werte.map((w) => w.pegel).sort((a, b) => a - b);
  }

  rauschboden() { return rangwert(this.sortierte(), RANG_LEISE); }
  spitze() { return rangwert(this.sortierte(), RANG_LAUT); }

  // Ab welchem Pegel es als Gesang zaehlt.
  schwelle() {
    return Math.max(MIN_SCHWELLE, this.rauschboden() * UEBER_RAUSCHEN);
  }

  // Wie stark verstaerkt werden soll.
  //
  // Der Wert wird gedaempft nachgefuehrt statt sofort gesetzt: Ein Sprung
  // mitten im Ton aendert zwar nicht die Tonhoehe, laesst aber die Anzeige
  // des Pegels springen und macht jede spaetere Schwelle unruhig.
  berechneFaktor() {
    const laut = this.spitze();
    let ziel = MIN_FAKTOR;
    // Erst ab etwas Erfahrung regeln - sonst wird die erste Stille als
    // "sehr leise" gedeutet und alles bis zum Anschlag hochgezogen.
    if (this.werte.length >= 8 && laut > 1e-6) {
      ziel = ZIEL_PEGEL / laut;
    }
    ziel = Math.min(MAX_FAKTOR, Math.max(MIN_FAKTOR, ziel));

    // Nach oben langsam, nach unten schneller: Uebersteuern soll kurz
    // bleiben, ein zu leises Mikrofon darf sich ruhig einpendeln.
    const tempo = ziel > this.faktor ? 0.08 : 0.25;
    this.faktor += (ziel - this.faktor) * tempo;
    return this.faktor;
  }
}
