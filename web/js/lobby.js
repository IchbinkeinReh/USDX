// Mehrspieler-Lobbys: Beitreten, Punktzahlen und Wiedergabe ueber mehrere
// Browser hinweg abgleichen.
//
// Der Server wird per HTTP abgefragt, nicht per WebSocket - dieselbe
// Begruendung wie beim Suchfeld: kein neues Protokoll, keine offene
// Verbindung, passt in das bestehende Anfrage-Antwort-Muster. Zwischen zwei
// Abfragen laeuft die Wiedergabe lokal frei weiter und wird nur sanft
// nachgezogen, nie hart gesprungen - siehe driftKorrektur().

import { pfad } from './game.js';

// Wie oft der laufende Zustand abgefragt wird, waehrend eine Lobby besteht.
const ABFRAGE_MS = 1000;

// Sechsstelliger, rein numerischer Code - so, wie ihn der Server erzeugt
// und wie ihn jemand von Hand eintippt.
export function istGueltigerCode(text) {
  return typeof text === 'string' && /^\d{6}$/.test(text);
}

// Erwartete Wiedergabeposition (Sekunden) aus dem Server-Anker.
//
// serverStartMs/serverNowMs stammen aus DERSELBEN Zaehlung (siehe
// UWebLobby.AktuelleZeitMillis) - nicht zwingend die echte Unix-Zeit, aber
// in sich stimmig, und genau darauf kommt es hier an.
export function wiedergabePosition(serverStartMs, serverNowMs) {
  if (!(serverStartMs > 0) || !(serverNowMs > 0)) return 0;
  return Math.max(0, (serverNowMs - serverStartMs) / 1000);
}

// --- Uhrenabgleich ---
//
// Der Server schickt bei jeder Antwort seine eigene Zaehlung mit
// (serverNowMs). Sie NAIV mit Date.now() zu vergleichen geht daneben: Der
// Stempel entsteht auf dem Server, bevor die Antwort den Rueckweg antritt -
// bei gemessenen ~50 ms Umlaufzeit zu diesem Server waere der Versatz
// systematisch etwa 25 ms zu klein.
//
// Deshalb dieselbe Rechnung wie bei der Zeitsynchronisierung im Netz (NTP):
// Man merkt sich die eigene Zeit VOR dem Absenden (t0) und NACH dem Empfang
// (t1). Ist der Weg hin und zurueck etwa gleich lang, entstand der
// Serverstempel in der Mitte zwischen beiden:
//
//   Versatz = Serverstempel - (t0 + t1) / 2
//
// Uebrig bleibt der Fehler durch UNGLEICHE Wege hin und zurueck.
export function uhrVersatz(t0, serverMs, t1) {
  return serverMs - (t0 + t1) / 2;
}

// Wie viele Messungen betrachtet werden. Genommen wird nicht die neueste,
// sondern die mit der KUERZESTEN Umlaufzeit - auch das ist NTP-Praxis: Eine
// schnelle Antwort kann kaum ungleich verteilt gewesen sein, eine langsame
// dagegen beliebig. Die schnellste Messung ist damit die genaueste.
export const UHR_PROBEN = 8;

export class UhrAbgleich {
  constructor(maxProben = UHR_PROBEN) {
    this.maxProben = maxProben;
    this.proben = [];   // [{ versatz, umlauf }]
  }

  probe(t0, serverMs, t1) {
    const umlauf = t1 - t0;
    if (!(umlauf >= 0) || !Number.isFinite(serverMs)) return;
    this.proben.push({ versatz: uhrVersatz(t0, serverMs, t1), umlauf });
    if (this.proben.length > this.maxProben) this.proben.shift();
  }

  get bekannt() { return this.proben.length > 0; }

  // Der Versatz der schnellsten Messung im Fenster.
  get versatz() {
    if (this.proben.length === 0) return 0;
    let beste = this.proben[0];
    for (const p of this.proben) if (p.umlauf < beste.umlauf) beste = p;
    return beste.versatz;
  }

  // Die Serverzeit, wie sie JETZT sein duerfte - ohne neue Anfrage.
  //
  // Genau das macht die Genauigkeit aus: Vorher wurde gegen den Stempel der
  // letzten Antwort geprueft, der beim Anwenden schon eine Sekunde alt sein
  // konnte. Hochgerechnet ist er immer frisch.
  serverJetzt(jetzt = Date.now()) { return jetzt + this.versatz; }
}

