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

import { parseSong, lineAt, nextLineAt, singAbschnitte, previewRange } from './song.js';
import { detectMidi, maxVolume } from './pitch.js';
import { Pegel } from './pegel.js';
import { Scorer, LEICHT } from './score.js';
import { Renderer } from './render.js';

const FFT_GROESSE = 4096;

// Adressen ohne Zugangsdaten bauen.
//
// Wer die Seite mit Zugangsdaten in der Adresse aufruft - also
// https://name:wort@rechner/ - vererbt die an jede relative Adresse. Chrome
// verweigert dann sowohl fetch als auch das Laden von Ton, Video und Bild:
// "Request cannot be constructed from a URL that includes credentials".
// Die Seite blieb dadurch leer.
//
// Deshalb wird jede Adresse ausdruecklich gegen eine bereinigte Basis
// aufgeloest. Ohne Zugangsdaten in der Adresse aendert das nichts.
export function basisOhneZugangsdaten(href) {
  try {
    const u = new URL(href);
    u.username = '';
    u.password = '';
    u.search = '';
    u.hash = '';
    return u.toString();
  } catch (e) {
    return href;
  }
}

// Wohin gespult wird. Getrennt, weil sich hier leicht vertut, wer die
// Grenzen von Hand hinschreibt: Vor den Anfang darf es nicht gehen, und ans
// aeusserste Ende auch nicht - dort gilt das Lied sofort als beendet, und
// statt zu spulen kaeme die Ergebnisseite.
export const SPUL_RESERVE = 0.25;

export function spulZiel(jetzt, dauer, delta) {
  if (!(dauer > 0)) return 0;
  const ziel = (Number.isFinite(jetzt) ? jetzt : 0) +
               (Number.isFinite(delta) ? delta : 0);
  return Math.max(0, Math.min(dauer - SPUL_RESERVE, ziel));
}

export function pfad(p, href) {
  const basis = basisOhneZugangsdaten(
    href !== undefined ? href
      : (typeof location !== 'undefined' ? location.href : ''));
  try {
    return new URL(p, basis).toString();
  } catch (e) {
    return p;
  }
}

// Ab wie viel Abweichung das Video nachgezogen wird. Jedes Bild neu zu
// setzen laesst es ruckeln; gar nicht nachzuziehen laesst es davonlaufen.
const VIDEO_TOLERANZ = 0.30;

// Lautstaerke der Vorschau in der Liedauswahl - Ini.PreviewVolume steht im
// Original standardmaessig auf 30% (UIni.pas: ReadVolumePercent(..., 30)).
export const VORSCHAU_LAUTSTAERKE = 0.30;
export const VORSCHAU_FADE_MS = 1000;

// Wie weit eine Blende zwischen 0 (Anfang) und 1 (Ende) fortgeschritten ist.
//
// Eigene, pruefbare Funktion, weil genau hier ein fehlender unterer Anschlag
// zu einer leicht negativen Lautstaerke gefuehrt hat: audio.volume wies das
// mit einer IndexSizeError zurueck, und weil das in einem
// requestAnimationFrame-Callback geschah, blieb der Fehler stumm - die
// Vorschau setzte beim Liedwechsel einfach aus. Der Grund: Der Zeitstempel,
// den requestAnimationFrame liefert, ist der Beginn des Bildes und kann vor
// dem performance.now() liegen, das synchron kurz zuvor lief.
export function blendFortschritt(jetzt, beginn, dauerMs) {
  if (!(dauerMs > 0)) return 1;
  return Math.max(0, Math.min(1, (jetzt - beginn) / dauerMs));
}

export class Game {
  constructor(canvas, elemente) {
    this.renderer = new Renderer(canvas);
    this.el = elemente;
    this.audio = new Audio();
    this.audio.preload = 'auto';
    // Eigenes Element fuer die Vorschau in der Liedauswahl - getrennt von
    // this.audio, das dem eigentlichen Singen gehoert. Zusammen auf einem
    // Element liesse sich beim Liedwechsel nicht erst ausblenden: Sobald
    // src sich aendert, verstummt der Ton sofort, kein Uebergang mehr
    // moeglich.
    this.vorschauAudio = new Audio();
    this.vorschauAudio.preload = 'auto';
    this.vorschauAudio.volume = 0;
    this._vorschauGen = 0;
    this._vorschauWaechterAbmelden = null;
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
        bild.src = pfad(`/api/song/${index}/background`);
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
        video.src = pfad(`/api/song/${index}/video`);
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
    const txt = await fetch(pfad(`/api/song/${index}/txt`)).then((r) => {
      if (!r.ok) throw new Error('Lied nicht ladbar');
      return r.text();
    });
    this.song = parseSong(txt);   // wirft bei kaputten Spurwechseln
    // Einmal berechnen, nicht je Bild - das sind alle Zeilen des Liedes.
    this.abschnitte = singAbschnitte(this.song);
    this.audio.src = pfad(`/api/song/${index}/audio`);
    this.el.titel.textContent = `${this.song.artist} – ${this.song.title}`;
    this.bereiteHintergrund(index, this.song);
    return this.song;
  }

