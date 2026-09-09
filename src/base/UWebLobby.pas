unit UWebLobby;

(*
 * Mehrspieler-Lobbys fuer die Weboberflaeche.
 *
 * Bewusst eine EIGENE Einheit, getrennt von UWebBridge: Der Liederkatalog
 * dort und der fluechtige Mehrspieler-Zustand hier sind unterschiedliche
 * Belange - ein gemeinsames Schloss wuerde beide unnoetig ausbremsen, und
 * Tests fuer das eine sollten sich nicht um das andere kuemmern muessen.
 *
 * Genau wie UWebBridge laeuft das hier NIE ueber den Spielthread - eine
 * Lobby betrifft nur Mitgliedschaft, Punktzahlen und den Gleichlauf der
 * Wiedergabe zwischen Browsern. Die eigentliche Liedauswahl AM GERAET
 * selbst (falls dort jemand sitzt) bleibt weiterhin Sache von
 * TWebBridge.PostCommand/NextCommand und beruehrt diese Einheit nicht.
 *
 * Kein eigener Aufraeum-Thread: Jede oeffentliche Methode raeumt zu Beginn
 * (unter dem schon gehaltenen Schloss) selbst auf. Das genuegt bei der
 * erwarteten Groessenordnung (eine Handvoll Lobbys fuer eine Runde im
 * selben Netz) vollauf und erspart einen zweiten Hintergrund-Thread neben
 * dem Webserver-Thread.
 *)

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

interface

uses
  SysUtils, Classes, SyncObjs;

const
  // Kein Zugriff (Poll oder Aktion) in dieser Zeit -> gilt als verlassen.
  // Grosszuegig ueber dem ~1-Sekunden-Abfragetakt, damit ein kurz
  // gedrosselter Hintergrund-Tab nicht faelschlich rausfliegt.
  LOBBY_TTL_SECONDS = 180;
  // Genug fuer eine Feier-Runde; schuetzt vor Wachstum ohne Ende.
  LOBBY_MAX_PLAYERS = 16;
  // Begrenzte Reaktions-Schlange, genau wie MAX_BEFEHLE in UWebBridge -
  // lieber ein verlorenes Emoji als unbegrenztes Wachstum.
  LOBBY_MAX_REAKTIONEN = 32;

