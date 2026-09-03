// Bindet alles zusammen: Lied laden, Musik abspielen, Mikrofon auswerten,
// zeichnen, werten.
//
// Der Taktgeber ist NICHT ein Zeitgeber, sondern die Abspielposition des
// Audioelements. Alles andere laeuft frueher oder spaeter aus dem Takt -
// Timer schwanken, und schon ein halber Schlag Versatz macht das Singen
// unmoeglich.

import { parseSong } from './song.js';
import { detectFrequency, freqToMidi } from './pitch.js';
import { Scorer } from './score.js';
import { Renderer } from './render.js';

const FFT_GROESSE = 4096;

export class Game {
  constructor(canvas, elemente) {
    this.renderer = new Renderer(canvas);
    this.el = elemente;
    this.audio = new Audio();
    this.audio.preload = 'auto';
    this.song = null;
    this.scorer = null;
    this.analyser = null;
    this.puffer = null;
    this.laeuft = false;
  }

  async ladeLied(index) {
    const txt = await fetch(`/api/song/${index}/txt`).then((r) => {
      if (!r.ok) throw new Error('Lied nicht ladbar');
      return r.text();
    });
    this.song = parseSong(txt);
    this.scorer = new Scorer(this.song);
    this.audio.src = `/api/song/${index}/audio`;
    this.el.titel.textContent = `${this.song.artist} – ${this.song.title}`;
    if (this.song.duet)
      this.el.hinweis.textContent = 'Duett: nur die erste Stimme wird gesungen.';
    return this.song;
  }

  async starteMikrofon() {
    // Ohne Mikrofon laesst sich spielen, nur eben ohne Punkte - besser als
    // gar nicht zu starten, wenn jemand die Freigabe verweigert.
    try {
      const strom = await navigator.mediaDevices.getUserMedia({
        audio: {
          echoCancellation: false,   // wuerde die eigene Stimme wegrechnen
          noiseSuppression: false,   // beschneidet die Tonhoehe
          autoGainControl: false,
        },
      });
      const ctx = new (window.AudioContext || window.webkitAudioContext)();
      const quelle = ctx.createMediaStreamSource(strom);
      this.analyser = ctx.createAnalyser();
      this.analyser.fftSize = FFT_GROESSE;
      quelle.connect(this.analyser);
      this.puffer = new Float32Array(this.analyser.fftSize);
      this.abtastrate = ctx.sampleRate;
      return true;
    } catch (e) {
      this.el.hinweis.textContent =
        'Kein Mikrofon - es wird abgespielt, aber nicht gewertet.';
      return false;
    }
  }

  async start() {
    if (!this.song) return;
    await this.starteMikrofon();
    await this.audio.play();
    this.laeuft = true;
    requestAnimationFrame(() => this.schleife());
  }

  stop() {
    this.laeuft = false;
    this.audio.pause();
  }

  aktuelleZeile(beat) {
    let treffer = null;
    for (const zeile of this.song.lines) {
      if (beat >= zeile.startBeat) treffer = zeile;
      else break;
    }
    return treffer || this.song.lines[0];
  }

  schleife() {
    if (!this.laeuft) return;

    // Die Abspielposition ist der Takt, siehe Kopfkommentar.
    const zeit = this.audio.currentTime;
    const beat = this.song.timeToBeat(zeit);

    let midi = -1;
    if (this.analyser) {
      this.analyser.getFloatTimeDomainData(this.puffer);
      const f = detectFrequency(this.puffer, this.abtastrate);
      if (f > 0) midi = freqToMidi(f);
      this.scorer.feed(zeit, midi);
    }

    // Anteil je Note fuer die Einfaerbung.
    const anteile = new Map();
    for (const [note, s] of this.scorer.state)
      anteile.set(note, s.tries > 0 ? s.hits / s.tries : 0);

    this.renderer.draw(this.aktuelleZeile(beat), beat, midi, anteile);
    this.el.punkte.textContent = String(this.scorer.score);

    if (this.audio.ended) {
      this.laeuft = false;
      this.el.hinweis.textContent = `Fertig - ${this.scorer.score} Punkte`;
      return;
    }
    requestAnimationFrame(() => this.schleife());
  }
}