// --- Nachfuehrung der Wiedergabe ---

// Unterhalb dieser Abweichung wird NICHT eingegriffen (Sekunden).
//
// Bewusst knapp: Schon wenige Millisekunden Versatz zwischen zwei Geraeten
// im selben Raum klingen nach Hall und stoeren beim Singen deutlich.
//
// Ganz auf null geht aber nicht. Der Uhrenabgleich selbst streut (gemessen
// etwa 3 ms), und audio.currentTime wird nur im Takt der Tonausgabe
// fortgeschrieben. Wer darunter regelt, jagt dieses Rauschen und macht es
// dadurch schlechter statt besser.
export const TOTZONE = 0.012;

// Ab hier wird hart gesprungen statt nachgezogen. Deutlich knapper als
// vorher: Ein Sprung ist einmal kurz hoerbar, eine Viertelsekunde
// Dauerversatz dagegen die ganze Zeit.
export const SPRUNG_AB = 0.12;

// Wie stark die Geschwindigkeit hoechstens abweichen darf. Die Tonhoehe
// bleibt dabei erhalten (siehe preservesPitch in game.js), sonst saenge man
// gegen eine verstimmte Begleitung an.
export const MAX_RATE_ABWEICHUNG = 0.06;

// Wie kraeftig auf eine Abweichung reagiert wird. 1,2 heisst: 50 ms
// Rueckstand ergeben 6 % mehr Geschwindigkeit (also gleich die Grenze).
// Zusammen mit dem schnellen Takt unten ist eine Abweichung damit in unter
// einer Sekunde abgebaut, statt wie vorher in mehreren.
export const RATE_VERSTAERKUNG = 1.2;

// Wie stark und wie korrigiert werden soll, wenn die eigene Wiedergabe von
// der erwarteten Position abweicht - nach dem Vorbild von haltVideoNach()
// in game.js: erst ab einer Toleranz eingreifen, und dann sanft, nicht hart.
//
// Anders als dort wird PROPORTIONAL geregelt, nicht mit einem festen Wert:
// Eine feste Abweichung von 3 % holt in zwei Sekunden nur 60 ms auf - eine
// halbe Sekunde Rueckstand braeuchte damit fast eine halbe Minute. Mit einem
// zur Abweichung passenden Wert, laufend angewendet, klingt der Fehler
// dagegen von selbst ab.
export function driftKorrektur(istSek, sollSek, opts = {}) {
  const totzone = opts.totzone ?? TOTZONE;
  const sprungAb = opts.sprungAb ?? SPRUNG_AB;
  const maxAbweichung = opts.maxAbweichung ?? MAX_RATE_ABWEICHUNG;
  const verstaerkung = opts.verstaerkung ?? RATE_VERSTAERKUNG;

  const delta = sollSek - istSek;   // positiv: die eigene Wiedergabe haengt hinterher
  const abs = Math.abs(delta);
  if (!(abs > totzone)) return { art: 'keine', wert: 1 };
  if (abs >= sprungAb) return { art: 'sprung', wert: sollSek };

  const roh = delta * verstaerkung;
  const begrenzt = Math.max(-maxAbweichung, Math.min(maxAbweichung, roh));
  return { art: 'rate', wert: 1 + begrenzt };
}

// Wenn niemand einen Namen eingetragen hat.
export const STANDARDNAME = 'Gast';

