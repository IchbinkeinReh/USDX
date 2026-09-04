program testwebserver;

// Prueft den Webserver als Ganzes: echter Aufruf ueber TCP, echte Dateien.
//
// Das Spiel laesst sich hier nicht starten (kein OpenGL), der Server aber
// schon - und genau die Teile, die HandleWebRequest nicht abdeckt, stecken
// im Ausliefern der Dateien und im Teilbereich fuer den Ton.

{$MODE Delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, ssockets,
  UWebBridge, UWebApi, UWebServer;

var
  Bestanden, Fehlgeschlagen: integer;
  // Der Kopf der zuletzt geholten Antwort, damit sich Kopfzeilen pruefen
  // lassen, ohne die Hole-Funktion umzubauen.
  LetzterKopf: string;
  B: TWebBridge;
  S: TWebServerThread;
  Ordner, Lied, Ton, Roh, Gross: string;
  I: integer;
  RohStrom: TFileStream;
  RohBytes: RawByteString;
  L: TWebSongArray;

procedure Check(const Was: string; Bedingung: boolean; const Info: string = '');
begin
  if Bedingung then
  begin
    Inc(Bestanden);
    WriteLn('  OK   ', Was);
    Flush(Output);
  end
  else
  begin
    Inc(Fehlgeschlagen);
    WriteLn('  FEHL ', Was, '  ', Info);
    Flush(Output);
  end;
end;

// Stellt eine Anfrage ueber einen rohen TCP-Anschluss.
//
// Bewusst ohne HTTP-Bibliothek: Die eine, die hier zur Verfuegung steht,
// verschluckt sich an Teilantworten, und dann prueft der Test die Bibliothek
// statt den Server. So steht genau das im Test, was auch ueber die Leitung
// geht - und das ist es, was der Browser zu sehen bekommt.
function Hole(const Weg: string; out Body: string;
              const Bereich: string = ''): integer;
var
  Anschluss: TInetSocket;
  Anfrage, Kopf: string;
  Antwort, Stueck: RawByteString;
  Puffer: array[0..4095] of byte;
  Gelesen, Leer: integer;
begin
  Result := 0;
  Body := '';
  Anfrage := 'GET ' + Weg + ' HTTP/1.1'#13#10 +
             'Host: 127.0.0.1:8099'#13#10 +
             'Connection: close'#13#10;
  if (Bereich <> '') then
    Anfrage := Anfrage + 'Range: ' + Bereich + #13#10;
  Anfrage := Anfrage + #13#10;

  Anschluss := TInetSocket.Create('127.0.0.1', 8099);
  try
    Anschluss.WriteBuffer(Anfrage[1], Length(Anfrage));
    Antwort := '';
    // Bis zum Verbindungsende lesen. Der Server schliesst wegen
    // "Connection: close" von sich aus - kein Warten auf eine Laenge, die
    // vielleicht nicht stimmt.
    repeat
      Gelesen := Anschluss.Read(Puffer, SizeOf(Puffer));
      if (Gelesen > 0) then
      begin
        // Byteweise umkopieren statt Copy auf dem Puffer: Copy behandelt ihn
        // als Text und bricht am ersten Nullbyte ab - womit der Test genau
        // den Fehler nicht sehen wuerde, den er nachweisen soll.
        SetLength(Stueck, Gelesen);
        Move(Puffer[0], Stueck[1], Gelesen);
        Antwort := Antwort + Stueck;
      end;
    until (Gelesen <= 0);
  finally
    Anschluss.Free;
  end;

  Kopf := '';
  if (Copy(Antwort, 1, 5) <> 'HTTP/') then Exit;
  Result := StrToIntDef(Copy(Antwort, 10, 3), 0);

  Leer := Pos(#13#10#13#10, Antwort);
  if (Leer > 0) then
  begin
    Kopf := Copy(Antwort, 1, Leer - 1);
    LetzterKopf := Kopf;
    Body := Copy(Antwort, Leer + 4, Length(Antwort));
    // Der Kopf wird mitgeprueft, wo er zaehlt.
    if (Bereich <> '') and (Result = 206) and
       (Pos('Content-Range:', Kopf) = 0) then
      Result := -1;   // 206 ohne Bereichsangabe ist fuer den Browser wertlos
  end;
end;

var
  Body: string;
  Status: integer;
  F: TextFile;
begin
  Bestanden := 0; Fehlgeschlagen := 0;

  // Ordner mit Weboberflaeche und einem Lied aufbauen.
  Ordner := GetTempDir + 'usdxweb' + IntToStr(Random(100000)) + PathDelim;
  ForceDirectories(Ordner + 'js');
  AssignFile(F, Ordner + 'index.html'); Rewrite(F);
  WriteLn(F, '<!doctype html><title>Test</title>'); CloseFile(F);
  AssignFile(F, Ordner + 'js' + PathDelim + 'song.js'); Rewrite(F);
  WriteLn(F, 'export const x = 1;'); CloseFile(F);

  Lied := Ordner + 'lied.txt';
  AssignFile(F, Lied); Rewrite(F);
  WriteLn(F, '#TITLE:Test'); WriteLn(F, '#BPM:120'); WriteLn(F, 'E'); CloseFile(F);

  Ton := Ordner + 'lied.mp3';
  AssignFile(F, Ton); Rewrite(F);
  Write(F, '0123456789'); CloseFile(F);   // 10 Zeichen, gut nachzurechnen

  // Zweite Datei mit den Bytes, an denen eine Textbehandlung scheitert:
  // Nullbyte, CR, LF. Eine echte MP3 ist voll davon.
  Roh := Ordner + 'roh.mp3';
  RohStrom := TFileStream.Create(Roh, fmCreate);
  RohBytes := 'A'#0'B'#13'C'#10'D'#26'E';
  RohStrom.WriteBuffer(RohBytes[1], Length(RohBytes));
  RohStrom.Free;

  B := TWebBridge.Create;
  // Eine Datei ueber der Stueckelungsgrenze.
  Gross := Ordner + 'gross.mp3';
  RohStrom := TFileStream.Create(Gross, fmCreate);
  SetLength(RohBytes, 64 * 1024);
  FillChar(RohBytes[1], Length(RohBytes), Ord('x'));
  for I := 1 to (WEB_MAX_STUECK div Length(RohBytes)) + 2 do
    RohStrom.WriteBuffer(RohBytes[1], Length(RohBytes));
  RohStrom.Free;
  RohBytes := 'A'#0'B'#13'C'#10'D'#26'E';

  SetLength(L, 3);
  L[0].Index := 0; L[0].Artist := 'A'; L[0].Title := 'T';
  L[0].TxtPath := Lied; L[0].AudioPath := Ton;
  L[1].Index := 1; L[1].Artist := 'B'; L[1].Title := 'R';
  L[1].TxtPath := Lied; L[1].AudioPath := Roh;
  L[2].Index := 2; L[2].Artist := 'C'; L[2].Title := 'G';
  L[2].TxtPath := Lied; L[2].AudioPath := Gross;
  B.PublishSongs(L);

  S := TWebServerThread.Create(B, 8099, Ordner);
  Sleep(700);   // dem Server Zeit zum Binden geben

  WriteLn('Weboberflaeche');
  Status := Hole('/', Body);
  Check('Startseite liefert 200', Status = 200, IntToStr(Status));
  Check('und zwar die Datei, nicht die eingebaute Seite',
        Pos('<title>Test</title>', Body) > 0, Copy(Body, 1, 60));
  Status := Hole('/js/song.js', Body);
  Check('Modul wird ausgeliefert', (Status = 200) and (Pos('export', Body) > 0),
        IntToStr(Status));

  WriteLn('Liedateien');
  Status := Hole('/api/song/0/txt', Body);
  Check('Liedtext kommt an', (Status = 200) and (Pos('#BPM:120', Body) > 0),
        IntToStr(Status));
  Status := Hole('/api/song/0/audio', Body);
  Check('Ton kommt ganz an', (Status = 200) and (Body = '0123456789'),
        IntToStr(Status) + ' ' + Body);

  // Der Fehler, der hier lauert: Wird der Inhalt als Text behandelt, kommen
  // Zeilenenden hinzu oder werden umgeschrieben - die Datei ist dann kaputt,
  // ohne dass Status oder Laenge etwas verraten.
  Status := Hole('/api/song/1/audio', Body);
  Check('Bytes kommen unveraendert an',
        (Status = 200) and (Body = RohBytes) and (Length(Body) = 9),
        IntToStr(Status) + ' Laenge ' + IntToStr(Length(Body)));

  WriteLn('Teilbereiche');
  Status := Hole('/api/song/0/audio', Body, 'bytes=3-5');
  Check('Teilbereich liefert 206', Status = 206, IntToStr(Status));
  Check('und genau die angefragten Zeichen', Body = '345', Body);
  Status := Hole('/api/song/0/audio', Body, 'bytes=7-');
  Check('offenes Ende geht bis zum Schluss', (Status = 206) and (Body = '789'),
        Body);
  Status := Hole('/api/song/0/audio', Body, 'bytes=0-999');
  Check('zu grosses Ende wird gekappt, nicht abgelehnt',
        (Status = 206) and (Body = '0123456789'), IntToStr(Status) + ' ' + Body);
  Status := Hole('/api/song/0/audio', Body, 'bytes=0-');
  Check('bytes=0- liefert 206, nicht 200',
        (Status = 206) and (Body = '0123456789'), IntToStr(Status));

  WriteLn('Verbindungen');
  // Der Server schliesst nach jeder Antwort. Sagt er das nicht dazu, haelt
  // ein Vorschalt-Server die Verbindung fuer wiederverwendbar, schreibt
  // beim naechsten Mal in einen toten Anschluss und macht daraus einen
  // Serverfehler. Das ist im Betrieb passiert.
  Status := Hole('/api/status', Body);
  Check('Antwort sagt, dass die Verbindung schliesst',
        Pos('close', LowerCase(LetzterKopf)) > 0, LetzterKopf);
  Hole('/gibtesnicht', Body);
  Check('auch bei 404', Pos('close', LowerCase(LetzterKopf)) > 0, LetzterKopf);
  Hole('/api/song/0/audio', Body);
  Check('auch beim Ausliefern einer Datei',
        Pos('close', LowerCase(LetzterKopf)) > 0, LetzterKopf);

  WriteLn('Grosse Dateien');
  // Eine Datei ueber der Grenze darf nicht am Stueck in den Speicher gehen.
  // Geprueft wird ueber die Antwort: Sie muss gekuerzt sein und das auch
  // sagen, statt die ganze Datei zu behaupten.
  Status := Hole('/api/song/2/audio', Body);
  Check('zu grosse Datei wird gestueckelt', Status = 206, IntToStr(Status));
  Check('und zwar auf die Obergrenze',
        Length(Body) = WEB_MAX_STUECK,
        IntToStr(Length(Body)) + ' statt ' + IntToStr(WEB_MAX_STUECK));

  Status := Hole('/api/song/2/audio', Body, 'bytes=0-');
  Check('auch bei offenem Ende gekuerzt',
        (Status = 206) and (Length(Body) = WEB_MAX_STUECK),
        IntToStr(Length(Body)));

  WriteLn('Abweisen');
  Status := Hole('/api/song/9/txt', Body);
  Check('unbekanntes Lied: 404', Status = 404, IntToStr(Status));
  Status := Hole('/js/../lied.txt', Body);
  Check('Ausbruch aus dem Webordner scheitert', Status <> 200, IntToStr(Status));
  Status := Hole('/lied.txt', Body);
  Check('nicht aufgefuehrte Datei im Webordner bleibt verschlossen',
        Status <> 200, IntToStr(Status));
  Status := Hole('/api/status', Body);
  Check('Api antwortet weiterhin', (Status = 200) and (Pos('songs', Body) > 0),
        IntToStr(Status));

  WriteLn('Beenden');
  S.Stop;
  // WaitFor darf nicht haengen - im Spiel wuerde das den Ausstieg blockieren.
  S.WaitFor;
  Check('Server beendet sich', true);
  S.Free;
  B.Free;

  DeleteFile(Lied); DeleteFile(Ton); DeleteFile(Roh); DeleteFile(Gross);
  DeleteFile(Ordner + 'index.html');
  DeleteFile(Ordner + 'js' + PathDelim + 'song.js');
  RemoveDir(Ordner + 'js'); RemoveDir(Ordner);

  WriteLn;
  WriteLn(Format('%d bestanden, %d fehlgeschlagen', [Bestanden, Fehlgeschlagen]));
  if Fehlgeschlagen > 0 then Halt(1);
end.
