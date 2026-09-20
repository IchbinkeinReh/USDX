program testwebapi;
(*
 * Prueft UWebApi - die Wegewahl der Weboberflaeche.
 *
 * Ohne HTTP und ohne Spiel: Weg und Parameter rein, Status und Rumpf raus.
 * Genau deshalb liegt die Logik dort und nicht im Server-Thread, der ueber
 * ULog am halben Spiel haengt.
 *)
{$MODE Delphi}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, fpjson, jsonparser,
  USongFilter, UWebBridge, UWebCrypto, UWebLobby, UWebApi;

var
  Bestanden, Fehlgeschlagen: integer;

const
  // Die Plaetze der drei Testlieder NACH dem Veroeffentlichen.
  //
  // PublishSongs sortiert alphabetisch nach Interpret und vergibt den Index
  // neu - er zeigt auf die Stelle in dieser sortierten Liste, nicht auf die
  // Reihenfolge, in der die Lieder hier hineingereicht werden. Aus
  // ABBA / Queen / Nirvana wird also ABBA / Nirvana / Queen.
  //
  // Frueher standen hier nackte Zahlen, und genau daran ist der Test
  // auseinandergelaufen: '/api/song/1/...' war einmal Queen gemeint, traf
  // nach dem Hinzukommen von Nirvana aber dieses - und weil Nirvana
  // ebenfalls weder Ton noch Video hat, blieben die Pruefungen gruen und
  // pruefte nur nichts mehr. Als Namen faellt eine Verschiebung auf.
  ABBA_NR    = 0;
  NIRVANA_NR = 1;
  QUEEN_NR   = 2;

  // Was das SPIEL zum Auswaehlen braucht, steht getrennt in SelectIndex und
  // hat mit dem Platz in der Liste nichts zu tun. Bewusst unterschiedliche
  // Werte: Waeren sie gleich, koennte /api/select den einen fuer den anderen
  // halten und niemand saehe es.
  ABBA_SEL    = 50;
  QUEEN_SEL   = 60;
  NIRVANA_SEL = 70;

procedure Check(const Was: string; Bedingung: boolean; const Detail: string = '');
begin
  if Bedingung then begin Inc(Bestanden); WriteLn('  OK   ', Was); end
  else begin Inc(Fehlgeschlagen); WriteLn('  FEHL ', Was, '   ', Detail); end;
end;

var
  B: TWebBridge;
  Lobby: TLobbyRegistry;
  Sessions: TCryptoSessions;
  Q: TStringList;
  CT, Body: UTF8String;
  Status: integer;
  Pfad: UTF8String;
  Fehlt: UTF8String;
  Suche: TSearchRec;
  Gefunden: boolean;
  I: integer;
  L: TWebSongArray;
  D: TJSONData;
  Cmd: TWebCommand;
  LobbyCode, LobbyCode2: UTF8String;
  LetzteSeq: int64;

function Ruf(const Pfad: UTF8String; const Params: array of string): integer;
var I: integer;
begin
  Q.Clear;
  I := 0;
  while I < Length(Params) do
  begin
    Q.Values[Params[I]] := Params[I + 1];
    Inc(I, 2);
  end;
  Result := HandleWebRequest(B, Lobby, Sessions, Pfad, Q, CT, Body);
end;

// Die allermeisten Faelle hier interessiert nur, WELCHE Antwortart
// herauskommt - der Schutz wird getrennt geprueft (siehe "Verschluesselung").
function Aufloesen(Bridge: TWebBridge; const Weg, Wurzel: UTF8String;
                   out P, C: UTF8String): TWebAntwortArt;
var
  Schutz: TWebDateiSchutz;
begin
  Result := ResolveFileRequest(Bridge, Weg, Wurzel, P, C, Schutz);
end;

// Welche Dateien nur gegen eine gueltige Sitzung hinausgehen - und dass
// die Zuordnung von Schluessel und Einmalwert daran haengt.
procedure PruefeSchutz;
var
  P, C: UTF8String;
  Schutz: TWebDateiSchutz;
  Key: TChaChaKey;
  Nonce, NonceB: TChaChaNonce;
  Sid: UTF8String;
  I: integer;
  Gleich: boolean;
  Art: TWebAntwortArt;