// Die Namensliste waehrend des Singens - ALLE Mitglieder, das eigene Geraet
// eingeschlossen.
//
// Bewusst KEINE eigenen Bahnen im Notenbild: Eine Bahn je Person nimmt ein
// Vielfaches des Platzes weg, den die Noten selbst brauchen. Geliefert wird
// nur, was in eine Zeile passt - Name und Punktzahl.
//
// eigenePunkte ist die Punktzahl je LOKALEM Saenger dieses Geraets. Singen
// hier zwei Leute mit (Solo zu zweit), wird der Eintrag in zwei aufgeteilt
// und mit "(1)"/"(2)" unterschieden - sonst staende derselbe Name zweimal
// da, ohne dass man die Punktzahlen auseinanderhalten koennte.
//
// Wer die Buehne verlassen hat (singt=false), bleibt mit "weg: true" stehen
// und wird durchgestrichen dargestellt: Man soll sehen, dass da jemand war
// und jetzt nicht mehr mitsingt. Wer die LOBBY verlassen hat, steht ohnehin
// nicht mehr in der Liste und verschwindet damit ganz.
export function mitspielerAnzeige(zustand, eigenePunkte = null) {
  if (!zustand || !Array.isArray(zustand.spieler)) return [];
  const eigene = Array.isArray(eigenePunkte) ? eigenePunkte : null;
  const liste = [];
  for (const s of zustand.spieler) {
    const name = (s.name || '').trim() || STANDARDNAME;
    if (s.isYou && eigene && eigene.length > 1) {
      eigene.forEach((p, i) => liste.push({
        name: `${name} (${i + 1})`,
        punkte: p == null || p < 0 ? null : p,
        weg: !s.singt,
        ich: true,
      }));
    } else if (s.isYou && eigene && eigene.length === 1) {
      liste.push({
        name,
        punkte: eigene[0] == null || eigene[0] < 0 ? null : eigene[0],
        weg: !s.singt,
        ich: true,
      });
    } else {
      liste.push({
        name,
        punkte: s.score == null ? null : s.score,
        weg: !s.singt,
        ich: !!s.isYou,
      });
    }
  }
  return liste;
}

// Duerfen alle losgesungen werden? Der Ersteller wartet, bis sich jeder
// andere bereitgemeldet hat - sonst faengt das Lied ohne die an, die noch
// ihr Mikrofon zuordnen.
//
// Der Ersteller selbst zaehlt nicht mit: Er ist es ja, der startet.
export function alleBereit(zustand) {
  if (!zustand || !Array.isArray(zustand.spieler)) return true;
  return zustand.spieler.every((s) => s.isYou || s.isHost || s.bereit);
}

// Wer noch fehlt - fuer die Anzeige "Warte auf ...".
export function fehlendeBereit(zustand) {
  if (!zustand || !Array.isArray(zustand.spieler)) return [];
  return zustand.spieler
    .filter((s) => !s.isYou && !s.isHost && !s.bereit)
    .map((s) => s.name);
}

// Wo die Wiedergabe laut Lobby JETZT stehen muesste.
//
// Waehrend einer Pause zaehlt nicht der Anker, sondern die festgehaltene
// Stelle - sonst liefe die Sollposition waehrend der Pause weiter, und beim
// Fortsetzen spraenge die Wiedergabe bei allen nach vorn.
export function sollPositionAus(zustand, serverJetztMs) {
  if (!zustand) return 0;
  if (zustand.pausiert) return Math.max(0, (zustand.pausePosMs || 0) / 1000);
  return wiedergabePosition(zustand.serverStartMs, serverJetztMs);
}

// Dasselbe fuer die angespielte Vorschau in der Liedauswahl. null heisst
// "kein Anker bekannt" - dann spielt jeder fuer sich, wie bisher.
export function vorschauSollPosition(zustand, serverJetztMs) {
  if (!zustand || !(zustand.vorschauStartMs > 0)) return null;
  return wiedergabePosition(zustand.vorschauStartMs, serverJetztMs);
}

// Ergaenzt Game.ergebnisListe() um die entfernten Mitspieler - nur die
// Gesamtpunktzahl ist bekannt, keine Aufschluesselung. "isYou" schliesst den
// eigenen Eintrag aus, der schon in lokal steht.
export function ergebnisMitFernspielern(lokal, zustand) {
  if (!zustand || !Array.isArray(zustand.spieler)) return lokal;
  const fern = zustand.spieler
    .filter((s) => !s.isYou)
    .map((s) => ({
      name: s.name,
      gewertet: s.score != null,
      punkte: s.score == null ? null : s.score,
      normal: null,
      golden: null,
      bonus: null,
    }));
  return [...lokal, ...fern];
}

// Die eigene Zeit vor dem Absenden und nach dem Empfang wird mitgeliefert -
// nur daraus laesst sich der Uhrenversatz sauber schaetzen (siehe
// uhrVersatz).
async function anfrage(pfadText, methode) {
  const t0 = Date.now();
  const antwort = await fetch(pfad(pfadText), { method: methode });
  const daten = await antwort.json().catch(() => null);
  return { ok: antwort.ok, status: antwort.status, daten, t0, t1: Date.now() };
}