type
  TLobbyPhase = (lphWartet, lphSingt);

  // Wo die Mitglieder gerade sein sollen.
  //
  // Die Phase allein genuegt dafuer nicht: "Nochmal singen" und "Anderes
  // Lied" enden beide bei lphWartet und waeren fuer die Gaeste nicht zu
  // unterscheiden - und nach dem Ende eines Liedes aendert sich die Phase
  // ueberhaupt nicht mehr, sodass ein spaeterer Tastendruck des Erstellers
  // gar nicht ankaeme. Das Ziel sagt es ausdruecklich.
  TLobbyZiel = (lzAuswahl, lzBuehne, lzErgebnis);

  TReaktionsArt = (rkHoch, rkRunter);

  TLobbyReaktion = record
    Seq: int64;
    Art: TReaktionsArt;
    // Wer reagiert hat - die Anzeige stellt den Namen neben das Emoji.
    // Der Name, NICHT der Token: Der geht niemanden etwas an.
    Name: UTF8String;
  end;

  TLobbySpieler = record
    Token: UTF8String;
    Name: UTF8String;
    Score: integer;        // -1 = noch keine Wertung gemeldet
    Bereit: boolean;       // hat "Bereit"/"Singen" getippt
    Singt: boolean;        // ist gerade auf der Buehne (nicht abgesprungen)
    LastSeen: TDateTime;
  end;

  // Abschrift fuer den Aufrufer - kein Zeiger auf das interne Array.
  // Dient intern zugleich als Speicherform selbst, siehe TLobbyRegistry.
  TLobbyZustand = record
    Code: UTF8String;
    HostToken: UTF8String;      // NIE nach aussen (JSON) weitergeben!
    Spieler: array of TLobbySpieler;   // Spieler[i].Token ebenfalls geheim halten
    SongIndex: integer;         // -1 = nichts gewaehlt
    Phase: TLobbyPhase;
    Ziel: TLobbyZiel;
    // Zaehlt jedes Mal hoch, wenn der Ersteller ein Ziel vorgibt.
    //
    // Das Ziel allein genuegt nicht: Drueckt er zweimal hintereinander
    // "Anderes Lied", bliebe der Wert derselbe und die Gaeste merkten den
    // zweiten Druck nicht. Es ist ein Ereignis, kein Zustand - und Ereignisse
    // zaehlt man.
    ZielNr: int64;
    ServerStartMs: int64;       // Ankerpunkt: Audiozeit 0 entspricht dieser Zeit
    ServerNowMs: int64;         // "jetzt", frisch bei jedem GetState gesetzt
    // Pause haelt die Wiedergabe fuer ALLE an. Waehrenddessen zaehlt nicht
    // der Anker, sondern die festgehaltene Stelle - beim Fortsetzen wird der
    // Anker daraus neu berechnet.
    Pausiert: boolean;
    PausePosMs: int64;
    // Anker fuer die ANGESPIELTE VORSCHAU in der Liedauswahl - dieselbe
    // Rechnung wie ServerStartMs, nur fuer das Vorschau-Tonelement. 0 heisst
    // "keine Vorschau angekuendigt".
    VorschauStartMs: int64;
    Revision: int64;            // "Stand"-Idiom aus UWebBridge
    Reaktionen: array of TLobbyReaktion;
  end;

  TLobbyRegistry = class
  private
    fLock: TCriticalSection;
    fLobbies: array of TLobbyZustand;
    function IndexVonCode(const Code: UTF8String): integer;   // nur unter Lock
    function NeuerCode: UTF8String;                            // nur unter Lock
    procedure Aufraeumen(Jetzt: TDateTime);                    // nur unter Lock
  public
    constructor Create;
    destructor Destroy; override;

    function CreateLobby(const HostToken, HostName: UTF8String): UTF8String;
    function JoinLobby(const Code, Token, Name: UTF8String): boolean;
    procedure LeaveLobby(const Code, Token: UTF8String);

    // Liest den Zustand und zaehlt zugleich als Lebenszeichen von Token.
    // Score/Bereit/Singt werden dabei gleich mitgemeldet - so reicht EIN
    // Aufruf pro Abfrage-Takt fuer alles, was ein Mitglied ueber sich sagt.
    // -1 heisst jeweils "unveraendert lassen", 0/1 setzt.
    function GetState(const Code, Token: UTF8String;
                      Score, Bereit, Singt: integer;
                      out Zustand: TLobbyZustand): boolean;

    // Nur der Ersteller (HostToken) darf waehlen/starten.
    function SelectSong(const Code, Token: UTF8String; SongIndex: integer;
                       out FalscherToken: boolean): boolean;
    function StartSinging(const Code, Token: UTF8String; ServerStartMs: int64;
                         out FalscherToken, KeinLiedGewaehlt: boolean): boolean;

    // Schickt ALLE an denselben Ort und beendet dabei ein laufendes Lied.
    //
    // Ersetzt das fruehere StopSinging: Nur "aufhoeren" genuegt nicht, weil
    // die Gaeste sonst nicht wissen, ob es zurueck in die Auswahl geht
    // ("Anderes Lied"), noch einmal auf die Buehne ("Nochmal singen") oder
    // ob einfach das Lied zu Ende ist.
    //
    // Die Bereitschaft wird dabei zurueckgesetzt: Nach jedem Wechsel muss
    // sich jeder neu bereitmelden, sonst startete die naechste Runde
    // ungefragt bei denen mit, die gerade gar nicht am Geraet sind.
    function SetZiel(const Code, Token: UTF8String; Ziel: TLobbyZiel;
                    out FalscherToken: boolean): boolean;

    // Pause fuer alle. PosMs ist die Stelle, an der angehalten wird; beim
    // Fortsetzen wird der Anker daraus neu berechnet.
    function SetPause(const Code, Token: UTF8String; An: boolean; PosMs: int64;
                     out FalscherToken: boolean): boolean;

    // Sagt der Lobby, ab wann die Vorschau des gewaehlten Liedes laeuft -
    // damit sie bei allen an derselben Stelle spielt.
    function SetVorschau(const Code, Token: UTF8String; StartMs: int64;
                        out FalscherToken: boolean): boolean;

    function React(const Code, Token: UTF8String; Art: TReaktionsArt;
                   out Seq: int64): boolean;

    function LobbyCount: integer;   // fuer Tests/Diagnose

    // NUR fuer Tests: setzt LastSeen direkt, ohne auf die echte Uhr zu
    // warten - sonst liesse sich das Aufraeumen nicht ohne echte
    // Wartezeit von LOBBY_TTL_SECONDS pruefen.
    procedure SetzeLastSeenFuerTest(const Code, Token: UTF8String; Zeit: TDateTime);
  end;