begin
  Check('Sitzung liefert 200', Ruf('/api/session', []) = 200);
  D := GetJSON(Body);
  try
    Check('Sitzung nennt eine Kennung',
          Length(TJSONObject(D).Strings['sid']) = 32,
          TJSONObject(D).Strings['sid']);
    Check('Sitzung nennt einen 256-Bit-Schluessel',
          Length(TJSONObject(D).Strings['key']) = 64,
          TJSONObject(D).Strings['key']);
    Check('Sitzung nennt ihre Laufzeit',
          TJSONObject(D).Integers['ttl'] = CRYPTO_TTL_SECONDS);
    Sid := TJSONObject(D).Strings['sid'];
  finally D.Free; end;

  Ruf('/api/session', []);
  D := GetJSON(Body);
  try
    Check('zwei Anfragen geben verschiedene Sitzungen',
          TJSONObject(D).Strings['sid'] <> Sid);
  finally D.Free; end;

  Check('Ton ist geschuetzt', DateiIstGeschuetzt(wfkAudio));
  Check('Video ist geschuetzt', DateiIstGeschuetzt(wfkVideo));
  Check('Noten sind geschuetzt', DateiIstGeschuetzt(wfkTxt));
  // Der Schnipsel ist nur eine halbe Minute - dreissigtausend halbe Minuten
  // sind trotzdem die Sammlung.
  Check('Vorschau ist geschuetzt', DateiIstGeschuetzt(wfkPreview));
  // Titelbilder und Hintergruende bleiben offen - sie haengen in der Liste
  // an tausenden <img>-Elementen.
  Check('Titelbild ist nicht geschuetzt', not DateiIstGeschuetzt(wfkCover));
  Check('Hintergrund ist nicht geschuetzt',
        not DateiIstGeschuetzt(wfkBackground));

  Art := ResolveFileRequest(B, '/api/song/' + IntToStr(ABBA_NR) + '/audio',
                            '', P, C, Schutz);
  Check('Ton meldet Schutzbedarf',
        (Art = waDatei) and Schutz.Noetig);
  Check('mit richtiger Liednummer und Art',
        (Schutz.SongIndex = ABBA_NR) and (Schutz.Art = Ord(wfkAudio)),
        IntToStr(Schutz.SongIndex) + '/' + IntToStr(Schutz.Art));

  Art := ResolveFileRequest(B, '/api/song/' + IntToStr(ABBA_NR) + '/cover',
                       '', P, C, Schutz);
  Check('Titelbild meldet keinen Schutzbedarf',
        (Art = waDatei) and not Schutz.Noetig);

  // Ohne Sitzung gibt es keinen Schluessel - und damit (im Server) 403.
  Art := ResolveFileRequest(B, '/api/song/' + IntToStr(ABBA_NR) + '/audio',
                            '', P, C, Schutz);
  Check('ohne Sitzung kein Schluessel',
        not SchluesselFuerAnfrage(Sessions, Schutz, '', Key, Nonce));
  Check('unbekannte Sitzung ebenso',
        not SchluesselFuerAnfrage(Sessions, Schutz, 'ff00ff00', Key, Nonce));

  Sessions.NewSession(Sid, Key);
  FillChar(Key, SizeOf(Key), 0);
  Check('mit gueltiger Sitzung gibt es einen Schluessel',
        SchluesselFuerAnfrage(Sessions, Schutz, Sid, Key, Nonce));
  Gleich := True;
  for I := 0 to 31 do
    if (Key[I] <> 0) then Gleich := False;
  Check('und der ist nicht leer', not Gleich);

  // Der Einmalwert muss sich je Datei unterscheiden, sonst liefe der
  // bekannte Klartext einer .txt gegen den Ton daneben.
  ResolveFileRequest(B, '/api/song/' + IntToStr(ABBA_NR) + '/txt',
                       '', P, C, Schutz);
  SchluesselFuerAnfrage(Sessions, Schutz, Sid, Key, NonceB);
  Gleich := True;
  for I := 0 to 11 do
    if (Nonce[I] <> NonceB[I]) then Gleich := False;
  Check('Ton und Noten bekommen verschiedene Einmalwerte', not Gleich);

  // Eine ungeschuetzte Datei bekommt NIE einen Schluessel - sonst wuerde
  // sie verschluesselt ausgeliefert, obwohl niemand sie entschluesselt.
  ResolveFileRequest(B, '/api/song/' + IntToStr(ABBA_NR) + '/cover',
                       '', P, C, Schutz);
  Check('ungeschuetzte Datei bekommt keinen Schluessel',
        not SchluesselFuerAnfrage(Sessions, Schutz, Sid, Key, Nonce));