// Haelt die Verbindung zu genau einer Lobby. token identifiziert dieses
// Geraet/diesen Tab gegenueber dem Server - wie und wo er aufbewahrt wird
// (sessionStorage o.ae.), entscheidet der Aufrufer, nicht diese Klasse.
//
// onZustand(zustand) wird nach jeder erfolgreichen Abfrage gerufen, mit
// zustand=null, wenn die Lobby nicht mehr existiert (Host weg, abgelaufen) -
// der Aufrufer entscheidet dann, wie es weitergeht, genau wie bei der
// singen=1-Rueckfallbehandlung in anwendenZustand (index.html).
//
// Generationszaehler wie _vorschauGen in game.js: Jeder trete()/erstelle()
// bricht eine laufende Abfrageschleife ab, statt gegen eine neuere
// anzuarbeiten.
export class LobbyClient {
  // punktzahlQuelle() wird bei JEDEM Abfrage-Takt frisch aufgerufen und
  // soll die eigene aktuelle Punktzahl liefern (oder -1/nichts, wenn noch
  // keine Wertung vorliegt) - so muss niemand von aussen daran denken, sie
  // laufend zu melden.
  // meldung() liefert bei jedem Abfrage-Takt frisch, was dieses Geraet ueber
  // sich sagt: { punkte, bereit, singt }. So muss niemand von aussen daran
  // denken, es laufend zu melden - und es kann nicht veralten.
  constructor(token, onZustand, meldung) {
    this.token = token;
    this.onZustand = onZustand || null;
    this.meldung = meldung || null;
    this._code = null;
    this._gen = 0;
    this._timerId = null;
    this._letzteSeq = 0;
    // Es darf immer nur EINE Abfrage unterwegs sein.
    //
    // Sonst passiert Folgendes: jetztAbfragen() ueberholt eine noch laufende
    // Abfrage, beide fragen mit demselben "since" und liefern dieselben
    // Reaktionen - die wurden dann doppelt angezeigt. Schlimmer noch: Am
    // Ende plant JEDE ihren eigenen naechsten Takt, und weil _timerId nur
    // einen davon kennt, laufen die zusaetzlichen Schleifen fuer immer
    // weiter und lassen sich nicht einmal mehr abstellen. Mit drei Leuten in
    // der Lobby (also mehr Statusmeldungen) trat das schnell auf.
    this._pollLaeuft = false;
    this._sofortNochmal = false;
    // Wird bei JEDER Antwort mitgefuehrt - auch bei erstellen/beitreten,
    // damit schon vor dem ersten Abfrage-Takt eine Schaetzung dasteht.
    this.uhr = new UhrAbgleich();
  }

  get code() { return this._code; }

  // Die Serverzeit, wie sie jetzt sein duerfte - Grundlage fuer jede
  // Soll-Position, damit nie gegen einen veralteten Stempel geregelt wird.
  serverJetzt() { return this.uhr.serverJetzt(); }

  _nimmZeit(antwort) {
    if (antwort && antwort.daten && Number.isFinite(antwort.daten.serverNowMs))
      this.uhr.probe(antwort.t0, antwort.daten.serverNowMs, antwort.t1);
  }

  _melde(zustand) {
    if (this.onZustand) this.onZustand(zustand);
  }

  // Der erste Zustand nach erstellen/beitreten.
  //
  // Er bringt den vorhandenen Reaktions-Rueckstand mit (diese Aufrufe kennen
  // kein "since"). Das sind aber keine Ereignisse, die JETZT passieren -
  // wuerde man sie melden, flaeche einem beim Beitreten alles entgegen, was
  // vorher schon getippt wurde, und die naechste Abfrage lieferte sie
  // gleich noch einmal. Also: Stand merken, Liste leeren.
  _ersterZustand(daten) {
    if (Array.isArray(daten.reaktionen) && daten.reaktionen.length) {
      this._letzteSeq = Math.max(this._letzteSeq,
                                 ...daten.reaktionen.map((r) => r.seq));
    }
    return { ...daten, reaktionen: [] };
  }

  _neueGeneration() {
    if (this._timerId !== null) { clearTimeout(this._timerId); this._timerId = null; }
    return ++this._gen;
  }

  _planeAbfrage(gen) {
    this._timerId = setTimeout(() => this._einePoll(gen), ABFRAGE_MS);
  }