implementation

// Millisekunden-Zaehlung fuer den Wiedergabe-Anker.
//
// Bewusst NICHT die echte Unix-Zeit: Das braeuchte eine
// Zeitzonen-Umrechnung (dieser Server laeuft in MEZ/MESZ, nicht UTC), und
// deren Zuverlaessigkeit haengt vom Betriebssystem ab. Noetig ist das auch
// gar nicht - der Client gleicht die Differenz zwischen zwei Werten DIESER
// Funktion mit seiner eigenen Uhr (Date.now()) ab, und dafuer genuegt eine
// im Server gleichbleibende Zaehlung. Eine feste Verschiebung zur echten
// Unix-Zeit (z.B. durch die Zeitzone) kuerzt sich beim Abgleich heraus.
//
// GetTickCount64 statt Now, obwohl beide auf diesem Rechner
// millisekundengenau sind (nachgemessen): Es laeuft MONOTON. Now ist die
// oertliche Wanduhr - eine Zeitumstellung oder ein Zeitabgleich per NTP
// verschoebe sie mitten im Lied um Sekunden bis Stunden, und der Anker
// waere schlagartig falsch. Fuer eine reine Differenzmessung ist eine
// monotone Zaehlung ohnehin das richtige Werkzeug.
function AktuelleZeitMillis: int64;
begin
  Result := int64(GetTickCount64);
end;

// Schreibt einen 6-stelligen Code, mit fuehrenden Nullen.
function FormatiereCode(Zahl: integer): UTF8String;
begin
  Result := Format('%.6d', [Zahl]);
end;

constructor TLobbyRegistry.Create;
begin
  inherited Create;
  fLock := TCriticalSection.Create;
  Randomize;
end;

destructor TLobbyRegistry.Destroy;
begin
  fLock.Free;
  inherited;
end;

function TLobbyRegistry.IndexVonCode(const Code: UTF8String): integer;
var
  I: integer;
begin
  Result := -1;
  for I := 0 to High(fLobbies) do
    if (fLobbies[I].Code = Code) then
    begin
      Result := I;
      Exit;
    end;
end;

function TLobbyRegistry.NeuerCode: UTF8String;
var
  Versuch: integer;
begin
  for Versuch := 1 to 20 do
  begin
    Result := FormatiereCode(Random(1000000));
    if (IndexVonCode(Result) < 0) then Exit;
  end;
  // In der Praxis unerreichbar: 20 Fehlversuche in Folge braeuchten schon
  // zehntausende gleichzeitige Lobbys.
  raise Exception.Create('Konnte keinen freien Lobby-Code finden');
end;

// Entfernt abgelaufene Lobbys/Spieler. Laeuft unter dem schon gehaltenen
// Schloss - kein eigener Thread, siehe Kopfkommentar.
procedure TLobbyRegistry.Aufraeumen(Jetzt: TDateTime);
var
  I, J: integer;
  Grenze: TDateTime;
  HostWeg: boolean;
