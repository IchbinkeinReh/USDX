// Bindet alles zusammen: Lied laden, Musik abspielen, Mikrofone auswerten,
// zeichnen, werten.
//
// Der Taktgeber ist NICHT ein Zeitgeber, sondern die Abspielposition des
// Audioelements. Alles andere laeuft frueher oder spaeter aus dem Takt -
// Timer schwanken, und schon ein halber Schlag Versatz macht das Singen
// unmoeglich.
//
// Duett: Jede Stimme bekommt ein eigenes Mikrofon und eine eigene Wertung.
// Zwei Saenger an EINEM Mikrofon lassen sich nicht auseinanderhalten - der
// Aufbau laesst das deshalb gar nicht erst zu, statt hinterher Punkte zu
// verteilen, die niemand nachvollziehen kann.

import { parseSong, lineAt, nextLineAt } from './song.js';
import { detectFrequency, freqToMidi } from './pitch.js';
import { Scorer } from './score.js';
import { Renderer } from './render.js';

const FFT_GROESSE = 4096;

// Ab wie viel Abweichung das Video nachgezogen wird. Jedes Bild neu zu
// setzen laesst es ruckeln; gar nicht nachzuziehen laesst es davonlaufen.
const VIDEO_TOLERANZ = 0.30;

export class Game {
  constructor(canvas, elemente) {
    this.renderer = new Renderer(canvas);
    this.el = elemente;
    this.audio = new Audio();
    this.audio.preload = 'auto';
    this.song = null;
    this.saenger = [];      // [{ trackIndex, scorer, analyser, puffer, sungMidi }]
    this.ctx = null;
    this.laeuft = false;
    this.hatVideo = false;
    this.hatBild = false;
    // Wird gerufen, wenn das Lied durch ist - die Oberflaeche verlaesst
    // darauf das Vollbild.
    this.onEnde = null;
  }

  // Video und Hintergrundbild vorbereiten.
  //
  // Dieselbe Reihenfolge wie im Spiel (UScreenSingController): Ist ein Video
  // da, laeuft es; sonst steht das Bild. Beide werden geladen, denn das Bild
  // ist der Rueckfall - und der wird oefter gebraucht, als man denkt: In
  // vielen aelteren Liedern steht ein .avi oder .mpg, und das spielt kein
  // Browser ab. Erst der Fehler beim Laden verraet das, vorher nicht.
  bereiteHintergrund(index, song) {
    const { video, bild } = this.el;
    this.hatVideo = false;
    this.hatBild = false;

    if (bild) {
      bild.style.display = 'none';
      if (song.background) {
        bild.onload = () => {
          this.hatBild = true;
          if (!this.hatVideo) bild.style.display = 'block';
        };
        bild.onerror = () => { this.hatBild = false; };
        bild.src = `/api/song/${index}/background`;
      } else {
        bild.removeAttribute('src');
      }
    }

    if (video) {
      video.style.display = 'none';
      video.pause();
      // Stumm, und das ist keine Bequemlichkeit: Der Ton kommt aus der
      // Tondatei. Liefe die Tonspur des Videos mit, hoerte man alles doppelt
      // und leicht versetzt.
      video.muted = true;
      video.removeAttribute('src');
      video.load();

      if (song.video) {
        video.oncanplay = () => {
          this.hatVideo = true;
          video.style.display = 'block';
          if (bild) bild.style.display = 'none';
        };
        video.onerror = () => {
          // Kein Video - das Bild uebernimmt, falls es eines gibt.
          this.hatVideo = false;
          video.style.display = 'none';
          if (bild && this.hatBild) bild.style.display = 'block';
        };
        video.src = `/api/song/${index}/video`;
        video.load();
      }
    }
  }

  // Zieht das Video an den Ton heran.
  //
  // Massgeblich ist die Tonzeit, nicht das Video: Videoposition = VIDEOGAP +
  // Tonzeit, genau wie in UScreenSingController. Nachgezogen wird nur bei
  // spuerbarer Abweichung - jedes Bild neu zu setzen laesst es ruckeln.
  haltVideoNach(zeit) {
    const video = this.el.video;
    if (!this.hatVideo || !video) return;

    const ziel = zeit + this.song.videoGap;
    if (ziel < 0) {
      // Negativer VIDEOGAP: Das Video faengt spaeter an als der Ton. Bis
      // dahin steht es auf dem ersten Bild.
      if (!video.paused) video.pause();
      if (video.currentTime !== 0) video.currentTime = 0;
      return;
    }
    if (video.paused) video.play().catch(() => {});
    if (Math.abs(video.currentTime - ziel) > VIDEO_TOLERANZ)
      video.currentTime = ziel;
  }

  async ladeLied(index) {
    const txt = await fetch(`/api/song/${index}/txt`).then((r) => {
      if (!r.ok) throw new Error('Lied nicht ladbar');
      return r.text();
    });
    this.song = parseSong(txt);   // wirft bei kaputten Spurwechseln
    this.audio.src = `/api/song/${index}/audio`;
    this.el.titel.textContent = `${this.song.artist} – ${this.song.title}`;
    this.bereiteHintergrund(index, this.song);
    return this.song;
  }

  // Die verfuegbaren Mikrofone. Namen gibt der Browser erst nach einer
  // erteilten Freigabe heraus - vorher steht dort nur eine leere Zeichenkette.
  async listeMikrofone() {
    if (!navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices)
      return [];
    const alle = await navigator.mediaDevices.enumerateDevices();
    return alle
      .filter((g) => g.kind === 'audioinput')
      .map((g, i) => ({ deviceId: g.deviceId, label: g.label || `Mikrofon ${i + 1}` }));
  }