  // Blendet die Lautstaerke der Vorschau ueber DAUER Millisekunden auf ZIEL.
  // Generation dient dem Abbruch: Wechselt waehrenddessen das Lied noch
  // einmal, bricht diese Schleife sich selbst ab, statt gegen eine neuere
  // Ein-/Ausblendung anzuarbeiten.
  _vorschauUeberblenden(ziel, dauerMs, generation) {
    return new Promise((resolve) => {
      const audio = this.vorschauAudio;
      const start = audio.volume;
      if (dauerMs <= 0 || start === ziel) {
        audio.volume = ziel;
        resolve();
        return;
      }
      const beginn = performance.now();
      const schritt = (jetzt) => {
        if (generation !== this._vorschauGen) { resolve(); return; }
        const t = blendFortschritt(jetzt, beginn, dauerMs);
        audio.volume = start + (ziel - start) * t;
        if (t < 1) requestAnimationFrame(schritt);
        else resolve();
      };
      requestAnimationFrame(schritt);
    });
  }

  // Wartet, bis die Dauer der Vorschau-Audiodatei bekannt ist - erst dann
  // laesst sich previewRange() berechnen.
  _vorschauDauerAbwarten(audio) {
    return new Promise((resolve, reject) => {
      if (audio.readyState >= 1 && audio.duration > 0) { resolve(); return; }
      const weg = () => {
        audio.removeEventListener('loadedmetadata', weg);
        audio.removeEventListener('error', fehler);
        resolve();
      };
      const fehler = () => {
        audio.removeEventListener('loadedmetadata', weg);
        audio.removeEventListener('error', fehler);
        reject(new Error('Vorschau nicht ladbar'));
      };
      audio.addEventListener('loadedmetadata', weg);
      audio.addEventListener('error', fehler);
    });
  }

  _vorschauEndeAbmelden() {
    if (this._vorschauWaechterAbmelden) {
      this._vorschauWaechterAbmelden();
      this._vorschauWaechterAbmelden = null;
    }
  }

  // Wie PreviewEnd im Spiel (TScreenSong.Draw): sobald die Abspielposition
  // das Ende der Vorschau erreicht, wird angehalten statt in den Rest des
  // Liedes weiterzulaufen.
  _vorschauEndeUeberwachen(ende, generation) {
    this._vorschauEndeAbmelden();
    const audio = this.vorschauAudio;
    const pruefen = () => {
      if (generation !== this._vorschauGen) return;
      if (ende > 0 && audio.currentTime >= ende) this.vorschauStop();
    };
    audio.addEventListener('timeupdate', pruefen);
    this._vorschauWaechterAbmelden =
      () => audio.removeEventListener('timeupdate', pruefen);
  }

  // Spielt die Vorschau eines ausgewaehlten Liedes an - wie im Spiel
  // (TScreenSong.StartMusicPreview): nicht von vorne, sondern ab
  // previewRange() (song.js), und leiser als beim eigentlichen Singen.
  //
  // Anders als im Original wird eine laufende Vorschau erst ausgeblendet,
  // bevor die naechste einblendet - dort wird nur hart umgeschaltet, aber
  // zwei Lieder ohne jeden Uebergang klingt auf einer Auswahlseite falsch,
  // auf der man schneller weiterklickt als im Spiel selbst.
  async vorschauStarten(index, song) {
    const gen = ++this._vorschauGen;
    await this.vorschauAusblenden(gen);
    if (gen !== this._vorschauGen) return;

    const audio = this.vorschauAudio;
    this._vorschauEndeAbmelden();
    audio.pause();
    audio.src = pfad(`/api/song/${index}/audio`);
    audio.volume = 0;
    audio.load();

    try {
      await this._vorschauDauerAbwarten(audio);
    } catch (e) {
      return;
    }
    if (gen !== this._vorschauGen) return;

    const bereich = previewRange(song, audio.duration || 0);
    audio.currentTime = bereich.start;
    this._vorschauEndeUeberwachen(bereich.end, gen);

    try {
      await audio.play();
    } catch (e) {
      return;   // Autoplay verweigert - kein Grund, die Auswahl zu stoeren.
    }
    if (gen !== this._vorschauGen) return;
    await this._vorschauUeberblenden(VORSCHAU_LAUTSTAERKE, VORSCHAU_FADE_MS, gen);
  }