begin
  Grenze := Jetzt - (LOBBY_TTL_SECONDS / 86400.0);

  I := 0;
  while I <= High(fLobbies) do
  begin
    // Ist der HOST selbst abgelaufen, endet die ganze Lobby - kein
    // Host-Wechsel in dieser Fassung. Gaeste bekommen beim naechsten Poll
    // ein 404 und fangen das wie eine abgelaufene Lobby ab.
    HostWeg := True;
    for J := 0 to High(fLobbies[I].Spieler) do
      if (fLobbies[I].Spieler[J].Token = fLobbies[I].HostToken) then
      begin
        HostWeg := fLobbies[I].Spieler[J].LastSeen < Grenze;
        Break;
      end;

    if HostWeg then
    begin
      fLobbies[I] := fLobbies[High(fLobbies)];
      SetLength(fLobbies, Length(fLobbies) - 1);
      Continue;   // NICHT I erhoehen - an dieser Stelle steht jetzt was Neues
    end;

    // Einzelne abgelaufene Gaeste entfernen (der Host bleibt sicher stehen,
    // siehe oben - er waere sonst schon behandelt).
    J := 0;
    while J <= High(fLobbies[I].Spieler) do
    begin
      if (fLobbies[I].Spieler[J].Token <> fLobbies[I].HostToken) and
         (fLobbies[I].Spieler[J].LastSeen < Grenze) then
      begin
        fLobbies[I].Spieler[J] := fLobbies[I].Spieler[High(fLobbies[I].Spieler)];
        SetLength(fLobbies[I].Spieler, Length(fLobbies[I].Spieler) - 1);
        Continue;
      end;
      Inc(J);
    end;

    Inc(I);
  end;
end;

function TLobbyRegistry.CreateLobby(const HostToken, HostName: UTF8String): UTF8String;
var
  Z: TLobbyZustand;
begin
  fLock.Acquire;
  try
    Aufraeumen(Now);

    Z.Code := NeuerCode;
    Z.HostToken := HostToken;
    SetLength(Z.Spieler, 1);
    Z.Spieler[0].Token := HostToken;
    Z.Spieler[0].Name := HostName;
    Z.Spieler[0].Score := -1;
    Z.Spieler[0].Bereit := False;
    Z.Spieler[0].Singt := False;
    Z.Spieler[0].LastSeen := Now;
    Z.SongIndex := -1;
    Z.Phase := lphWartet;
    Z.Ziel := lzAuswahl;
    Z.ZielNr := 0;
    Z.ServerStartMs := 0;
    Z.Pausiert := False;
    Z.PausePosMs := 0;
    Z.VorschauStartMs := 0;
    Z.Revision := 1;
    SetLength(Z.Reaktionen, 0);

    SetLength(fLobbies, Length(fLobbies) + 1);
    fLobbies[High(fLobbies)] := Z;
    Result := Z.Code;
  finally
    fLock.Release;
  end;
end;

function TLobbyRegistry.JoinLobby(const Code, Token, Name: UTF8String): boolean;
var
  Idx, I, Neu: integer;
begin
  Result := False;
  fLock.Acquire;
  try
    Aufraeumen(Now);
    Idx := IndexVonCode(Code);
    if (Idx < 0) then Exit;

    // Schon dabei? Nur Name/Lebenszeichen auffrischen - sonst zaehlte ein
    // Neuladen als zweiter Spieler.
    for I := 0 to High(fLobbies[Idx].Spieler) do
      if (fLobbies[Idx].Spieler[I].Token = Token) then
      begin
        fLobbies[Idx].Spieler[I].Name := Name;
        fLobbies[Idx].Spieler[I].LastSeen := Now;
        Result := True;
        Exit;
      end;

    if (Length(fLobbies[Idx].Spieler) >= LOBBY_MAX_PLAYERS) then Exit;

    SetLength(fLobbies[Idx].Spieler, Length(fLobbies[Idx].Spieler) + 1);
    Neu := High(fLobbies[Idx].Spieler);
    fLobbies[Idx].Spieler[Neu].Token := Token;
    fLobbies[Idx].Spieler[Neu].Name := Name;
    fLobbies[Idx].Spieler[Neu].Score := -1;
    fLobbies[Idx].Spieler[Neu].Bereit := False;
    fLobbies[Idx].Spieler[Neu].Singt := False;
    fLobbies[Idx].Spieler[Neu].LastSeen := Now;
    Inc(fLobbies[Idx].Revision);
    Result := True;
  finally
    fLock.Release;
  end;
end;

procedure TLobbyRegistry.LeaveLobby(const Code, Token: UTF8String);
var
  Idx, I: integer;
