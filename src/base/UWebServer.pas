unit UWebServer;

(*
 * Weboberflaeche zur Fernbedienung, eingeschaltet mit --web.
 *
 * Laeuft in einem eigenen Thread und spricht ausschliesslich mit
 * UWebBridge - nie mit den Datenstrukturen des Spiels. Alles, was das Spiel
 * betrifft, wandert als Befehl in die Schlange und wird vom Spielthread
 * ausgefuehrt.
 *
 * HTTP-Server und JSON kommen aus der FPC-Standardbibliothek
 * (fphttpserver, fpjson) - keine zusaetzliche Abhaengigkeit.
 *
 * ACHTUNG: Der Server hat KEINE Anmeldung. Wer im selben Netz ist, kann die
 * Liederliste sehen und Lieder auswaehlen. Deshalb bindet er standardmaessig
 * an alle Adressen des Heimnetzes, aber der Port ist bewusst zu nennen, und
 * ins Internet gehoert das nicht.
 *)

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

interface

uses
  SysUtils,
  Classes,
  fphttpserver,
  httpdefs,
  ssockets,
  UWebBridge,
  UWebCrypto,
  UWebLobby,
  UWebZaehler;

type
  // TFPHttpServer veroeffentlicht die Bindeadresse nicht - sie liegt im
  // Vorfahren unter protected. Ein Nachfahre darf die Sichtbarkeit anheben;
  // das ist die ganze Aufgabe dieser Klasse.
  TBindbarerServer = class(TFPHttpServer)
    public
      property Address;
  end;

  TWebServerThread = class(TThread)
    private
      fServer:   TBindbarerServer;
      fBridge:   TWebBridge;
      fLobby:    TLobbyRegistry;
      fSessions: TCryptoSessions;
      fZaehler:  TWebZaehler;
      fPort:     word;
      fWebRoot:  UTF8String;
      fAdresse:  UTF8String;
      // Schluesseln <> nil heisst: den Inhalt vor dem Senden verschluesseln.
      procedure SendeDatei(const Pfad, ContentType: UTF8String;
                           Schluesseln: boolean;
                           const Key: TChaChaKey; const Nonce: TChaChaNonce;
                           var ARequest: TFPHTTPConnectionRequest;
                           var AResponse: TFPHTTPConnectionResponse);
      procedure HandleRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest;
                              var AResponse: TFPHTTPConnectionResponse);
    protected
      procedure Execute; override;
    public
      // AWebRoot ist der Ordner mit index.html und js/. Leer heisst: nur die
      // eingebaute Fernbedienungsseite.
      // AAdresse begrenzt, von wo aus der Server erreichbar ist. Leer heisst
      // "von ueberall" - richtig fuer das Heimnetz. Steht der Server hinter
      // einem Vorschalt-Server, der die Anmeldung prueft, MUSS hier
      // 127.0.0.1 stehen: Sonst ist der Port unter Umgehung der Anmeldung
      // direkt aus dem Netz erreichbar, und die Anmeldung ist wertlos.
      constructor Create(ABridge: TWebBridge; ALobby: TLobbyRegistry; APort: word;
                         const AWebRoot: UTF8String = '';
                         const AAdresse: UTF8String = '';
                         const AZaehlerOrdner: UTF8String = '');
      // Nur zum Nachsehen in Tests - der Server besitzt den Zaehler.
      property Zaehler: TWebZaehler read fZaehler;
      destructor Destroy; override;
      procedure Stop;
  end;

const
  WEB_DEFAULT_PORT = 8080;

  // Groesste Menge, die eine einzelne Antwort in den Speicher legt.
  //
  // Ein Lied bringt schnell ein paar hundert MB Video mit. Wuerde davon
  // jede Anfrage alles auf einmal einlesen, koennte eine Handvoll
  // gleichzeitiger Zugriffe den Rechner leerraeumen - und bei einer von
  // aussen erreichbaren Oberflaeche waere das ein Hebel, an dem jeder
  // ziehen kann. Wird mehr angefordert, antwortet der Server mit weniger;
  // das ist erlaubt (RFC 7233) und die uebliche Arbeitsweise beim Streamen.
  WEB_MAX_STUECK = 8 * 1024 * 1024;

var
  // Wohin der Server meldet. Bewusst ein Haken statt eines "uses ULog":
  // ULog zieht ueber UMain und UMusic ganz SDL herein, und dann liesse sich
  // der Server hier nicht mehr ohne Bildschirm pruefen. UMain haengt das
  // Spielprotokoll ein, im Test bleibt es leer.
  WebLogHandler: procedure(const Nachricht: UTF8String; Fehler: boolean) = nil;

implementation

uses
  StrUtils,
  UWebApi;