  // Blendet eine laufende Vorschau aus. vorGen ist die Generation, gegen die
  // ein Abbruch geprueft wird - beim Aufruf aus vorschauStarten() ist das
  // schon die NEUE Generation, damit eine dritte Auswahl mitten im Ausblenden
  // auch dieses Ausblenden noch abbricht.
  async vorschauAusblenden(vorGen) {
    const audio = this.vorschauAudio;
    if (audio.paused || audio.volume === 0) { audio.pause(); return; }
    await this._vorschauUeberblenden(0, VORSCHAU_FADE_MS,
                                     vorGen === undefined ? this._vorschauGen : vorGen);
    audio.pause();
  }

  // Sofortiges Ende ohne Ausblenden - wenn tatsaechlich gesungen wird, soll
  // nicht noch eine Sekunde lang leise die Vorschau mitlaufen.
  vorschauStop() {
    this._vorschauGen++;   // laufende Ein-/Ausblendungen brechen sich selbst ab
    this._vorschauEndeAbmelden();
    this.vorschauAudio.pause();
    this.vorschauAudio.volume = 0;
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
      echoCancellation: true,
      noiseSuppression: false,
      autoGainControl: false,
    };
    if (deviceId) wunsch.deviceId = { exact: deviceId };
    const strom = await navigator.mediaDevices.getUserMedia({ audio: wunsch });

    if (!this.ctx)
      this.ctx = new (window.AudioContext || window.webkitAudioContext)();
    const quelle = this.ctx.createMediaStreamSource(strom);

    // Verstaerkung in die Kette, VOR der Auswertung. Genau die
    // Pegelregelung, die oben mit autoGainControl:false abgeschaltet wurde -
    // nur eben eine, die den Ton nicht verbiegt: ein glatter Faktor, keine
    // Kompression, keine Rauschunterdrueckung.
    const verstaerker = this.ctx.createGain();
    verstaerker.gain.value = 1;

    const analyser = this.ctx.createAnalyser();
    analyser.fftSize = FFT_GROESSE;
    // Roh mitschneiden, um den echten Pegel zu messen: Am verstaerkten
    // Signal liesse sich der Faktor nicht mehr bestimmen, man regelte gegen
    // die eigene Regelung.
    const rohAnalyser = this.ctx.createAnalyser();
    rohAnalyser.fftSize = FFT_GROESSE;

    quelle.connect(rohAnalyser);
    quelle.connect(verstaerker);
    verstaerker.connect(analyser);