begin
  fLock.Acquire;
  try
    Aufraeumen(Now);
    Idx := IndexVonCode(Code);
    if (Idx < 0) then Exit;

    if (fLobbies[Idx].HostToken = Token) then
    begin
      // Der Host verlaesst seine eigene Lobby - sie endet fuer alle, kein
      // Host-Wechsel in dieser Fassung.
      fLobbies[Idx] := fLobbies[High(fLobbies)];
      SetLength(fLobbies, Length(fLobbies) - 1);
      Exit;
    end;

    for I := 0 to High(fLobbies[Idx].Spieler) do
      if (fLobbies[Idx].Spieler[I].Token = Token) then
      begin
        fLobbies[Idx].Spieler[I] := fLobbies[Idx].Spieler[High(fLobbies[Idx].Spieler)];
        SetLength(fLobbies[Idx].Spieler, Length(fLobbies[Idx].Spieler) - 1);
        Inc(fLobbies[Idx].Revision);
        Exit;
      end;
  finally
    fLock.Release;
  end;
end;

function TLobbyRegistry.GetState(const Code, Token: UTF8String;
                                 Score, Bereit, Singt: integer;
                                 out Zustand: TLobbyZustand): boolean;
var
  Idx, I: integer;
begin
  Result := False;
  fLock.Acquire;
  try
    Aufraeumen(Now);
    Idx := IndexVonCode(Code);
    if (Idx < 0) then Exit;

    for I := 0 to High(fLobbies[Idx].Spieler) do
      if (fLobbies[Idx].Spieler[I].Token = Token) then
      begin
        fLobbies[Idx].Spieler[I].LastSeen := Now;
        if (Score >= 0) then
          fLobbies[Idx].Spieler[I].Score := Score;
        // Aendert sich etwas an Bereitschaft oder Buehne, muss die Revision
        // steigen - die anderen sollen es an ihrer Anzeige merken.
        if (Bereit >= 0) and (fLobbies[Idx].Spieler[I].Bereit <> (Bereit <> 0)) then
        begin
          fLobbies[Idx].Spieler[I].Bereit := Bereit <> 0;
          Inc(fLobbies[Idx].Revision);
        end;
        if (Singt >= 0) and (fLobbies[Idx].Spieler[I].Singt <> (Singt <> 0)) then
        begin
          fLobbies[Idx].Spieler[I].Singt := Singt <> 0;
          Inc(fLobbies[Idx].Revision);
        end;
        Break;
      end;
    // Ein (noch) nicht beigetretenes Token darf trotzdem lesen - sonst gaebe
    // es ein Henne-Ei-Problem beim allerersten Abruf vor JoinLobby.

    Zustand := fLobbies[Idx];
    Zustand.Spieler := Copy(fLobbies[Idx].Spieler);
    Zustand.Reaktionen := Copy(fLobbies[Idx].Reaktionen);
    Zustand.ServerNowMs := AktuelleZeitMillis;
    Result := True;
  finally
    fLock.Release;
  end;
end;

function TLobbyRegistry.SelectSong(const Code, Token: UTF8String; SongIndex: integer;
                                   out FalscherToken: boolean): boolean;
var
  Idx, I: integer;
begin
  Result := False;
  FalscherToken := False;
  fLock.Acquire;
  try
    Aufraeumen(Now);
    Idx := IndexVonCode(Code);
    if (Idx < 0) then Exit;

    if (fLobbies[Idx].HostToken <> Token) then
    begin
      FalscherToken := True;
      Exit;
    end;

    fLobbies[Idx].SongIndex := SongIndex;
    // Neues Lied -> zurueck auf "wartet", Pause aufheben und die
    // Bereitschaft zuruecksetzen: Wer beim vorigen Lied bereit war, ist es
    // fuer ein anderes nicht automatisch auch.
    //
    // Und alle in die Auswahl: Ein neues Lied waehlt man dort aus, nicht auf
    // der Buehne oder vor dem Ergebnis der vorigen Runde.
    fLobbies[Idx].Ziel := lzAuswahl;
    Inc(fLobbies[Idx].ZielNr);
    fLobbies[Idx].Phase := lphWartet;
    fLobbies[Idx].Pausiert := False;
    fLobbies[Idx].PausePosMs := 0;
    // Der Vorschau-Anker gehoert zum vorigen Lied und gilt nicht weiter.
    fLobbies[Idx].VorschauStartMs := 0;
    for I := 0 to High(fLobbies[Idx].Spieler) do
    begin
      fLobbies[Idx].Spieler[I].Bereit := False;
      fLobbies[Idx].Spieler[I].Singt := False;
      fLobbies[Idx].Spieler[I].Score := -1;
    end;
    Inc(fLobbies[Idx].Revision);
    Result := True;
  finally
    fLock.Release;
  end;
