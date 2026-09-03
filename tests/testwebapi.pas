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
  USongFilter, UWebBridge, UWebApi;

var
  Bestanden, Fehlgeschlagen: integer;

procedure Check(const Was: string; Bedingung: boolean; const Detail: string = '');
begin
  if Bedingung then begin Inc(Bestanden); WriteLn('  OK   ', Was); end
  else begin Inc(Fehlgeschlagen); WriteLn('  FEHL ', Was, '   ', Detail); end;
end;

var
  B: TWebBridge;
  Q: TStringList;
  CT, Body: UTF8String;
  Status: integer;
  Pfad: UTF8String;
  L: TWebSongArray;
  D: TJSONData;
  Cmd: TWebCommand;

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
  Result := HandleWebRequest(B, Pfad, Q, CT, Body);
end;

begin
  Bestanden := 0; Fehlgeschlagen := 0;
  B := TWebBridge.Create;
  Q := TStringList.Create;

  SetLength(L, 3);
  L[0].Index := 5; L[0].Artist := 'ABBA';    L[0].Title := 'Dancing Queen'; L[0].Genre := 'Pop';    L[0].Year := 1976;
  L[1].Index := 6; L[1].Artist := 'Queen';   L[1].Title := 'Bohemian';      L[1].Genre := 'Rock';   L[1].Year := 1975;
  L[2].Index := 7; L[2].Artist := 'Nirvana'; L[2].Title := 'Smells';        L[2].Genre := 'Grunge'; L[2].Year := 1991;
  L[0].TxtPath := '/lieder/abba.txt';  L[0].AudioPath := '/lieder/abba.mp3';
  L[1].Duet := True;   // Queen-Eintrag als Duett
  L[1].TxtPath := '/lieder/queen.txt'; L[1].AudioPath := '';   // ohne Ton
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
    Check('ueber alles gesucht', TJSONArray(D).Count = 2, IntToStr(TJSONArray(D).Count));
  finally D.Free; end;

  Ruf('/api/songs', ['q', 'queen', 'mode', 'artist']);
  D := GetJSON(Body);
  try
    Check('Modus wird beachtet', TJSONArray(D).Count = 1, IntToStr(TJSONArray(D).Count));
    Check('und liefert den richtigen',
          TJSONObject(TJSONArray(D)[0]).Strings['artist'] = 'Queen');
  finally D.Free; end;

  // Die Suchsyntax des Spiels muss auch hier gelten.
  Ruf('/api/songs', ['q', 'abba OR nirvana']);
  D := GetJSON(Body);
  try Check('OR wirkt', TJSONArray(D).Count = 2, IntToStr(TJSONArray(D).Count));
  finally D.Free; end;

  Ruf('/api/songs', ['q', '1970-1980']);
  D := GetJSON(Body);
  try Check('Jahresbereich wirkt', TJSONArray(D).Count = 2, IntToStr(TJSONArray(D).Count));
  finally D.Free; end;

  Ruf('/api/songs', ['q', '!queen']);
  D := GetJSON(Body);
  try Check('Ausschluss wirkt', TJSONArray(D).Count = 1, IntToStr(TJSONArray(D).Count));
  finally D.Free; end;

  // Eine Anfrage darf nicht das ganze Verzeichnis in eine Antwort giessen.
  Ruf('/api/songs', ['q', '', 'max', '1000000']);
  D := GetJSON(Body);
  try Check('Obergrenze wird erzwungen', TJSONArray(D).Count <= WEB_MAX_RESULTS);
  finally D.Free; end;
  Ruf('/api/songs', ['q', '', 'max', '1']);
  D := GetJSON(Body);
  try Check('kleines max wird beachtet', TJSONArray(D).Count = 1);
  finally D.Free; end;

  WriteLn('Auswaehlen');
  Status := Ruf('/api/select', ['index', '6']);
  Check('Auswahl liefert 200', Status = 200, IntToStr(Status));
  Check('Befehl liegt beim Spiel',
        B.NextCommand(Cmd) and (Cmd.Kind = wckStart) and (Cmd.SongIndex = 6));

  Status := Ruf('/api/select', []);
  Check('ohne Index: 400', Status = 400, IntToStr(Status));
  Status := Ruf('/api/select', ['index', 'quatsch']);
  Check('unlesbarer Index: 400', Status = 400, IntToStr(Status));
  Check('und kein Befehl entstanden', not B.NextCommand(Cmd));

  WriteLn('Fehlerfaelle');
  Status := Ruf('/gibtesnicht', []);
  Check('unbekannter Weg: 404', Status = 404, IntToStr(Status));

  Status := HandleWebRequest(nil, '/api/status', Q, CT, Body);
  Check('ohne Bruecke: 503 statt Absturz', Status = 503, IntToStr(Status));

  Ruf('/api/songs', ['q', 'queen', 'mode', 'artist']);
  D := GetJSON(Body);
  try
    Check('Duett wird gemeldet',
          (TJSONArray(D).Count = 1) and
          TJSONObject(TJSONArray(D)[0]).Booleans['duet']);
  finally D.Free; end;
  Ruf('/api/songs', ['q', 'abba', 'mode', 'artist']);
  D := GetJSON(Body);
  try
    Check('Sololied wird nicht als Duett gemeldet',
          (TJSONArray(D).Count = 1) and
          (not TJSONObject(TJSONArray(D)[0]).Booleans['duet']));
  finally D.Free; end;

  WriteLn;
  WriteLn('Dateianfragen');
  Check('Liedtext wird zugeordnet',
        (ResolveFileRequest(B, '/api/song/0/txt', '', Pfad, CT) = waDatei) and
        (Pfad = '/lieder/abba.txt'));
  Check('und als Text ausgeliefert', Pos('text/plain', CT) = 1, CT);
  Check('Ton wird zugeordnet',
        (ResolveFileRequest(B, '/api/song/0/audio', '', Pfad, CT) = waDatei) and
        (Pfad = '/lieder/abba.mp3'));
  Check('mit passendem Typ', CT = 'audio/mpeg', CT);

  Check('fehlender Ton: 404 statt leerer Pfad',
        ResolveFileRequest(B, '/api/song/1/audio', '', Pfad, CT) = waFehlt);
  Check('Index ausserhalb: 404',
        ResolveFileRequest(B, '/api/song/99/txt', '', Pfad, CT) = waFehlt);
  Check('negativer Index: 404',
        ResolveFileRequest(B, '/api/song/-1/txt', '', Pfad, CT) = waFehlt);
  Check('unlesbarer Index: 404',
        ResolveFileRequest(B, '/api/song/x/txt', '', Pfad, CT) = waFehlt);
  Check('unbekannte Datei am Lied: 404',
        ResolveFileRequest(B, '/api/song/0/passwd', '', Pfad, CT) = waFehlt);
  Check('kein Pfad bei Ablehnung', Pfad = '', Pfad);

  // Der eigentliche Punkt: Aus der URL laesst sich kein Pfad steuern. Der
  // Index wird nachgeschlagen, alles andere faellt durch.
  Check('Punkt-Punkt im Index greift nicht',
        ResolveFileRequest(B, '/api/song/..%2F..%2Fetc%2Fpasswd/txt', '',
                           Pfad, CT) = waFehlt);
  Check('Ausbruch ueber den Dateinamen greift nicht',
        ResolveFileRequest(B, '/../etc/passwd', 'web', Pfad, CT) = waNichts);
  Check('nicht aufgefuehrte Datei wird nicht geliefert',
        ResolveFileRequest(B, '/js/../../etc/passwd', 'web', Pfad, CT) = waNichts);
  Check('unbekanntes js wird nicht geliefert',
        ResolveFileRequest(B, '/js/geheim.js', 'web', Pfad, CT) = waNichts);

  Check('ohne Webordner faellt die Seite zurueck',
        ResolveFileRequest(B, '/index.html', '', Pfad, CT) = waNichts);
  Check('Api bleibt Api',
        ResolveFileRequest(B, '/api/songs', 'web', Pfad, CT) = waNichts);

  B.Free; Q.Free;
  WriteLn;
  WriteLn(Format('%d bestanden, %d fehlgeschlagen', [Bestanden, Fehlgeschlagen]));
  if Fehlgeschlagen > 0 then Halt(1);
end.