procedure Melde(const Nachricht: UTF8String; Fehler: boolean);
begin
  if Assigned(WebLogHandler) then
    WebLogHandler(Nachricht, Fehler);
end;

constructor TWebServerThread.Create(ABridge: TWebBridge; ALobby: TLobbyRegistry;
                                   APort: word;
                                   const AWebRoot: UTF8String = '';
                                   const AAdresse: UTF8String = '';
                                   const AZaehlerOrdner: UTF8String = '');
begin
  fBridge := ABridge;
  fLobby := ALobby;
  fPort := APort;
  fWebRoot := AWebRoot;
  fAdresse := AAdresse;
  // Die Sitzungsschluessel gehoeren dem Server und leben genau so lange wie
  // er. Ein Neustart macht alle ausgegebenen Schluessel ungueltig - das ist
  // gewollt: Sie stehen nirgends auf der Platte.
  fSessions := TCryptoSessions.Create;
  fZaehler := TWebZaehler.Create(AZaehlerOrdner);
  FreeOnTerminate := false;
  inherited Create(false);
end;

destructor TWebServerThread.Destroy;
begin
  fServer.Free;
  fSessions.Free;
  fZaehler.Free;
  inherited;
end;

procedure TWebServerThread.Stop;
var
  Wecker: TInetSocket;
begin
  Terminate;
  if not Assigned(fServer) then
    Exit;
  fServer.Active := false;

  // Active := false allein genuegt nicht: Der Server haengt in accept() und
  // merkt vom Abschalten erst etwas, wenn die naechste Verbindung eintrifft.
  // Ohne diesen Anstupser wartet das Spiel beim Beenden endlos.
  try
    Wecker := TInetSocket.Create(
      IfThen(fAdresse <> '', fAdresse, '127.0.0.1'), fPort);
    Wecker.Free;
  except
    // Der Server ist schon zu - genau das wollten wir.
  end;
end;