    return {
      analyser, rohAnalyser, verstaerker, strom,
      puffer: new Float32Array(analyser.fftSize),
      rohPuffer: new Float32Array(rohAnalyser.fftSize),
    };
  }

  // besetzung: [{ trackIndex, deviceId }] - ein Eintrag je mitsingender Stimme.
  // deviceId darf null sein; dann wird die Stimme angezeigt, aber nicht
  // gewertet. schwierigkeit steuert, wie weit daneben noch zaehlt.
  async start(besetzung, schwierigkeit = LEICHT) {
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
        // Beim Solo zu zweit singen beide dieselbe Spur; dann taugt der
        // Spurname nicht als Beschriftung, weil beide Bahnen gleich hiessen.
        name: b.name || null,
        scorer: new Scorer(this.song, b.trackIndex, schwierigkeit),
        analyser: null,
        puffer: null,
        sungMidi: -1,
        pegel: new Pegel(),
      };
      if (b.deviceId !== null && b.deviceId !== undefined) {
        try {
          const m = await this.oeffneMikrofon(b.deviceId);
          eintrag.analyser = m.analyser;
          eintrag.puffer = m.puffer;
          eintrag.rohAnalyser = m.rohAnalyser;
          eintrag.rohPuffer = m.rohPuffer;
          eintrag.verstaerker = m.verstaerker;
          eintrag.strom = m.strom;
        } catch (e) {
          // Ohne Mikrofon laesst sich mitlesen - besser als gar nicht zu
          // starten, wenn jemand die Freigabe verweigert.
          hinweise.push(
            `${eintrag.name || eintrag.scorer.name || 'Stimme'}: kein Mikrofon`);
        }
      }
      this.saenger.push(eintrag);
    }

    this.el.hinweis.textContent = hinweise.length
      ? hinweise.join(' · ') + ' - wird nicht gewertet.'
      : '';

    // Von vorne beginnen - sonst haengt bei "Nochmal singen" die Zeit vom
    // vorigen Durchlauf noch am Audioelement, etwa weil zuvor mitten im
    // Lied das Vollbild verlassen wurde.
    this.audio.currentTime = 0;
    await this.audio.play();
    this.laeuft = true;
    requestAnimationFrame(() => this.schleife());
  }

  // Was die Ergebnisseite braucht - die Oberflaeche soll nicht in den
  // Wertungen herumsuchen muessen.
  ergebnisListe() {
    return this.saenger.map((s) => {
      const teile = s.scorer.teilwertung();
      return {
        name: s.name || s.scorer.name,
        gewertet: !!s.analyser,
        punkte: s.analyser ? s.scorer.score : null,
        normal: teile.normal,
        golden: teile.golden,
        bonus: teile.bonus,
      };
    });
  }

  // Beendet das Lied und meldet das Ergebnis. Wird sowohl am Ende des
  // Stuecks aufgerufen als auch beim Abbrechen - beide Male soll das
  // Ergebnis erscheinen.
  beende() {
    if (!this.laeuft) return;
    this.laeuft = false;
    this.audio.pause();
    if (this.el.video) this.el.video.pause();
    if (this.onEnde) this.onEnde(this.ergebnisListe());
  }

  // Vor- und zurueckspulen.
  //
  // Die Wertung zieht mit: Uebersprungene Zeilen werden beim naechsten Bild
  // als beendet verbucht und bringen dann keinen Bonus - was richtig ist,
  // gesungen wurde dort ja nichts. Zurueckgespulte Zeilen bleiben verbucht;
  // ihren Bonus gibt es kein zweites Mal.
  spulen(sekunden) {
    if (!this.song || !(this.audio.duration > 0)) return;
    this.audio.currentTime =
      spulZiel(this.audio.currentTime, this.audio.duration, sekunden);
  }

  stop() {
    this.laeuft = false;
    this.audio.pause();
    if (this.el.video) this.el.video.pause();
    for (const s of this.saenger)
      if (s.strom) s.strom.getTracks().forEach((t) => t.stop());
  }

  // Ende der letzten Note, als Ausweichwert fuer die Dauer.
  liedEnde() {
    const a = this.abschnitte;
    return a && a.length ? a[a.length - 1].bis : 0;
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
        // Erst am ROHEN Signal messen und die Regelung nachfuehren. Die
        // Schranke wird ebenfalls hier geprueft, nicht am verstaerkten:
        // Die Verstaerkung wird gedaempft nachgezogen und hinkt dem
        // berechneten Faktor hinterher - man verglich sonst gegen eine
        // Lautstaerke, die noch gar nicht anliegt, und verwarf zu viel.
        s.rohAnalyser.getFloatTimeDomainData(s.rohPuffer);
        const spitze = maxVolume(s.rohPuffer);
        s.pegel.fuettern(spitze, zeit);
        const faktor = s.pegel.berechneFaktor();
        if (s.verstaerker) {
          // Sanft nachziehen statt springen - ein harter Sprung im
          // Verstaerkungsfaktor knackt hoerbar in der Kette.
          s.verstaerker.gain.setTargetAtTime(faktor, this.ctx.currentTime, 0.1);
        }

        if (spitze >= s.pegel.schwelle()) {
          // Ausgewertet wird das verstaerkte Signal. Die Schranke steht auf
          // 0, weil sie oben schon geprueft wurde - wie im Spiel, wo nach
          // der Lautstaerkepruefung immer ein Ton herauskommt.
          s.analyser.getFloatTimeDomainData(s.puffer);
          s.sungMidi = detectMidi(s.puffer, this.ctx.sampleRate, 0);
        }
        s.scorer.feed(zeit, s.sungMidi);
      }
      const spur = this.song.track(s.trackIndex);
      // Die Bewertung der eben beendeten Zeile, samt ihrem Alter - die
      // Anzeige entscheidet selbst, wie lange sie sie zeigt.
      const lz = s.scorer.letzteZeile;
      return {
        zeilenLob: lz ? { ...lz, alter: zeit - lz.zeit } : null,
        line: lineAt(spur, beat),
        // Die naechste Zeile wird mit angezeigt, damit man weiss, was kommt.
        nextLine: nextLineAt(spur, beat),
        bars: s.scorer.bars,
        name: s.name || s.scorer.name,
        // Ohne Mikrofon keine Punktzahl, auch keine 0: Eine 0 hiesse
        // "danebengesungen", und das waere schlicht gelogen. Die Anzeige
        // erkennt daran auch, dass sie die Noten ganz weglassen kann.
        score: s.analyser ? s.scorer.score : undefined,
      };
    });

    this.haltVideoNach(zeit);
    this.renderer.draw(bahnen, beat, this.hatVideo || this.hatBild, {
      zeit,
      // Solange die Dauer noch nicht bekannt ist, hilft das letzte Ende
      // aus dem Lied - sonst bliebe die Leiste am Anfang leer.
      dauer: this.audio.duration > 0 ? this.audio.duration : this.liedEnde(),
      abschnitte: this.abschnitte,
    }, this.song.isDuet);

    if (this.audio.ended) {
      this.beende();
      return;
    }
    requestAnimationFrame(() => this.schleife());
  }
}