end;

// /api/lobby/* liefert bei Erfolg immer die Zustands-Antwort - ob es
// ueberhaupt eine ist, wird hier an einer Stelle geprueft.
function IstZustand(D: TJSONData): boolean;
begin
  Result := Assigned(D) and (D.JSONType = jtObject) and
            (TJSONObject(D).Find('code') <> nil);
end;

// /api/songs liefert {"total": N, "songs": [...]} - die Liederliste steckt
// darin, nicht als nacktes Array wie frueher.
function Liedliste(D: TJSONData): TJSONArray;
begin
  Result := TJSONArray(TJSONObject(D).Arrays['songs']);
end;

begin
  Bestanden := 0; Fehlgeschlagen := 0;
  B := TWebBridge.Create;
  Lobby := TLobbyRegistry.Create;
  Sessions := TCryptoSessions.Create;
  Q := TStringList.Create;

  SetLength(L, 3);
  // Index wird hier NICHT gesetzt: PublishSongs vergibt ihn beim Sortieren
  // ohnehin neu. Stuenden hier Zahlen, laese sich der Test so, als haetten
  // sie Bedeutung - genau der Irrtum, der ihn hat verfallen lassen.
  L[0].Artist := 'ABBA';    L[0].Title := 'Dancing Queen'; L[0].Genre := 'Pop';    L[0].Year := 1976;
  L[1].Artist := 'Queen';   L[1].Title := 'Bohemian';      L[1].Genre := 'Rock';   L[1].Year := 1975;
  L[2].Artist := 'Nirvana'; L[2].Title := 'Smells';        L[2].Genre := 'Grunge'; L[2].Year := 1991;
  L[0].TxtPath := '/lieder/abba.txt';  L[0].AudioPath := '/lieder/abba.mp3';
  L[1].Duet := True;   // Queen-Eintrag als Duett
  L[1].TxtPath := '/lieder/queen.txt'; L[1].AudioPath := '';   // ohne Ton
  L[0].VideoPath := '/lieder/abba.mp4'; L[0].BackgPath := '/lieder/abba.jpg';
  L[0].CoverPath := '/lieder/abba_cover.jpg';
  L[1].VideoPath := '';                 L[1].BackgPath := '/lieder/queen.png';
  L[0].SelectIndex := ABBA_SEL;
  L[1].SelectIndex := QUEEN_SEL;
  L[2].SelectIndex := NIRVANA_SEL;
  B.PublishSongs(L);

  WriteLn('Seite und Status');
  Status := Ruf('/', []);
  Check('Startseite liefert 200', Status = 200);
  Check('als HTML', Pos('text/html', CT) > 0, CT);
  Check('Seite ist vollstaendig',
        (Pos('<!doctype html>', LowerCase(Body)) > 0) and (Pos('</html>', Body) > 0));
  Check('Seite laedt nichts von aussen',
        (Pos('http://', Body) = 0) and (Pos('https://', Body) = 0), 'externe Adresse gefunden');

  Status := Ruf('/api/status', []);
  Check('Status liefert 200', Status = 200);
  D := GetJSON(Body);
  try
    Check('Liederzahl stimmt', TJSONObject(D).Integers['songs'] = 3);
  finally D.Free; end;

  WriteLn('Suche');
  Ruf('/api/songs', ['q', 'queen']);
  Check('JSON als Inhaltstyp', Pos('application/json', CT) > 0, CT);
  D := GetJSON(Body);
  try
    // "queen" trifft ABBA (Titel) und Queen (Interpret)
    Check('ueber alles gesucht', Liedliste(D).Count = 2, IntToStr(Liedliste(D).Count));
    Check('Gesamtzahl steht dabei', TJSONObject(D).Integers['total'] = 2);
  finally D.Free; end;

  Ruf('/api/songs', ['q', 'queen', 'mode', 'artist']);
  D := GetJSON(Body);
  try
    Check('Modus wird beachtet', Liedliste(D).Count = 1, IntToStr(Liedliste(D).Count));
    Check('und liefert den richtigen',
          TJSONObject(Liedliste(D)[0]).Strings['artist'] = 'Queen');
  finally D.Free; end;

  // Die Suchsyntax des Spiels muss auch hier gelten.
  Ruf('/api/songs', ['q', 'abba OR nirvana']);
  D := GetJSON(Body);
  try Check('OR wirkt', Liedliste(D).Count = 2, IntToStr(Liedliste(D).Count));
  finally D.Free; end;

  Ruf('/api/songs', ['q', '1970-1980']);
  D := GetJSON(Body);
  try Check('Jahresbereich wirkt', Liedliste(D).Count = 2, IntToStr(Liedliste(D).Count));
  finally D.Free; end;

  Ruf('/api/songs', ['q', '!queen']);
  D := GetJSON(Body);
  try Check('Ausschluss wirkt', Liedliste(D).Count = 1, IntToStr(Liedliste(D).Count));
  finally D.Free; end;

  // Eine Anfrage darf nicht das ganze Verzeichnis in eine Antwort giessen.
  // Die Gesamtzahl darf die Begrenzung aber nicht mitmachen - sonst wuerfelt
  // das Zufallslied nur noch unter den ersten WEB_MAX_RESULTS Treffern.
  Ruf('/api/songs', ['q', '', 'max', '1000000']);
  D := GetJSON(Body);
  try
    Check('Obergrenze wird erzwungen', Liedliste(D).Count <= WEB_MAX_RESULTS);
    Check('Gesamtzahl bleibt echt', TJSONObject(D).Integers['total'] = 3,
          IntToStr(TJSONObject(D).Integers['total']));
  finally D.Free; end;
  Ruf('/api/songs', ['q', '', 'max', '1']);
  D := GetJSON(Body);
  try
    Check('kleines max wird beachtet', Liedliste(D).Count = 1);
    Check('Gesamtzahl bleibt trotzdem 3', TJSONObject(D).Integers['total'] = 3);
  finally D.Free; end;

  WriteLn('Auswaehlen');
  Status := Ruf('/api/select', ['index', IntToStr(QUEEN_NR)]);
  Check('Auswahl liefert 200', Status = 200, IntToStr(Status));
  // Der eigentliche Punkt: Aus dem Netz kommt der PLATZ in der sortierten
  // Liste, an das Spiel geht der SelectIndex. Wer beides verwechselt, waehlt
  // ein anderes Lied aus als angetippt - genau dafuer sind die beiden Felder
  // getrennt (siehe WEB.md, "Reihenfolge und Nachladen").
  Check('Befehl liegt beim Spiel, mit dem SelectIndex statt dem Platz',
        B.NextCommand(Cmd) and (Cmd.Kind = wckStart) and
        (Cmd.SongIndex = QUEEN_SEL),
        IntToStr(Cmd.SongIndex) + ' statt ' + IntToStr(QUEEN_SEL));

  Status := Ruf('/api/select', []);
  Check('ohne Index: 400', Status = 400, IntToStr(Status));
  Status := Ruf('/api/select', ['index', 'quatsch']);
  Check('unlesbarer Index: 400', Status = 400, IntToStr(Status));
  // Ein Platz jenseits der Liste ist kein Lied - und darf auch keines
  // auswaehlen.
  Status := Ruf('/api/select', ['index', '99']);
  Check('Platz ausserhalb der Liste: 404', Status = 404, IntToStr(Status));
  Check('und kein Befehl entstanden', not B.NextCommand(Cmd));

  WriteLn('Fehlerfaelle');
  Status := Ruf('/gibtesnicht', []);
  Check('unbekannter Weg: 404', Status = 404, IntToStr(Status));

  Status := HandleWebRequest(nil, Lobby, Sessions, '/api/status', Q, CT, Body);
  Check('ohne Bruecke: 503 statt Absturz', Status = 503, IntToStr(Status));
  Status := HandleWebRequest(B, nil, Sessions, '/api/status', Q, CT, Body);
  Check('ohne Lobby-Register: ebenso 503', Status = 503, IntToStr(Status));

  Ruf('/api/songs', ['q', 'queen', 'mode', 'artist']);
  D := GetJSON(Body);
  try
    Check('Duett wird gemeldet',
          (Liedliste(D).Count = 1) and
          TJSONObject(Liedliste(D)[0]).Booleans['duet']);
  finally D.Free; end;
  Ruf('/api/songs', ['q', 'abba', 'mode', 'artist']);
  D := GetJSON(Body);
  try
    Check('Sololied wird nicht als Duett gemeldet',
          (Liedliste(D).Count = 1) and
          (not TJSONObject(Liedliste(D)[0]).Booleans['duet']));
  finally D.Free; end;

  WriteLn;
  WriteLn('Erlaubnisliste');
  // Jede aufgefuehrte Datei muss auch wirklich im Ordner web/ liegen.
  // Ein Tippfehler hier faellt sonst nirgends auf - die Datei wird einfach
  // nicht ausgeliefert, und die Seite bleibt ohne Erklaerung leer.
  Fehlt := '';
  for I := Low(WEB_DATEIEN) to High(WEB_DATEIEN) do
    if not FileExists('web/' + WEB_DATEIEN[I]) then
      Fehlt := Fehlt + ' ' + WEB_DATEIEN[I];
  Check('alle aufgefuehrten Dateien liegen in web/', Fehlt = '', Fehlt);

  // Und umgekehrt: Jedes Modul in web/js muss aufgefuehrt sein.
  Fehlt := '';
  if (FindFirst('web/js/*.js', faAnyFile, Suche) = 0) then
  begin
    repeat
      Gefunden := False;
      for I := Low(WEB_DATEIEN) to High(WEB_DATEIEN) do
        if (WEB_DATEIEN[I] = 'js/' + Suche.Name) then Gefunden := True;
      if not Gefunden then Fehlt := Fehlt + ' ' + Suche.Name;
    until FindNext(Suche) <> 0;
    FindClose(Suche);
  end;
  Check('kein Modul in web/js fehlt in der Liste', Fehlt = '', Fehlt);

  WriteLn;
  WriteLn('Dateianfragen');
  Check('Liedtext wird zugeordnet',
        (Aufloesen(B, '/api/song/' + IntToStr(ABBA_NR) + '/txt', '',
                   Pfad, CT) = waDatei) and
        (Pfad = '/lieder/abba.txt'));
  Check('und als Text ausgeliefert', Pos('text/plain', CT) = 1, CT);
  Check('Ton wird zugeordnet',
        (Aufloesen(B, '/api/song/' + IntToStr(ABBA_NR) + '/audio', '',
                   Pfad, CT) = waDatei) and
        (Pfad = '/lieder/abba.mp3'));
  Check('mit passendem Typ', CT = 'audio/mpeg', CT);

  Check('fehlender Ton: 404 statt leerer Pfad',
        Aufloesen(B, '/api/song/' + IntToStr(QUEEN_NR) + '/audio', '',
                  Pfad, CT) = waFehlt);
  Check('Index ausserhalb: 404',
        Aufloesen(B, '/api/song/99/txt', '', Pfad, CT) = waFehlt);
  Check('negativer Index: 404',
        Aufloesen(B, '/api/song/-1/txt', '', Pfad, CT) = waFehlt);
  Check('unlesbarer Index: 404',
        Aufloesen(B, '/api/song/x/txt', '', Pfad, CT) = waFehlt);
  Check('unbekannte Datei am Lied: 404',
        Aufloesen(B, '/api/song/0/passwd', '', Pfad, CT) = waFehlt);
  Check('kein Pfad bei Ablehnung', Pfad = '', Pfad);

  // Der eigentliche Punkt: Aus der URL laesst sich kein Pfad steuern. Der
  // Index wird nachgeschlagen, alles andere faellt durch.
  Check('Punkt-Punkt im Index greift nicht',
        Aufloesen(B, '/api/song/..%2F..%2Fetc%2Fpasswd/txt', '',
                           Pfad, CT) = waFehlt);
  Check('Ausbruch ueber den Dateinamen greift nicht',
        Aufloesen(B, '/../etc/passwd', 'web', Pfad, CT) = waNichts);
  Check('nicht aufgefuehrte Datei wird nicht geliefert',
        Aufloesen(B, '/js/../../etc/passwd', 'web', Pfad, CT) = waNichts);
  Check('unbekanntes js wird nicht geliefert',
        Aufloesen(B, '/js/geheim.js', 'web', Pfad, CT) = waNichts);

  WriteLn;
  WriteLn('Video und Hintergrundbild');
  Check('Video wird zugeordnet',
        (Aufloesen(B, '/api/song/' + IntToStr(ABBA_NR) + '/video', '',
                   Pfad, CT) = waDatei) and
        (Pfad = '/lieder/abba.mp4'), Pfad);
  Check('mit Videotyp', CT = 'video/mp4', CT);
  Check('Hintergrundbild wird zugeordnet',
        (Aufloesen(B, '/api/song/' + IntToStr(ABBA_NR) + '/background', '',
                   Pfad, CT) = waDatei) and
        (Pfad = '/lieder/abba.jpg'), Pfad);
  Check('mit Bildtyp', CT = 'image/jpeg', CT);
  Check('png bekommt seinen eigenen Typ',
        (Aufloesen(B, '/api/song/' + IntToStr(QUEEN_NR) + '/background', '',
                   Pfad, CT) = waDatei) and
        (CT = 'image/png'), Pfad + ' ' + CT);

  // Ein Lied ohne Video muss 404 liefern. Der Browser fragt naemlich immer
  // erst an und faellt bei 404 auf das Bild zurueck - eine leere 200-Antwort
  // haette er als kaputtes Video verstanden.
  Check('Titelbild wird zugeordnet',
        (Aufloesen(B, '/api/song/' + IntToStr(ABBA_NR) + '/cover', '',
                   Pfad, CT) = waDatei) and
        (Pfad = '/lieder/abba_cover.jpg'), Pfad);
  Check('fehlendes Titelbild: 404',
        Aufloesen(B, '/api/song/' + IntToStr(QUEEN_NR) + '/cover', '',
                  Pfad, CT) = waFehlt);

  Ruf('/api/songs', ['q', 'abba', 'mode', 'artist']);
  D := GetJSON(Body);
  try
    Check('mit Titelbild wird gemeldet',
          TJSONObject(Liedliste(D)[0]).Booleans['cover']);
  finally D.Free; end;
  Ruf('/api/songs', ['q', 'queen', 'mode', 'artist']);
  D := GetJSON(Body);
  try
    Check('ohne Titelbild ebenso',
          not TJSONObject(Liedliste(D)[0]).Booleans['cover']);
  finally D.Free; end;

  Check('fehlendes Video: 404',
        Aufloesen(B, '/api/song/' + IntToStr(QUEEN_NR) + '/video', '',
                  Pfad, CT) = waFehlt);

  // Auch hier gilt: aus der URL kommt kein Pfad, sondern eine Zahl.
  //
  // Die Dateiart muss GENAU passen. Frueher stand hier '/cover' als die
  // erfundene Art - bis es Titelbilder wirklich gab und die Pruefung das
  // Gegenteil dessen behauptete, was zwanzig Zeilen darueber steht. Jetzt
  // steht hier, worauf es ankommt: ein Name, der einer echten Art nur
  // aehnelt, zaehlt nicht.
  Check('abgeschnittene Dateiart: 404',
        Aufloesen(B, '/api/song/' + IntToStr(ABBA_NR) + '/cov', '',
                  Pfad, CT) = waFehlt);
  Check('verlaengerte Dateiart: 404',
        Aufloesen(B, '/api/song/' + IntToStr(ABBA_NR) + '/coverx', '',
                  Pfad, CT) = waFehlt);

  Check('ohne Webordner faellt die Seite zurueck',
        Aufloesen(B, '/index.html', '', Pfad, CT) = waNichts);
  Check('Api bleibt Api',
        Aufloesen(B, '/api/songs', 'web', Pfad, CT) = waNichts);

  WriteLn;
  WriteLn('Mehrspieler-Lobbys');
  Status := Ruf('/api/lobby/create', ['token', 'host-tok', 'name', 'Host']);
  Check('Erstellen liefert 200', Status = 200, IntToStr(Status));
  D := GetJSON(Body);
  try
    Check('Antwort ist eine Zustands-Antwort', IstZustand(D));
    Check('sechsstelliger Code',
          Length(TJSONObject(D).Strings['code']) = 6,
          TJSONObject(D).Strings['code']);
    Check('Ersteller ist Host', TJSONObject(D).Booleans['isHost']);
    Check('anfangs wartet', TJSONObject(D).Strings['phase'] = 'wartet');
    LobbyCode := TJSONObject(D).Strings['code'];
  finally D.Free; end;

  Status := Ruf('/api/lobby/' + LobbyCode + '/join',
                ['token', 'gast-tok', 'name', 'Gast']);
  Check('Beitreten liefert 200', Status = 200, IntToStr(Status));
  D := GetJSON(Body);
  try
    Check('Gast ist nicht Host', not TJSONObject(D).Booleans['isHost']);
    Check('zwei Spieler stehen drin',
          TJSONArray(TJSONObject(D).Arrays['spieler']).Count = 2);
  finally D.Free; end;

  Status := Ruf('/api/lobby/000000/join', ['token', 'x', 'name', 'X']);
  Check('Beitritt zu unbekanntem Code: 404', Status = 404, IntToStr(Status));

  // Kein Gast darf je den Token eines anderen zu Gesicht bekommen - auch
  // nicht den des Hosts. Das ist der eigentliche Punkt hinter isHost/isYou.
  Status := Ruf('/api/lobby/' + LobbyCode + '/state', ['token', 'gast-tok']);
  Check('Zustand fuer den Gast liefert 200', Status = 200, IntToStr(Status));
  Check('der Host-Token steht nirgends im Text',
        Pos('host-tok', Body) = 0, Body);

  WriteLn('Nur der Ersteller darf waehlen und starten');
  // Gueltige Indizes sind 0..SongCount-1 - die Sortierung beim
  // Veroeffentlichen vergibt sie neu, die urspruenglichen L[I].Index (5/6/7)
  // gelten danach nicht mehr.
  Status := Ruf('/api/lobby/' + LobbyCode + '/select',
                ['token', 'gast-tok', 'index', '1']);
  Check('Gast darf nicht auswaehlen: 403', Status = 403, IntToStr(Status));
  Status := Ruf('/api/lobby/' + LobbyCode + '/select',
                ['token', 'host-tok', 'index', '1']);
  Check('Host darf auswaehlen', Status = 200, IntToStr(Status));
  Status := Ruf('/api/lobby/' + LobbyCode + '/select',
                ['token', 'host-tok', 'index', '99999']);
  Check('nicht vorhandenes Lied: 404', Status = 404, IntToStr(Status));

  // -1 ist die ausdrueckliche Abwahl ("Anderes Lied") - kein Fehler wie ein
  // erfundener Index, sonst liesse sich nach einem Lied nichts mehr abwaehlen.
  Status := Ruf('/api/lobby/' + LobbyCode + '/select',
                ['token', 'host-tok', 'index', '-1']);
  Check('Abwahl mit -1 gelingt', Status = 200, IntToStr(Status));
  Status := Ruf('/api/lobby/' + LobbyCode + '/state', ['token', 'host-tok']);
  D := GetJSON(Body);
  try Check('kein Lied bleibt ausgewaehlt',
            TJSONObject(D).Int64s['songIndex'] = -1);
  finally D.Free; end;
  // Ein fehlender Parameter darf NICHT wie -1 durchgehen, sonst waere eine
  // kaputte Anfrage vom absichtlichen Abwaehlen nicht zu unterscheiden.
  Status := Ruf('/api/lobby/' + LobbyCode + '/select', ['token', 'host-tok']);
  Check('fehlender Index bleibt ein Fehler, nicht heimlich -1',
        Status = 404, IntToStr(Status));
  // Fuer die folgenden Tests wieder ein Lied auswaehlen - oben wurde
  // ausdruecklich abgewaehlt.
  Ruf('/api/lobby/' + LobbyCode + '/select', ['token', 'host-tok', 'index', '1']);

  Status := Ruf('/api/lobby/' + LobbyCode + '/start',
                ['token', 'gast-tok', 'serverStartMs', '1000']);
  Check('Gast darf nicht starten: 403', Status = 403, IntToStr(Status));

  Status := Ruf('/api/lobby/create', ['token', 'leer-host', 'name', 'LeerHost']);
  D := GetJSON(Body);
  try LobbyCode2 := TJSONObject(D).Strings['code'];
  finally D.Free; end;
  Status := Ruf('/api/lobby/' + LobbyCode2 + '/start',
                ['token', 'leer-host', 'serverStartMs', '1000']);
  Check('ohne gewaehltes Lied: 409', Status = 409, IntToStr(Status));

  Status := Ruf('/api/lobby/' + LobbyCode + '/start',
                ['token', 'host-tok', 'serverStartMs', '424242']);
  Check('Host darf starten', Status = 200, IntToStr(Status));
  D := GetJSON(Body);
  try Check('Anker kommt zurueck',
            TJSONObject(D).Int64s['serverStartMs'] = 424242);
  finally D.Free; end;

  Status := Ruf('/api/lobby/' + LobbyCode + '/state', ['token', 'host-tok']);
  D := GetJSON(Body);
  try Check('Zustand zeigt jetzt singt',
            TJSONObject(D).Strings['phase'] = 'singt');
  finally D.Free; end;

  WriteLn('Reaktionen');
  Status := Ruf('/api/lobby/' + LobbyCode + '/react',
                ['token', 'gast-tok', 'art', 'hoch']);
  Check('Reaktion wird angenommen', Status = 200, IntToStr(Status));
  D := GetJSON(Body);
  try LetzteSeq := TJSONObject(D).Int64s['seq'];
  finally D.Free; end;

  Status := Ruf('/api/lobby/' + LobbyCode + '/state',
                ['token', 'host-tok', 'since', IntToStr(LetzteSeq)]);
  D := GetJSON(Body);
  try
    Check('mit since=letzte Seq kommt sie nicht noch einmal',
          TJSONArray(TJSONObject(D).Arrays['reaktionen']).Count = 0);
  finally D.Free; end;
  Status := Ruf('/api/lobby/' + LobbyCode + '/state',
                ['token', 'host-tok', 'since', '0']);
  D := GetJSON(Body);
  try
    Check('ohne since kommt sie mit',
          TJSONArray(TJSONObject(D).Arrays['reaktionen']).Count >= 1);
  finally D.Free; end;

  WriteLn('Verlassen');
  Status := Ruf('/api/lobby/' + LobbyCode + '/leave', ['token', 'gast-tok']);
  Check('Verlassen liefert 200', Status = 200, IntToStr(Status));
  Status := Ruf('/api/lobby/' + LobbyCode + '/state', ['token', 'host-tok']);
  D := GetJSON(Body);
  try Check('Gast ist wirklich weg',
            TJSONArray(TJSONObject(D).Arrays['spieler']).Count = 1);
  finally D.Free; end;

  WriteLn('Unbekannte Lobby ueberall');
  Check('join: 404', Ruf('/api/lobby/999999/join', ['token','x','name','X']) = 404);
  Check('state: 404', Ruf('/api/lobby/999999/state', ['token','x']) = 404);
  Check('select: 404', Ruf('/api/lobby/999999/select', ['token','x','index','0']) = 404);
  Check('start: 404', Ruf('/api/lobby/999999/start', ['token','x','serverStartMs','1']) = 404);
  Check('react: 404', Ruf('/api/lobby/999999/react', ['token','x','art','hoch']) = 404);

  WriteLn;
  WriteLn('Verschluesselung');
  PruefeSchutz;

  B.Free; Lobby.Free; Sessions.Free; Q.Free;
  WriteLn;
  WriteLn(Format('%d bestanden, %d fehlgeschlagen', [Bestanden, Fehlgeschlagen]));
  if Fehlgeschlagen > 0 then Halt(1);
end.