// Liefert eine Datei aus, auf Wunsch auch nur ein Stueck davon.
//
// Der Teilbereich ist fuer Ton nicht Beiwerk: Ohne ihn zeigt der Browser bei
// laengeren Aufnahmen keine Dauer an und kann nicht springen - man koennte
// ein Lied nur von vorne bis hinten hoeren.
procedure TWebServerThread.SendeDatei(const Pfad, ContentType: UTF8String;
  Schluesseln: boolean;
  const Key: TChaChaKey; const Nonce: TChaChaNonce;
  var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  Datei: TFileStream;
  Teil: TMemoryStream;
  Bereich, Zahl: string;
  Von, Bis, Gesamt: int64;
  Strich: integer;
  Gefragt: boolean;
begin
  Datei := TFileStream.Create(Pfad, fmOpenRead or fmShareDenyNone);
  try
    Gesamt := Datei.Size;
    Von := 0;
    Bis := Gesamt - 1;

    Gefragt := False;
    Bereich := ARequest.GetCustomHeader('Range');
    if (Copy(Bereich, 1, 6) = 'bytes=') then
    begin
      Gefragt := True;
      Zahl := Copy(Bereich, 7, Length(Bereich));
      Strich := Pos('-', Zahl);
      if (Strich > 0) then
      begin
        Von := StrToInt64Def(Copy(Zahl, 1, Strich - 1), 0);
        // Offenes Ende ("bytes=500-") ist der Normalfall beim Abspielen.
        Bis := StrToInt64Def(Copy(Zahl, Strich + 1, Length(Zahl)), Gesamt - 1);
      end;
    end;

    // Unsinnige Angaben zurechtruecken, statt sie abzulehnen: Ein zu grosses
    // Ende ist erlaubt und meint schlicht "bis zum Schluss".
    if (Von < 0) or (Von > Gesamt - 1) then Von := 0;
    if (Bis > Gesamt - 1) or (Bis < Von) then Bis := Gesamt - 1;

    // Zu grosse Stuecke kuerzen, siehe WEB_MAX_STUECK. Der Browser holt
    // sich den Rest mit der naechsten Anfrage.
    if (Bis - Von + 1 > WEB_MAX_STUECK) then
    begin
      Bis := Von + WEB_MAX_STUECK - 1;
      // Ab jetzt ist es ein Teilstueck, auch wenn niemand danach gefragt
      // hat - sonst behauptete die Antwort, die ganze Datei zu enthalten.
      Gefragt := True;
    end;

    // Ueber einen Stream, nicht ueber AResponse.Content: Content wird intern
    // als Zeilenliste gefuehrt und haengt beim Senden Zeilenenden an. Bei
    // Text faellt das kaum auf, bei einer MP3 macht es die Datei kaputt.
    Teil := TMemoryStream.Create;
    if (Bis >= Von) then
    begin
      Datei.Position := Von;
      Teil.CopyFrom(Datei, Bis - Von + 1);
    end;

    // Verschluesseln, NACHDEM das Stueck feststeht, und mit Von als Stelle
    // im Strom. Dass beides zusammenpasst, ist der ganze Grund fuer ein
    // Stromverfahren: Die Laenge bleibt gleich, Content-Range und
    // Content-Length stimmen weiter, und der Browser kann ab jeder Stelle
    // einsteigen, ohne den Anfang der Datei gesehen zu haben.
    if Schluesseln and (Teil.Size > 0) then
      ChaCha20XOR(Key, Nonce, Von, Teil.Memory^, Teil.Size);

    Teil.Position := 0;

    AResponse.ContentType := ContentType;
    AResponse.SetCustomHeader('Accept-Ranges', 'bytes');
    // Wer nach einem Bereich fragt, bekommt auch 206 - selbst wenn der
    // Bereich zufaellig die ganze Datei umfasst. "bytes=0-" ist die uebliche
    // erste Anfrage beim Abspielen, und ein 200 darauf bringt manche Browser
    // dazu, das Springen im Stueck gar nicht erst anzubieten.
    if Gefragt then
    begin
      AResponse.Code := 206;
      AResponse.SetCustomHeader('Content-Range',
        Format('bytes %d-%d/%d', [Von, Bis, Gesamt]));
    end
    else
      AResponse.Code := 200;
    // Der Stream gehoert ab hier der Antwort und wird von ihr freigegeben.
    AResponse.ContentStream := Teil;
    AResponse.ContentLength := Teil.Size;
    AResponse.FreeContentStream := true;
  finally
    Datei.Free;
  end;
end;

procedure TWebServerThread.HandleRequest(Sender: TObject;
  var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  ContentType, Body, Pfad: UTF8String;
  Schutz: TWebDateiSchutz;
  Key: TChaChaKey;
  Nonce: TChaChaNonce;
  Schluesseln: boolean;
  ZArtist, ZTitel: UTF8String;
begin
  // "Connection: close" gehoert an JEDE Antwort, und zwar zuerst, damit kein
  // Weg hier unten sie vergisst.
  //
  // Der Server schliesst die Verbindung nach jeder Antwort - Wiederverwendung
  // kann er nicht. Sagt er das nicht dazu, gilt bei HTTP/1.1 das Gegenteil:
  // Die Verbindung waere wiederverwendbar. Ein Vorschalt-Server legt sie
  // dann in seinen Vorrat, schreibt beim naechsten Mal in einen laengst
  // geschlossenen Anschluss und meldet dem Browser einen Serverfehler.
  //
  // Genau das ist passiert: vereinzelte 500er beim Laden der Seite, im
  // Protokoll "AH01102: error reading status line from remote server".
  AResponse.Connection := 'close';

  try
    // Erst pruefen, ob eine Datei gefragt ist. Die Entscheidung faellt in
    // UWebApi, damit sie ohne laufenden Server pruefbar bleibt.
    case ResolveFileRequest(fBridge, ARequest.PathInfo, fWebRoot,
                            Pfad, ContentType, Schutz) of
      waDatei:
        begin
          // Geschuetzte Dateien gibt es NUR verschluesselt. Ohne gueltige
          // Sitzung ist hier Schluss - es gibt bewusst keinen Rueckfall auf
          // die offene Datei, sonst genuegte das Weglassen des Parameters,
          // um die Verschluesselung zu umgehen.
          Schluesseln := Schutz.Noetig;
          if Schluesseln and
             not SchluesselFuerAnfrage(fSessions, Schutz,
                                       ARequest.QueryFields.Values['sid'],
                                       Key, Nonce) then
          begin
            AResponse.Code := 403;
            AResponse.ContentType := 'text/plain; charset=utf-8';
            AResponse.SetCustomHeader('Cache-Control', 'no-store');
            AResponse.Content := 'Keine gueltige Sitzung';
            Exit;
          end;
          // Lieddateien duerfen zwischengespeichert werden, die Oberflaeche
          // nicht.
          //
          // Titelbilder sind im Schnitt eine Viertelmegabyte gross. Ohne
          // diese Angabe holt der Browser jedes davon beim Zurueckblaettern
          // erneut - bei einer Liste mit neuntausend Eintraegen laeppert
          // sich das zu Hunderten von Megabyte. Die Dateien aendern sich
          // praktisch nie; ein Tag ist reichlich vorsichtig.
          //
          // Fuer index.html und die Module gilt das ausdruecklich NICHT:
          // Sonst liefe nach einer Aktualisierung tagelang die alte Fassung.
          //
          // Verschluesselte Dateien duerfen NICHT "public" sein: Die Bytes
          // gelten nur fuer diese eine Sitzung, und ein Vorschalt-Server
          // darf sie nicht an den naechsten Benutzer weiterreichen. "private"
          // erlaubt dem Browser selbst weiterhin, sie zu behalten - ohne das
          // holte er beim Zurueckspulen alles noch einmal.
          if Schluesseln then
            AResponse.SetCustomHeader('Cache-Control',
              Format('private, max-age=%d', [CRYPTO_TTL_SECONDS]))
          else if (Copy(ARequest.PathInfo, 1, 10) = '/api/song/') then
            AResponse.SetCustomHeader('Cache-Control', 'public, max-age=86400')
          else
            AResponse.SetCustomHeader('Cache-Control', 'no-cache');
          // Zaehlen, bevor das erste Byte hinausgeht.
          //
          // Am Ton haengt es, nicht an der Vorschau: Die Vorschau ist seit
          // dem eigenen Endpunkt sauber getrennt, und wer nur durch die
          // Liste blaettert, hat nichts gesungen. Die Karaoke-Tonspur zaehlt
          // GENAUSO wie die normale - gesungen wird so oder so, nur eben
          // ohne die Gesangsspur der Aufnahme.
          //
          // Der Durchgang kommt vom Browser und ueberlebt dort ein
          // Neuladen. Damit zaehlt dasselbe Singen nur einmal, ein zweites
          // Singen desselben Liedes aber wieder - und drei Leute, die
          // dasselbe Lied singen, dreimal.
          if (Schutz.Art in [Ord(wfkAudio), Ord(wfkAudioInstrumental)]) and
             (ARequest.QueryFields.Values['lauf'] <> '') and
             fBridge.SongInfo(Schutz.SongIndex, ZArtist, ZTitel) then
            fZaehler.Zaehle(ARequest.QueryFields.Values['lauf'],
                            Schutz.SongIndex, ZArtist, ZTitel);

          // Ob es eine Karaoke-Tonspur gibt, reist mit der Notendatei mit -
          // ein eigener Umweg ueber /api/songs waere eine zweite Anfrage fuer
          // etwas, das der Browser ohnehin schon abruft. Der Dienstarbeiter
          // reicht Kopfzeilen unveraendert durch (new Response(...,
          // {headers: antwort.headers}) in sw.js), die Seite liest sie also
          // trotz Verschluesselung.
          if (Schutz.Art = Ord(wfkTxt)) then
            AResponse.SetCustomHeader('X-Karaoke',
              IfThen(fBridge.HatInstrumental(Schutz.SongIndex), '1', '0'));

          SendeDatei(Pfad, ContentType, Schluesseln, Key, Nonce,
                     ARequest, AResponse);
          Exit;
        end;
      waFehlt:
        begin
          AResponse.Code := 404;
          AResponse.ContentType := 'text/plain; charset=utf-8';
          AResponse.Content := 'Nicht gefunden';
          Exit;
        end;
    end;

    // Die Wegewahl liegt in UWebApi - dort ohne SDL und damit pruefbar.
    AResponse.Code := HandleWebRequest(fBridge, fLobby, fSessions,
                                       ARequest.PathInfo,
                                       ARequest.QueryFields,
                                       ContentType, Body);
    AResponse.ContentType := ContentType;
    // Ein ausgegebener Schluessel gehoert in keinen Zwischenspeicher.
    if (ARequest.PathInfo = '/api/session') then
      AResponse.SetCustomHeader('Cache-Control', 'no-store');
    AResponse.Content := Body;
  except
    on E: Exception do
    begin
      // Ein Fehler in einer Anfrage darf den Server nicht beenden - sonst
      // waere die Fernbedienung nach dem ersten Missgriff tot.
      Melde('Web request failed: ' + E.Message, true);
      AResponse.Code := 500;
      AResponse.ContentType := 'text/plain; charset=utf-8';
      AResponse.Content := 'Fehler';
    end;
  end;
end;

procedure TWebServerThread.Execute;
begin
  fServer := TBindbarerServer.Create(nil);
  try
    fServer.Port := fPort;
    if (fAdresse <> '') then
      fServer.Address := fAdresse;
    fServer.Threaded := true;
    fServer.OnRequest := HandleRequest;
    if (fAdresse <> '') then
      Melde(Format('Web interface on %s port %d', [fAdresse, fPort]), false)
    else
      Melde(Format('Web interface on port %d', [fPort]), false);
    try
      fServer.Active := true;   // blockiert bis Active := false
    except
      on E: Exception do
        Melde('Web server stopped: ' + E.Message, true);
    end;
  finally
    // fServer wird im Destruktor freigegeben
  end;
end;

end.
