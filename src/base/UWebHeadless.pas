unit UWebHeadless;

(*
 * Der Webbetrieb ohne Spiel: kein Fenster, kein OpenGL, kein SDL.
 *
 * Gedacht fuer einen Rechner ohne Bildschirm - ein kleiner Server im
 * Heimnetz, an dem gar keine Grafikkarte haengt. Gesungen wird dann im
 * Browser; das Spiel selbst laeuft dort nicht und braucht es auch nicht.
 *
 * Diese Unit bindet mit Absicht NICHTS aus dem Spiel ein. Sobald hier ein
 * ULog, UIni oder USongs auftaucht, haengt der kopflose Betrieb wieder an
 * SDL - und genau das soll er nicht. Gemeldet wird deshalb ueber WriteLn,
 * nicht ueber das Spielprotokoll.
 *)

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

interface

uses
  SysUtils,
  Classes,
  UWebBridge,
  UWebServer,
  USongScan;

// Startet den Server und laeuft, bis abgebrochen wird.
// Rueckgabe ist der Beendigungscode fuer das Programm.
function RunHeadlessWeb(Port: word; const Adresse: UTF8String = ''): integer;

implementation

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  UWebApi;

var
  Beenden: boolean = False;

{$IFDEF UNIX}
// Strg-C und "kill" sollen den Server ordentlich schliessen, statt ihn
// mitten in einer Antwort abzuschneiden.
procedure AufSignal(Sig: cint); cdecl;
begin
  Beenden := True;
end;
{$ENDIF}

procedure Melde(const Nachricht: UTF8String; Fehler: boolean);
begin
  if Fehler then
    WriteLn(StdErr, 'Web: ', Nachricht)
  else
    WriteLn('Web: ', Nachricht);
  Flush(Output);
end;

// Sucht den Ordner mit der Weboberflaeche. Ohne ihn laeuft nur die
// Fernbedienung - im kopflosen Betrieb ist das wenig sinnvoll, aber immer
// noch besser als gar nicht zu starten.
function FindeWebOrdner: UTF8String;
var
  I: integer;
  Kandidat, Basis: UTF8String;
begin
  Result := '';
  Basis := ExtractFilePath(ParamStr(0));
  for I := 0 to 2 do
  begin
    case I of
      0: Kandidat := Basis + 'web' + PathDelim;
      1: Kandidat := Basis + '..' + PathDelim + 'web' + PathDelim;
      2: Kandidat := Basis + '..' + PathDelim + '..' + PathDelim + 'web' + PathDelim;
    end;
    if FileExists(Kandidat + 'index.html') then
    begin
      Result := Kandidat;
      Exit;
    end;
  end;
end;

function RunHeadlessWeb(Port: word; const Adresse: UTF8String = ''): integer;
var
  Bridge: TWebBridge;
  Server: TWebServerThread;
  Ordner: TStringList;
  Lieder: TWebSongArray;
  WebOrdner, Ini: UTF8String;
  Cmd: TWebCommand;
  I: integer;
begin
  Result := 0;
  Beenden := False;

  {$IFDEF UNIX}
  FpSignal(SIGINT, @AufSignal);
  FpSignal(SIGTERM, @AufSignal);
  {$ENDIF}

  WriteLn('UltraStar Deluxe - Weboberflaeche ohne Spiel');

  Ordner := TStringList.Create;
  Bridge := TWebBridge.Create;
  Server := nil;
  try
    Ini := FindConfigIni;
    if (Ini <> '') then
      WriteLn('Einstellungen: ', Ini);

    CollectSongDirs(Ordner);
    if (Ordner.Count = 0) then
    begin
      // Ohne Lieder ist der Server nutzlos. Lieber gleich sagen, woran es
      // liegt, als eine leere Liste ausliefern.
      WriteLn(StdErr, 'Keine Liederordner gefunden.');
      WriteLn(StdErr, 'Mit --songpath <Ordner> angeben, oder in der ',
                      'config.ini unter [Directories] SongDir1 eintragen.');
      Result := 1;
      Exit;
    end;

    for I := 0 to Ordner.Count - 1 do
      WriteLn('Liederordner: ', Ordner[I]);

    Write('Lese Lieder ... ');
    Flush(Output);
    Lieder := ScanSongs(Ordner);
    WriteLn(Length(Lieder), ' gefunden');
    if (Length(Lieder) = 0) then
      WriteLn(StdErr, 'Warnung: In den Ordnern steht keine lesbare .txt.');

    Bridge.PublishSongs(Lieder);

    WebOrdner := FindeWebOrdner;
    if (WebOrdner = '') then
      WriteLn(StdErr, 'Warnung: Ordner web/ nicht gefunden - es laeuft nur ',
                      'die Fernbedienung, nicht das Singen im Browser.')
    else
      WriteLn('Weboberflaeche: ', WebOrdner);

    WebLogHandler := Melde;
    Server := TWebServerThread.Create(Bridge, Port, WebOrdner, Adresse);

    if (Adresse <> '') then
      WriteLn('Bereit auf ', Adresse, ' Port ', Port, ' - mit Strg-C beenden.')
    else
      WriteLn('Bereit auf Port ', Port, ' - mit Strg-C beenden.');
    Flush(Output);

    while not Beenden do
    begin
      // Auswahlbefehle abraeumen. Sie kommen von der Fernbedienung und
      // meinen "waehle im Spiel aus" - hier gibt es kein Spiel, also wird
      // die Schlange nur geleert, damit sie nicht volllaeuft.
      while Bridge.NextCommand(Cmd) do
        if (Cmd.Kind = wckStart) then
          WriteLn('Auswahl von Lied ', Cmd.SongIndex,
                  ' - ohne Spiel ohne Wirkung.');
      Sleep(200);
    end;

    WriteLn;
    WriteLn('Wird beendet ...');
  finally
    if Assigned(Server) then
    begin
      Server.Stop;
      Server.WaitFor;
      Server.Free;
    end;
    Bridge.Free;
    Ordner.Free;
  end;
end;

end.