end;

function TLobbyRegistry.StartSinging(const Code, Token: UTF8String; ServerStartMs: int64;
                                     out FalscherToken, KeinLiedGewaehlt: boolean): boolean;
var
  Idx: integer;
begin
  Result := False;
  FalscherToken := False;
  KeinLiedGewaehlt := False;
  fLock.Acquire;
  try
    Aufraeumen(Now);
    Idx := IndexVonCode(Code);
    if (Idx < 0) then Exit;

    if (fLobbies[Idx].HostToken <> Token) then
    begin
      FalscherToken := True;
      Exit;
    end;
    if (fLobbies[Idx].SongIndex < 0) then
    begin
      KeinLiedGewaehlt := True;
      Exit;
    end;

    fLobbies[Idx].ServerStartMs := ServerStartMs;
    fLobbies[Idx].Phase := lphSingt;
    // Wer jetzt singt, gehoert auf die Buehne - ohne ZielNr zu erhoehen:
    // Das Losspielen erkennen die Gaeste an der Phase, und ein zusaetzliches
    // Ereignis wuerde sie nur ein zweites Mal dorthin schicken.
    fLobbies[Idx].Ziel := lzBuehne;
    fLobbies[Idx].Pausiert := False;
    fLobbies[Idx].PausePosMs := 0;
    Inc(fLobbies[Idx].Revision);
    Result := True;
  finally
    fLock.Release;
  end;
end;

function TLobbyRegistry.SetZiel(const Code, Token: UTF8String; Ziel: TLobbyZiel;
                                out FalscherToken: boolean): boolean;
var
  Idx, I: integer;
begin
  Result := False;
  FalscherToken := False;
  fLock.Acquire;
  try
    Aufraeumen(Now);
    Idx := IndexVonCode(Code);
    if (Idx < 0) then Exit;

    if (fLobbies[Idx].HostToken <> Token) then
    begin
      FalscherToken := True;
      Exit;
    end;

    fLobbies[Idx].Ziel := Ziel;
    // Auch wenn dasselbe Ziel schon galt - siehe ZielNr.
    Inc(fLobbies[Idx].ZielNr);
    fLobbies[Idx].Phase := lphWartet;
    fLobbies[Idx].Pausiert := False;
    fLobbies[Idx].PausePosMs := 0;
    // Nach dem Singen steht fuer niemanden mehr ein Lied fest - sonst
    // zeigte ein spaeter beitretender Gast noch das Lied der vorigen Runde.
    if (Ziel = lzErgebnis) then
      fLobbies[Idx].SongIndex := -1;
    // Bereitschaft zuruecksetzen - siehe Kommentar bei der Deklaration.
    for I := 0 to High(fLobbies[Idx].Spieler) do
    begin
      fLobbies[Idx].Spieler[I].Bereit := False;
      fLobbies[Idx].Spieler[I].Singt := False;
    end;
    Inc(fLobbies[Idx].Revision);
    Result := True;
  finally
    fLock.Release;
  end;
end;

function TLobbyRegistry.SetPause(const Code, Token: UTF8String; An: boolean;
                                 PosMs: int64; out FalscherToken: boolean): boolean;
var
  Idx: integer;
begin
  Result := False;
  FalscherToken := False;
  fLock.Acquire;
  try
    Aufraeumen(Now);
    Idx := IndexVonCode(Code);
    if (Idx < 0) then Exit;

    if (fLobbies[Idx].HostToken <> Token) then
    begin
      FalscherToken := True;
      Exit;
    end;

    if An then
    begin
      if (PosMs < 0) then PosMs := 0;
      fLobbies[Idx].Pausiert := True;
      fLobbies[Idx].PausePosMs := PosMs;
    end
    else
    begin
      // Der Anker wird aus der festgehaltenen Stelle neu berechnet: Ab jetzt
      // laeuft die Zeit dort weiter, wo angehalten wurde - sonst spraenge die
      // Wiedergabe bei allen um die Dauer der Pause nach vorn.
      fLobbies[Idx].ServerStartMs :=
        AktuelleZeitMillis - fLobbies[Idx].PausePosMs;
      fLobbies[Idx].Pausiert := False;
    end;
    Inc(fLobbies[Idx].Revision);
    Result := True;
  finally
    fLock.Release;
  end;