  _meldeParameter(p) {
    const m = this.meldung ? this.meldung() : null;
    if (!m) return;
    if (Number.isFinite(m.punkte) && m.punkte >= 0)
      p.set('score', String(Math.round(m.punkte)));
    // Nur mitschicken, was wirklich bekannt ist - ein fehlender Parameter
    // heisst serverseitig "unveraendert lassen".
    if (typeof m.bereit === 'boolean') p.set('bereit', m.bereit ? '1' : '0');
    if (typeof m.singt === 'boolean') p.set('singt', m.singt ? '1' : '0');
  }

  async _einePoll(gen) {
    if (gen !== this._gen || !this._code) return;
    // Laeuft schon eine, wird sie nicht ueberholt - nur vorgemerkt, dass
    // gleich danach noch einmal gefragt werden soll (siehe _pollLaeuft).
    if (this._pollLaeuft) { this._sofortNochmal = true; return; }
    this._pollLaeuft = true;

    try {
      const p = new URLSearchParams({ token: this.token, since: String(this._letzteSeq) });
      this._meldeParameter(p);

      let antwort;
      try {
        antwort = await anfrage(`/api/lobby/${this._code}/state?${p}`, 'GET');
      } catch (e) {
        // Verbindung kurz weg - beim naechsten Takt erneut versuchen, nicht
        // gleich aufgeben.
        if (gen === this._gen) this._planeAbfrage(gen);
        return;
      }
      if (gen !== this._gen) return;

      if (!antwort.ok) {
        this._code = null;
        this._melde(null);
        return;
      }

      this._nimmZeit(antwort);
      const zustand = antwort.daten;
      if (Array.isArray(zustand.reaktionen) && zustand.reaktionen.length) {
        // Hoechster Wert, nicht einfach der letzte - so kann eine
        // verspaetete Antwort den Stand nicht zurueckdrehen und damit alte
        // Reaktionen ein zweites Mal hereinholen.
        this._letzteSeq = Math.max(
          this._letzteSeq,
          ...zustand.reaktionen.map((r) => r.seq));
      }
      this._melde(zustand);
      this._planeAbfrage(gen);
    } finally {
      this._pollLaeuft = false;
      if (this._sofortNochmal) {
        this._sofortNochmal = false;
        if (gen === this._gen && this._code) this.jetztAbfragen();
      }
    }
  }

  async erstelle(name) {
    const gen = this._neueGeneration();
    const p = new URLSearchParams({ token: this.token, name: name || '' });
    let antwort;
    try {
      antwort = await anfrage(`/api/lobby/create?${p}`, 'POST');
    } catch (e) {
      return false;
    }
    if (gen !== this._gen || !antwort.ok) return false;
    this._nimmZeit(antwort);
    this._code = antwort.daten.code;
    this._letzteSeq = 0;
    this._melde(this._ersterZustand(antwort.daten));
    this._planeAbfrage(gen);
    return true;
  }

  async trete(code, name) {
    const gen = this._neueGeneration();
    const p = new URLSearchParams({ token: this.token, name: name || '' });
    let antwort;
    try {
      antwort = await anfrage(`/api/lobby/${code}/join?${p}`, 'POST');
    } catch (e) {
      return false;
    }
    if (gen !== this._gen || !antwort.ok) return false;
    this._nimmZeit(antwort);
    this._code = antwort.daten.code;
    this._letzteSeq = 0;
    this._melde(this._ersterZustand(antwort.daten));
    this._planeAbfrage(gen);
    return true;
  }

  // Verlaesst die aktuelle Lobby und macht sofort eine neue, eigene auf -
  // "Lobby verlassen" soll nie ganz ohne Lobby enden.
  async verlasse(name) {
    const alterCode = this._code;
    const alterToken = this.token;
    this._neueGeneration();
    this._code = null;
    if (alterCode) {
      try {
        await anfrage(`/api/lobby/${alterCode}/leave?${new URLSearchParams({ token: alterToken })}`,
                      'POST');
      } catch (e) { /* Verbindung weg - trotzdem eine neue Lobby aufmachen */ }
    }
    return this.erstelle(name);
  }

