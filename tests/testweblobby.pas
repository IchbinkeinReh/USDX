program testweblobby;
(*
 * Prueft UWebLobby - die Mehrspieler-Lobbys.
 *
 * Wichtige Zusagen, dieselbe Art wie bei testwebbridge:
 *   - Nur der Ersteller (HostToken) darf ein Lied auswaehlen oder starten.
 *   - Abgelaufene Spieler/Lobbys werden von selbst entfernt, ohne eigenen
 *     Aufraeum-Thread.
 *   - Gleichzeitiger Zugriff ist gefahrlos.
 *)
{$MODE Delphi}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils,
  Classes,
  UWebLobby;

var
  Bestanden, Fehlgeschlagen: integer;
  Registry: TLobbyRegistry;
  NebenCode: UTF8String;
  NebenStoerung: boolean;

procedure Check(const Was: string; Bedingung: boolean; const Detail: string = '');
begin
  if Bedingung then
  begin
    Inc(Bestanden);
    WriteLn('  OK   ', Was);
  end
  else
  begin
    Inc(Fehlgeschlagen);
    WriteLn('  FEHL ', Was, '   ', Detail);
  end;
end;

// Haemmert auf einer gemeinsamen Lobby herum, waehrend der Haupttest
// gleichzeitig etwas anderes damit macht - Analog zu TSucher in
// testwebbridge.pas.
type
  TLobbyHammer = class(TThread)
    protected procedure Execute; override;
  end;

procedure TLobbyHammer.Execute;
var
  I: integer;
  Z: TLobbyZustand;
  S: int64;
begin
  for I := 1 to 500 do
  begin
    try
      if not Registry.GetState(NebenCode, 'neben-gast', I mod 100, -1, -1, Z) then
        NebenStoerung := true
      // Ein halb geschriebener Zustand waere leer oder ohne Code - beides
      // darf nicht vorkommen, auch nicht mitten in einer Aenderung.
      else if (Length(Z.Spieler) = 0) or (Z.Code <> NebenCode) then
        NebenStoerung := true;
      Registry.React(NebenCode, 'neben-gast', rkHoch, S);
    except
      NebenStoerung := true;
    end;
  end;
end;

var
  Code, RechteCode, LeerCode, RevCode, PunktCode, ReaktCode: UTF8String;
  AlterCode, VollCode, BereitCode, PauseCode, VorschauCode: UTF8String;
  VerlassCode: UTF8String;
  Zustand: TLobbyZustand;
  FalscherToken, KeinLied, Stimmt: boolean;
  AlteRevision, Seq, AlteZielNr: int64;
  Dummy, I: integer;
  Hammer: array[0..3] of TLobbyHammer;