end;

function TLobbyRegistry.SetVorschau(const Code, Token: UTF8String; StartMs: int64;
                                    out FalscherToken: boolean): boolean;
var
  Idx: integer;
begin
  Result := False;
  FalscherToken := False;
  fLock.Acquire;
  try
    Aufraeumen(Now);
    Idx := IndexVonCode(Code);
    if (Idx < 0) then Exit;

    if (fLobbies[Idx].HostToken <> Token) then
    begin
      FalscherToken := True;
      Exit;
    end;

    fLobbies[Idx].VorschauStartMs := StartMs;
    Inc(fLobbies[Idx].Revision);
    Result := True;
  finally
    fLock.Release;
  end;
end;

function TLobbyRegistry.React(const Code, Token: UTF8String; Art: TReaktionsArt;
                              out Seq: int64): boolean;
var
  Idx, Anzahl, I: integer;
  Wer: UTF8String;
begin
  Result := False;
  Seq := 0;
  fLock.Acquire;
  try
    Aufraeumen(Now);
    Idx := IndexVonCode(Code);
    if (Idx < 0) then Exit;

    // Den Namen zum Token nachschlagen - die Anzeige stellt ihn neben das
    // Emoji. Wer (noch) nicht in der Liste steht, bleibt namenlos.
    Wer := '';
    for I := 0 to High(fLobbies[Idx].Spieler) do
      if (fLobbies[Idx].Spieler[I].Token = Token) then
      begin
        Wer := fLobbies[Idx].Spieler[I].Name;
        Break;
      end;

    Inc(fLobbies[Idx].Revision);
    Seq := fLobbies[Idx].Revision;

    Anzahl := Length(fLobbies[Idx].Reaktionen);
    SetLength(fLobbies[Idx].Reaktionen, Anzahl + 1);
    fLobbies[Idx].Reaktionen[Anzahl].Seq := Seq;
    fLobbies[Idx].Reaktionen[Anzahl].Art := Art;
    fLobbies[Idx].Reaktionen[Anzahl].Name := Wer;
    Inc(Anzahl);

    // Begrenzt halten - aelteste zuerst verwerfen, wie MAX_BEFEHLE in
    // UWebBridge.
    //
    // Elementweise umkopieren, NICHT mit Move: Der Datensatz enthaelt seit
    // dem Namen eine Zeichenkette, und die wird ueber einen Zaehler
    // verwaltet. Ein roher Speicherumzug zieht diesen Zaehler nicht mit -
    // der ueberschriebene Eintrag wuerde nie freigegeben, der doppelt
    // stehende beim Kuerzen einmal zu oft, und der Zeiger zeigte danach ins
    // Leere. Die Zuweisung unten macht das richtig.
    if (Anzahl > LOBBY_MAX_REAKTIONEN) then
    begin
      for I := 0 to Anzahl - 2 do
        fLobbies[Idx].Reaktionen[I] := fLobbies[Idx].Reaktionen[I + 1];
      SetLength(fLobbies[Idx].Reaktionen, LOBBY_MAX_REAKTIONEN);
    end;

    Result := True;
  finally
    fLock.Release;
  end;
end;

function TLobbyRegistry.LobbyCount: integer;
begin
  fLock.Acquire;
  try
    Aufraeumen(Now);
    Result := Length(fLobbies);
  finally
    fLock.Release;
  end;
end;

procedure TLobbyRegistry.SetzeLastSeenFuerTest(const Code, Token: UTF8String;
                                               Zeit: TDateTime);
var
  Idx, I: integer;
begin
  fLock.Acquire;
  try
    Idx := IndexVonCode(Code);
    if (Idx < 0) then Exit;
    for I := 0 to High(fLobbies[Idx].Spieler) do
      if (fLobbies[Idx].Spieler[I].Token = Token) then
      begin
        fLobbies[Idx].Spieler[I].LastSeen := Zeit;
        Exit;
      end;
  finally
    fLock.Release;
  end;
end;

end.