  // Einmalige Freigabe erfragen, damit enumerateDevices Namen liefert.
  async frageFreigabe() {
    try {
      const s = await navigator.mediaDevices.getUserMedia({ audio: true });
      s.getTracks().forEach((t) => t.stop());
      return true;
    } catch (e) {
      return false;
    }
  }

  async oeffneMikrofon(deviceId) {
    // Die drei Aufbereitungen muessen aus: Die Echounterdrueckung rechnet die
    // eigene Stimme weg, Rauschunterdrueckung und Pegelregelung verbiegen die
    // Tonhoehe. Fuer ein Telefonat ist das richtig, fuers Singen nicht.
    const wunsch = {
      echoCancellation: false,
      noiseSuppression: false,
      autoGainControl: false,
    };
    if (deviceId) wunsch.deviceId = { exact: deviceId };
    const strom = await navigator.mediaDevices.getUserMedia({ audio: wunsch });

    if (!this.ctx)
      this.ctx = new (window.AudioContext || window.webkitAudioContext)();
    const quelle = this.ctx.createMediaStreamSource(strom);
    const analyser = this.ctx.createAnalyser();
    analyser.fftSize = FFT_GROESSE;
    quelle.connect(analyser);
    return { analyser, puffer: new Float32Array(analyser.fftSize), strom };
  }

  // besetzung: [{ trackIndex, deviceId }] - ein Eintrag je mitsingender Stimme.
  // deviceId darf null sein; dann wird die Stimme angezeigt, aber nicht
  // gewertet.
  async start(besetzung) {
    if (!this.song) return;

    const belegt = new Set();
    for (const b of besetzung) {
      if (b.deviceId && belegt.has(b.deviceId))
        throw new Error('Zwei Stimmen koennen sich kein Mikrofon teilen - ' +
                        'die Aufnahmen liessen sich nicht auseinanderhalten.');
      if (b.deviceId) belegt.add(b.deviceId);
    }

    this.saenger = [];
    const hinweise = [];
    for (const b of besetzung) {
      const eintrag = {
        trackIndex: b.trackIndex,
        scorer: new Scorer(this.song, b.trackIndex),
        analyser: null,
        puffer: null,
        sungMidi: -1,
      };
      if (b.deviceId !== null && b.deviceId !== undefined) {
        try {
          const m = await this.oeffneMikrofon(b.deviceId);
          eintrag.analyser = m.analyser;
          eintrag.puffer = m.puffer;
          eintrag.strom = m.strom;
        } catch (e) {
          // Ohne Mikrofon laesst sich mitlesen - besser als gar nicht zu
          // starten, wenn jemand die Freigabe verweigert.
          hinweise.push(`${eintrag.scorer.name || 'Stimme'}: kein Mikrofon`);
        }
      }
      this.saenger.push(eintrag);
    }

    this.el.hinweis.textContent = hinweise.length
      ? hinweise.join(' · ') + ' - wird nicht gewertet.'
      : '';

    await this.audio.play();
    this.laeuft = true;
    requestAnimationFrame(() => this.schleife());
  }

  stop() {
    this.laeuft = false;
    this.audio.pause();
    if (this.el.video) this.el.video.pause();
    for (const s of this.saenger)
      if (s.strom) s.strom.getTracks().forEach((t) => t.stop());
  }

  zeileBei(trackIndex, beat) {
    return lineAt(this.song.track(trackIndex), beat);
  }

  schleife() {
    if (!this.laeuft) return;

    // Die Abspielposition ist der Takt, siehe Kopfkommentar.
    const zeit = this.audio.currentTime;
    const beat = this.song.timeToBeat(zeit);

    const bahnen = this.saenger.map((s) => {
      s.sungMidi = -1;
      if (s.analyser) {
        s.analyser.getFloatTimeDomainData(s.puffer);
        const f = detectFrequency(s.puffer, this.ctx.sampleRate);
        if (f > 0) s.sungMidi = freqToMidi(f);
        s.scorer.feed(zeit, s.sungMidi);
      }
      // Anteil je Note fuer die Einfaerbung.
      const anteile = new Map();
      for (const [note, z] of s.scorer.state)
        anteile.set(note, z.tries > 0 ? z.hits / z.tries : 0);

      const spur = this.song.track(s.trackIndex);
      return {
        line: lineAt(spur, beat),
        // Die naechste Zeile wird mit angezeigt, damit man weiss, was kommt.
        nextLine: nextLineAt(spur, beat),
        bars: s.scorer.bars,
        anteile,
        name: s.scorer.name,
        // Ohne Mikrofon keine Punktzahl, auch keine 0: Eine 0 hiesse
        // "danebengesungen", und das waere schlicht gelogen.
        score: s.analyser ? s.scorer.score : undefined,
      };
    });

    this.haltVideoNach(zeit);
    this.renderer.draw(bahnen, beat, this.hatVideo || this.hatBild);
    const stand = (s) => (s.analyser ? String(s.scorer.score) : '–');
    this.el.punkte.textContent = this.saenger.length > 1
      ? this.saenger.map(stand).join(' · ')
      : (this.saenger.length ? stand(this.saenger[0]) : '0');

    if (this.audio.ended) {
      this.laeuft = false;
      if (this.el.video) this.el.video.pause();
      const ergebnis = 'Fertig - ' + this.saenger
        .map((s) => s.analyser
          ? `${s.scorer.name}: ${s.scorer.score}`
          : `${s.scorer.name}: nicht gewertet`)
        .join(', ');
      this.el.hinweis.textContent = ergebnis;
      if (this.onEnde) this.onEnde(ergebnis);
      return;
    }
    requestAnimationFrame(() => this.schleife());
  }
}