begin
  Bestanden := 0; Fehlgeschlagen := 0;
  Registry := TLobbyRegistry.Create;

  WriteLn('Erstellen und Beitreten');
  Code := Registry.CreateLobby('host-token', 'Host');
  Check('Code ist 6-stellig numerisch',
        (Length(Code) = 6) and TryStrToInt(Code, Dummy), Code);

  Check('Ersteller kann den Zustand lesen',
        Registry.GetState(Code, 'host-token', -1, -1, -1, Zustand) and
        (Length(Zustand.Spieler) = 1));
  Check('Ersteller steht als Host', Zustand.HostToken = 'host-token');
  Check('anfangs kein Lied gewaehlt', Zustand.SongIndex = -1);
  Check('anfangs Phase wartet', Zustand.Phase = lphWartet);

  Check('Beitritt eines Gasts klappt',
        Registry.JoinLobby(Code, 'gast-token', 'Gast'));
  Registry.GetState(Code, 'host-token', -1, -1, -1, Zustand);
  Check('jetzt zwei Spieler', Length(Zustand.Spieler) = 2,
        IntToStr(Length(Zustand.Spieler)));

  Check('unbekannter Code beim Beitreten schlaegt fehl',
        not Registry.JoinLobby('000000', 'x', 'X'));

  // Erneuter Beitritt desselben Tokens - kein zweiter Eintrag, sonst zaehlte
  // ein Neuladen als neuer Mitspieler.
  Check('erneuter Beitritt desselben Tokens klappt',
        Registry.JoinLobby(Code, 'gast-token', 'Gast2'));
  Registry.GetState(Code, 'host-token', -1, -1, -1, Zustand);
  Check('immer noch zwei Spieler, kein Duplikat',
        Length(Zustand.Spieler) = 2, IntToStr(Length(Zustand.Spieler)));
  Check('der Name wird dabei aufgefrischt',
        Zustand.Spieler[1].Name = 'Gast2', Zustand.Spieler[1].Name);

  WriteLn('Obergrenze der Spieleranzahl');
  VollCode := Registry.CreateLobby('voll-host', 'VH');
  for I := 1 to LOBBY_MAX_PLAYERS - 1 do
    Check('Spieler ' + IntToStr(I) + ' passt noch rein',
          Registry.JoinLobby(VollCode, 'voll-gast-' + IntToStr(I), 'G'));
  Registry.GetState(VollCode, 'voll-host', -1, -1, -1, Zustand);
  Check('Lobby ist jetzt am Limit',
        Length(Zustand.Spieler) = LOBBY_MAX_PLAYERS,
        IntToStr(Length(Zustand.Spieler)));
  Check('ein weiterer Beitritt scheitert',
        not Registry.JoinLobby(VollCode, 'ueberzaehlig', 'Zuviel'));

  WriteLn('Nur der Ersteller darf waehlen und starten');
  RechteCode := Registry.CreateLobby('r-host', 'RH');
  Registry.JoinLobby(RechteCode, 'r-gast', 'RG');

  Check('Gast darf kein Lied auswaehlen',
        (not Registry.SelectSong(RechteCode, 'r-gast', 5, FalscherToken))
        and FalscherToken);
  Check('Host darf auswaehlen',
        Registry.SelectSong(RechteCode, 'r-host', 5, FalscherToken)
        and not FalscherToken);
  Check('unbekannte Lobby beim Auswaehlen meldet nicht FalscherToken',
        (not Registry.SelectSong('000000', 'irgendwer', 1, FalscherToken))
        and not FalscherToken);

  Check('Gast darf nicht starten',
        (not Registry.StartSinging(RechteCode, 'r-gast', 1000,
                                   FalscherToken, KeinLied))
        and FalscherToken and not KeinLied);

  LeerCode := Registry.CreateLobby('leer-host', 'LH');
  Check('ohne gewaehltes Lied meldet StartSinging KeinLiedGewaehlt',
        (not Registry.StartSinging(LeerCode, 'leer-host', 1000,
                                   FalscherToken, KeinLied))
        and KeinLied and not FalscherToken);

  Check('Host darf nach Auswahl starten',
        Registry.StartSinging(RechteCode, 'r-host', 123456,
                              FalscherToken, KeinLied)
        and not FalscherToken and not KeinLied);
  Registry.GetState(RechteCode, 'r-host', -1, -1, -1, Zustand);
  Check('Phase steht jetzt auf singt', Zustand.Phase = lphSingt);
  Check('Anker wurde uebernommen', Zustand.ServerStartMs = 123456,
        IntToStr(Zustand.ServerStartMs));

  Check('eine neue Auswahl geht auch waehrend des Singens',
        Registry.SelectSong(RechteCode, 'r-host', 6, FalscherToken));
  Registry.GetState(RechteCode, 'r-host', -1, -1, -1, Zustand);
  Check('und setzt die Phase zurueck auf wartet', Zustand.Phase = lphWartet);

  WriteLn('Revisionszaehler');
  RevCode := Registry.CreateLobby('rev-host', 'RevH');
  Registry.GetState(RevCode, 'rev-host', -1, -1, -1, Zustand);
  AlteRevision := Zustand.Revision;
  Registry.JoinLobby(RevCode, 'rev-gast', 'RevG');
  Registry.GetState(RevCode, 'rev-host', -1, -1, -1, Zustand);
  Check('Beitritt erhoeht die Revision', Zustand.Revision > AlteRevision,
        IntToStr(Zustand.Revision));
  AlteRevision := Zustand.Revision;
  Registry.SelectSong(RevCode, 'rev-host', 1, FalscherToken);
  Registry.GetState(RevCode, 'rev-host', -1, -1, -1, Zustand);
  Check('Auswahl erhoeht die Revision', Zustand.Revision > AlteRevision);

  WriteLn('Punktzahl melden');
  PunktCode := Registry.CreateLobby('p-host', 'PH');
  Registry.GetState(PunktCode, 'p-host', -1, -1, -1, Zustand);
  Check('anfangs keine Wertung', Zustand.Spieler[0].Score = -1);
  Registry.GetState(PunktCode, 'p-host', 4210, -1, -1, Zustand);
  Check('Punktzahl wird uebernommen', Zustand.Spieler[0].Score = 4210,
        IntToStr(Zustand.Spieler[0].Score));
  Registry.GetState(PunktCode, 'p-host', -1, -1, -1, Zustand);
  Check('bleibt erhalten, wenn nicht erneut gemeldet',
        Zustand.Spieler[0].Score = 4210);

  WriteLn('Reaktionsschlange');
  ReaktCode := Registry.CreateLobby('react-host', 'ReactH');
  for I := 1 to LOBBY_MAX_REAKTIONEN + 10 do
    Registry.React(ReaktCode, 'react-host', rkHoch, Seq);
  Registry.GetState(ReaktCode, 'react-host', -1, -1, -1, Zustand);
  Check('Schlange bleibt begrenzt',
        Length(Zustand.Reaktionen) = LOBBY_MAX_REAKTIONEN,
        IntToStr(Length(Zustand.Reaktionen)));
  Check('die AELTESTEN wurden verworfen, nicht die neuesten',
        Zustand.Reaktionen[High(Zustand.Reaktionen)].Seq >
        Zustand.Reaktionen[0].Seq);
  Check('unbekannte Lobby liefert bei React false',
        not Registry.React('000000', 'x', rkHoch, Seq));

  // Der Name kommt mit - die Anzeige stellt ihn neben das Emoji. Der Token
  // darf dafuer NICHT herhalten.
  Registry.JoinLobby(ReaktCode, 'react-gast', 'Berta');
  Registry.React(ReaktCode, 'react-gast', rkRunter, Seq);
  Registry.GetState(ReaktCode, 'react-host', -1, -1, -1, Zustand);
  Check('die Reaktion traegt den Namen',
        Zustand.Reaktionen[High(Zustand.Reaktionen)].Name = 'Berta',
        Zustand.Reaktionen[High(Zustand.Reaktionen)].Name);
  Check('und die richtige Art',
        Zustand.Reaktionen[High(Zustand.Reaktionen)].Art = rkRunter);
  // Nach dem Verwerfen aelterer Eintraege muessen die verbliebenen Namen
  // noch stimmen - beim Nachruecken wird eine Zeichenkette umkopiert, und
  // ein roher Speicherumzug haette hier laengst Unsinn hinterlassen.
  for I := 1 to LOBBY_MAX_REAKTIONEN do
    Registry.React(ReaktCode, 'react-gast', rkHoch, Seq);
  Registry.GetState(ReaktCode, 'react-host', -1, -1, -1, Zustand);
  Stimmt := True;
  for I := 0 to High(Zustand.Reaktionen) do
    if (Zustand.Reaktionen[I].Name <> 'Berta') then Stimmt := False;
  Check('Namen ueberstehen das Nachruecken der Schlange', Stimmt);

  WriteLn('Vorschau-Anker');
  VorschauCode := Registry.CreateLobby('v-host', 'VH');
  Registry.JoinLobby(VorschauCode, 'v-gast', 'VG');
  Registry.GetState(VorschauCode, 'v-host', -1, -1, -1, Zustand);
  Check('anfangs kein Vorschau-Anker', Zustand.VorschauStartMs = 0);
  Check('Gast darf ihn nicht setzen',
        (not Registry.SetVorschau(VorschauCode, 'v-gast', 7777, FalscherToken))
        and FalscherToken);
  Check('der Host darf',
        Registry.SetVorschau(VorschauCode, 'v-host', 7777, FalscherToken));
  Registry.GetState(VorschauCode, 'v-gast', -1, -1, -1, Zustand);
  Check('und der Gast sieht ihn', Zustand.VorschauStartMs = 7777,
        IntToStr(Zustand.VorschauStartMs));
  // Ein neues Lied macht den alten Anker ungueltig - sonst spielte die
  // Vorschau des neuen Liedes an der Stelle des alten los.
  Registry.SelectSong(VorschauCode, 'v-host', 1, FalscherToken);
  Registry.GetState(VorschauCode, 'v-host', -1, -1, -1, Zustand);
  Check('ein neues Lied setzt den Vorschau-Anker zurueck',
        Zustand.VorschauStartMs = 0, IntToStr(Zustand.VorschauStartMs));

  WriteLn('Verlassen');
  VerlassCode := Registry.CreateLobby('vl-host', 'VlH');
  Registry.JoinLobby(VerlassCode, 'vl-gast', 'VlG');
  Registry.JoinLobby(VerlassCode, 'vl-gast2', 'VlG2');

  // Ein Gast geht: Die Lobby bleibt, nur er verschwindet.
  Registry.LeaveLobby(VerlassCode, 'vl-gast');
  Check('nach dem Austritt eines Gasts gibt es die Lobby noch',
        Registry.GetState(VerlassCode, 'vl-host', -1, -1, -1, Zustand));
  Check('und er steht nicht mehr drin',
        Length(Zustand.Spieler) = 2, IntToStr(Length(Zustand.Spieler)));
  Stimmt := True;
  for I := 0 to High(Zustand.Spieler) do
    if (Zustand.Spieler[I].Token = 'vl-gast') then Stimmt := False;
  Check('naemlich wirklich er', Stimmt);

  // Ein unbekannter Token aendert nichts - und wirft nicht.
  Registry.LeaveLobby(VerlassCode, 'gibtsnicht');
  Registry.GetState(VerlassCode, 'vl-host', -1, -1, -1, Zustand);
  Check('ein fremder Token laesst die Lobby unberuehrt',
        Length(Zustand.Spieler) = 2);

  // Geht der ERSTELLER, endet die Lobby fuer alle - es gibt keinen
  // Nachfolger. Die Verbliebenen bekommen beim naechsten Abruf ein Nein und
  // machen daraufhin ihre eigene Lobby auf.
  Registry.LeaveLobby(VerlassCode, 'vl-host');
  Check('der Austritt des Erstellers beendet die Lobby',
        not Registry.GetState(VerlassCode, 'vl-host', -1, -1, -1, Zustand));
  Check('auch fuer die Verbliebenen',
        not Registry.GetState(VerlassCode, 'vl-gast2', -1, -1, -1, Zustand));
  Check('und Beitreten geht danach auch nicht mehr',
        not Registry.JoinLobby(VerlassCode, 'spaet', 'Spaet'));

  Registry.LeaveLobby('000000', 'x');   // darf einfach nichts tun
  Check('Verlassen einer unbekannten Lobby ist folgenlos', True);

  WriteLn('Bereitschaft und Buehne melden');
  BereitCode := Registry.CreateLobby('b-host', 'BH');
  Registry.JoinLobby(BereitCode, 'b-gast', 'BG');
  Registry.GetState(BereitCode, 'b-host', -1, -1, -1, Zustand);
  Check('anfangs ist niemand bereit',
        (not Zustand.Spieler[0].Bereit) and (not Zustand.Spieler[1].Bereit));
  Check('und niemand auf der Buehne',
        (not Zustand.Spieler[0].Singt) and (not Zustand.Spieler[1].Singt));

  Registry.GetState(BereitCode, 'b-gast', -1, 1, 1, Zustand);
  Registry.GetState(BereitCode, 'b-host', -1, -1, -1, Zustand);
  Check('der Gast meldet sich bereit', Zustand.Spieler[1].Bereit);
  Check('und steht auf der Buehne', Zustand.Spieler[1].Singt);
  Check('der Host bleibt davon unberuehrt', not Zustand.Spieler[0].Bereit);

  // -1 heisst "unveraendert" - sonst wuerde jeder gewoehnliche Abruf die
  // Bereitschaft aus Versehen loeschen.
  Registry.GetState(BereitCode, 'b-gast', 500, -1, -1, Zustand);
  Check('ein Abruf ohne Angabe aendert die Bereitschaft nicht',
        Zustand.Spieler[1].Bereit and Zustand.Spieler[1].Singt);

  // Die Buehne verlassen, aber in der Lobby bleiben - genau der Fall, den
  // die Anzeige durchgestrichen darstellt.
  Registry.GetState(BereitCode, 'b-gast', -1, -1, 0, Zustand);
  Registry.GetState(BereitCode, 'b-host', -1, -1, -1, Zustand);
  Check('Buehne verlassen wird gemeldet', not Zustand.Spieler[1].Singt);
  Check('bereit bleibt davon unberuehrt', Zustand.Spieler[1].Bereit);
  Check('und der Spieler bleibt in der Lobby',
        Length(Zustand.Spieler) = 2, IntToStr(Length(Zustand.Spieler)));

  AlteRevision := Zustand.Revision;
  Registry.GetState(BereitCode, 'b-gast', -1, -1, 0, Zustand);
  Registry.GetState(BereitCode, 'b-host', -1, -1, -1, Zustand);
  Check('unveraenderte Meldung erhoeht die Revision nicht',
        Zustand.Revision = AlteRevision,
        IntToStr(Zustand.Revision) + ' statt ' + IntToStr(AlteRevision));

  WriteLn('Ziel fuer alle vorgeben');
  Registry.SelectSong(BereitCode, 'b-host', 3, FalscherToken);
  Registry.GetState(BereitCode, 'b-gast', -1, 1, 1, Zustand);
  Registry.StartSinging(BereitCode, 'b-host', 5000, FalscherToken, KeinLied);
  Check('Gast darf kein Ziel vorgeben',
        (not Registry.SetZiel(BereitCode, 'b-gast', lzErgebnis, FalscherToken))
        and FalscherToken);
  Check('der Host darf',
        Registry.SetZiel(BereitCode, 'b-host', lzErgebnis, FalscherToken));
  Registry.GetState(BereitCode, 'b-host', -1, -1, -1, Zustand);
  Check('Phase steht wieder auf wartet', Zustand.Phase = lphWartet);
  Check('das Ziel ist das Ergebnis', Zustand.Ziel = lzErgebnis);
  // Das Lied bleibt beim Ergebnis ausdruecklich stehen - "Nochmal singen"
  // geht von hier aus direkt auf die Buehne, OHNE das Lied neu zu waehlen.
  // Waere es hier schon geloescht, meldete /start faelschlich "kein Lied
  // ausgewaehlt" (genau der Fehler, der einmal live aufgetreten ist).
  Check('das Lied bleibt fuer "Nochmal singen" erhalten',
        Zustand.SongIndex = 3, IntToStr(Zustand.SongIndex));
  // Nach einem Abbruch muss sich jeder neu bereitmelden - sonst startete die
  // naechste Runde ungefragt bei denen mit, die gerade nicht am Geraet sind.
  Check('die Bereitschaft ist zurueckgesetzt',
        (not Zustand.Spieler[0].Bereit) and (not Zustand.Spieler[1].Bereit));
  Check('und niemand steht mehr auf der Buehne',
        (not Zustand.Spieler[0].Singt) and (not Zustand.Spieler[1].Singt));

  // "Nochmal singen": alle zurueck auf die Buehne - genau hier lag der Fehler.
  AlteZielNr := Zustand.ZielNr;
  Registry.SetZiel(BereitCode, 'b-host', lzBuehne, FalscherToken);
  Registry.GetState(BereitCode, 'b-host', -1, -1, -1, Zustand);
  Check('Ziel Buehne kommt an', Zustand.Ziel = lzBuehne);
  Check('und die Zielnummer steigt', Zustand.ZielNr > AlteZielNr);
  // Der eigentliche Fehlerfall: Losspielen OHNE vorher neu auszuwaehlen
  // muss gelingen, weil das Lied ja dasselbe bleibt.
  Check('Nochmal singen laesst sich starten, ohne neu auszuwaehlen',
        Registry.StartSinging(BereitCode, 'b-host', 5500, FalscherToken, KeinLied)
        and not KeinLied);

  // Der entscheidende Punkt: ZWEIMAL dasselbe Ziel muss zweimal zaehlen.
  // Sonst bekaeme ein Gast den zweiten Druck auf "Anderes Lied" gar nicht
  // mit - das Ziel allein aendert sich dabei ja nicht.
  Registry.SetZiel(BereitCode, 'b-host', lzAuswahl, FalscherToken);
  Registry.GetState(BereitCode, 'b-host', -1, -1, -1, Zustand);
  AlteZielNr := Zustand.ZielNr;
  // Anders als beim Ergebnis: Zurueck in die Auswahl heisst, dass dort ein
  // (womoeglich neues) Lied gewaehlt wird - das alte gilt nicht mehr.
  Check('zurueck in die Auswahl loescht das Lied',
        Zustand.SongIndex = -1, IntToStr(Zustand.SongIndex));
  Registry.SetZiel(BereitCode, 'b-host', lzAuswahl, FalscherToken);
  Registry.GetState(BereitCode, 'b-host', -1, -1, -1, Zustand);
  Check('dasselbe Ziel erneut zaehlt trotzdem als neue Ansage',
        Zustand.ZielNr > AlteZielNr,
        IntToStr(Zustand.ZielNr) + ' vs ' + IntToStr(AlteZielNr));

  // Losspielen schickt ebenfalls auf die Buehne - aber ohne neue Ansage:
  // Das erkennen die Gaeste an der Phase, ein zweites Signal wuerde sie nur
  // noch einmal dorthin schicken.
  Registry.SelectSong(BereitCode, 'b-host', 3, FalscherToken);
  Registry.GetState(BereitCode, 'b-host', -1, -1, -1, Zustand);
  AlteZielNr := Zustand.ZielNr;
  Registry.StartSinging(BereitCode, 'b-host', 6000, FalscherToken, KeinLied);
  Registry.GetState(BereitCode, 'b-host', -1, -1, -1, Zustand);
  Check('Losspielen setzt das Ziel auf die Buehne', Zustand.Ziel = lzBuehne);
  Check('erhoeht die Zielnummer aber nicht',
        Zustand.ZielNr = AlteZielNr,
        IntToStr(Zustand.ZielNr) + ' vs ' + IntToStr(AlteZielNr));

  // Ein neues Lied schickt alle in die Auswahl - dort waehlt man aus.
  Registry.SelectSong(BereitCode, 'b-host', 5, FalscherToken);
  Registry.GetState(BereitCode, 'b-host', -1, -1, -1, Zustand);
  Check('ein neues Lied schickt alle in die Auswahl',
        (Zustand.Ziel = lzAuswahl) and (Zustand.ZielNr > AlteZielNr));

  Check('unbekannte Lobby beim Ziel: kein falscher Token gemeldet',
        (not Registry.SetZiel('000000', 'x', lzAuswahl, FalscherToken))
        and not FalscherToken);

  // Ein neues Lied setzt ebenfalls zurueck, samt Punktzahlen des vorigen.
  Registry.GetState(BereitCode, 'b-gast', 7000, 1, 1, Zustand);
  Registry.SelectSong(BereitCode, 'b-host', 4, FalscherToken);
  Registry.GetState(BereitCode, 'b-host', -1, -1, -1, Zustand);
  Check('ein neues Lied setzt die Bereitschaft zurueck',
        not Zustand.Spieler[1].Bereit);
  Check('und die Punktzahl des vorigen Liedes',
        Zustand.Spieler[1].Score = -1, IntToStr(Zustand.Spieler[1].Score));

  WriteLn('Pause fuer alle');
  PauseCode := Registry.CreateLobby('pa-host', 'PaH');
  Registry.JoinLobby(PauseCode, 'pa-gast', 'PaG');
  Registry.SelectSong(PauseCode, 'pa-host', 2, FalscherToken);
  Registry.StartSinging(PauseCode, 'pa-host', 1000, FalscherToken, KeinLied);

  Check('Gast darf nicht pausieren',
        (not Registry.SetPause(PauseCode, 'pa-gast', True, 4000, FalscherToken))
        and FalscherToken);
  Check('der Host darf',
        Registry.SetPause(PauseCode, 'pa-host', True, 4000, FalscherToken));
  Registry.GetState(PauseCode, 'pa-host', -1, -1, -1, Zustand);
  Check('die Lobby steht auf pausiert', Zustand.Pausiert);
  Check('und merkt sich die Stelle', Zustand.PausePosMs = 4000,
        IntToStr(Zustand.PausePosMs));
  Check('die Phase bleibt dabei singt', Zustand.Phase = lphSingt);

  // Beim Fortsetzen muss der Anker so nachgezogen werden, dass es dort
  // weitergeht, wo angehalten wurde - sonst spraenge die Wiedergabe bei
  // allen um die Dauer der Pause nach vorn.
  Registry.SetPause(PauseCode, 'pa-host', False, 0, FalscherToken);
  Registry.GetState(PauseCode, 'pa-host', -1, -1, -1, Zustand);
  Check('nach dem Fortsetzen laeuft es wieder', not Zustand.Pausiert);
  Check('der Anker zeigt auf die Pausenstelle, nicht auf den alten Start',
        Abs((Zustand.ServerNowMs - Zustand.ServerStartMs) - 4000) < 500,
        IntToStr(Zustand.ServerNowMs - Zustand.ServerStartMs));

  // Ein Neustart hebt eine bestehende Pause auf.
  Registry.SetPause(PauseCode, 'pa-host', True, 9000, FalscherToken);
  Registry.StartSinging(PauseCode, 'pa-host', 2000, FalscherToken, KeinLied);
  Registry.GetState(PauseCode, 'pa-host', -1, -1, -1, Zustand);
  Check('ein Neustart hebt die Pause auf', not Zustand.Pausiert);

  Check('unbekannte Lobby: kein falscher Token gemeldet',
        (not Registry.SetPause('000000', 'x', True, 0, FalscherToken))
        and not FalscherToken);

  WriteLn('Aufraeumen abgelaufener Lobbys und Spieler');
  AlterCode := Registry.CreateLobby('alt-host', 'AltH');
  Registry.JoinLobby(AlterCode, 'alt-gast', 'AltG');

  // Nur den GAST zurueckdatieren - er soll verschwinden, die Lobby bleibt.
  Registry.SetzeLastSeenFuerTest(AlterCode, 'alt-gast',
    Now - ((LOBBY_TTL_SECONDS + 30) / 86400.0));
  Registry.GetState(AlterCode, 'alt-host', -1, -1, -1, Zustand);
  Check('abgelaufener Gast verschwindet, Lobby bleibt bestehen',
        (Length(Zustand.Spieler) = 1) and
        (Zustand.Spieler[0].Token = 'alt-host'),
        IntToStr(Length(Zustand.Spieler)));

  // Jetzt den HOST zurueckdatieren - die ganze Lobby soll enden.
  Registry.SetzeLastSeenFuerTest(AlterCode, 'alt-host',
    Now - ((LOBBY_TTL_SECONDS + 30) / 86400.0));
  Check('abgelaufener Host beendet die ganze Lobby',
        not Registry.GetState(AlterCode, 'alt-host', -1, -1, -1, Zustand));

  WriteLn('Gleichzeitiger Zugriff');
  NebenStoerung := False;
  NebenCode := Registry.CreateLobby('neben-host', 'NebenHost');
  Registry.JoinLobby(NebenCode, 'neben-gast', 'NebenGast');

  for I := 0 to High(Hammer) do
    Hammer[I] := TLobbyHammer.Create(False);
  for I := 1 to 300 do
  begin
    Registry.SelectSong(NebenCode, 'neben-host', I mod 50, FalscherToken);
    Registry.JoinLobby(NebenCode, 'neben-weiterer-' + IntToStr(I mod 5), 'X');
  end;
  for I := 0 to High(Hammer) do
    Hammer[I].WaitFor;
  for I := 0 to High(Hammer) do
    Hammer[I].Free;
  Check('kein Absturz, keine halben Zustaende', not NebenStoerung);

  Registry.Free;

  WriteLn;
  WriteLn(Format('%d bestanden, %d fehlgeschlagen', [Bestanden, Fehlgeschlagen]));
  if Fehlgeschlagen > 0 then
    Halt(1);
end.