  // Ein paar Messungen kurz hintereinander, um den Uhrenversatz zu schaerfen.
  //
  // Aus einer einzelnen Messung laesst sich der Versatz nur so gut schaetzen,
  // wie der Weg hin und zurueck gleich lang war - und das schwankt (hier
  // gemessen: 50 bis 62 ms Umlauf). Mehrere Messungen erlauben, die
  // schnellste zu nehmen, und die ist die verlaesslichste. Wird genau dann
  // gerufen, wenn es darauf ankommt: unmittelbar vor dem Losspielen.
  async synchronisiereUhr(anzahl = 4) {
    if (!this._code) return;
    for (let i = 0; i < anzahl; i++) {
      try {
        const p = new URLSearchParams({ token: this.token });
        const antwort = await anfrage(`/api/lobby/${this._code}/state?${p}`, 'GET');
        if (!antwort.ok) return;
        this._nimmZeit(antwort);
      } catch (e) {
        return;
      }
    }
  }

  // Nur der Ersteller darf waehlen/starten - der Server prueft das erneut
  // und weist einen falschen Token mit 403 zurueck.
  async waehle(index) {
    if (!this._code) return false;
    const p = new URLSearchParams({ token: this.token, index: String(index) });
    try {
      const antwort = await anfrage(`/api/lobby/${this._code}/select?${p}`, 'POST');
      return antwort.ok;
    } catch (e) {
      return false;
    }
  }

  async starte(serverStartMs) {
    if (!this._code) return false;
    const p = new URLSearchParams({
      token: this.token, serverStartMs: String(Math.round(serverStartMs)),
    });
    try {
      const antwort = await anfrage(`/api/lobby/${this._code}/start?${p}`, 'POST');
      return antwort.ok;
    } catch (e) {
      return false;
    }
  }

  // Schickt alle an denselben Ort und beendet dabei ein laufendes Lied
  // (nur Ersteller). ziel: 'auswahl', 'buehne' oder 'ergebnis'.
  //
  // Ein blosses "beenden" reichte nicht: Die Gaeste muessen unterscheiden
  // koennen, ob es zurueck in die Auswahl geht, noch einmal auf die Buehne
  // oder ob einfach das Lied vorbei ist.
  async setzeZiel(ziel) {
    if (!this._code) return false;
    const p = new URLSearchParams({ token: this.token, ziel });
    try {
      const antwort = await anfrage(`/api/lobby/${this._code}/ziel?${p}`, 'POST');
      return antwort.ok;
    } catch (e) {
      return false;
    }
  }

  // Pause fuer alle (nur Ersteller). posSek ist die Stelle, an der
  // angehalten wird - beim Fortsetzen rechnet der Server daraus den Anker neu.
  async pause(an, posSek) {
    if (!this._code) return false;
    const p = new URLSearchParams({
      token: this.token,
      an: an ? '1' : '0',
      pos: String(Math.max(0, Math.round((posSek || 0) * 1000))),
    });
    try {
      const antwort = await anfrage(`/api/lobby/${this._code}/pause?${p}`, 'POST');
      return antwort.ok;
    } catch (e) {
      return false;
    }
  }

  // Sagt der Lobby, ab wann die Vorschau laeuft (nur Ersteller).
  async vorschau(serverStartMs) {
    if (!this._code) return false;
    const p = new URLSearchParams({
      token: this.token, startMs: String(Math.round(serverStartMs)),
    });
    try {
      const antwort = await anfrage(`/api/lobby/${this._code}/vorschau?${p}`, 'POST');
      return antwort.ok;
    } catch (e) {
      return false;
    }
  }

  // Sofort abfragen statt auf den naechsten Takt zu warten - fuer Momente,
  // in denen die anderen es unmittelbar erfahren sollen (etwa "Bereit").
  jetztAbfragen() {
    if (!this._code) return;
    if (this._timerId !== null) { clearTimeout(this._timerId); this._timerId = null; }
    // _einePoll merkt selbst, wenn schon eine laeuft, und holt es dann
    // unmittelbar danach nach.
    this._einePoll(this._gen);
  }

  async reagiere(art) {
    if (!this._code) return false;
    const p = new URLSearchParams({ token: this.token, art });
    try {
      const antwort = await anfrage(`/api/lobby/${this._code}/react?${p}`, 'POST');
      return antwort.ok;
    } catch (e) {
      return false;
    }
  }

  // Beendet die Abfrageschleife, ohne die Lobby auf dem Server zu
  // verlassen - fuer Seitenwechsel/Aufraeumen, nicht fuer "Lobby verlassen".
  stop() {
    this._neueGeneration();
    this._code = null;
  }
}
