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
  UWebBridge;

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
      fServer:  TBindbarerServer;
      fBridge:  TWebBridge;
      fPort:    word;
      fWebRoot: UTF8String;
      fAdresse: UTF8String;
      procedure SendeDatei(const Pfad, ContentType: UTF8String;
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
      constructor Create(ABridge: TWebBridge; APort: word;
                         const AWebRoot: UTF8String = '';
                         const AAdresse: UTF8String = '');
      destructor Destroy; override;
      procedure Stop;
  end;

const
  WEB_DEFAULT_PORT = 8080;

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

constructor TWebServerThread.Create(ABridge: TWebBridge; APort: word;
                                   const AWebRoot: UTF8String = '';
                                   const AAdresse: UTF8String = '');
begin
  fBridge := ABridge;
  fPort := APort;
  fWebRoot := AWebRoot;
  fAdresse := AAdresse;
  FreeOnTerminate := false;
  inherited Create(false);
end;

destructor TWebServerThread.Destroy;
begin
  fServer.Free;
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

    // Ueber einen Stream, nicht ueber AResponse.Content: Content wird intern
    // als Zeilenliste gefuehrt und haengt beim Senden Zeilenenden an. Bei
    // Text faellt das kaum auf, bei einer MP3 macht es die Datei kaputt.
    Teil := TMemoryStream.Create;
    if (Bis >= Von) then
    begin
      Datei.Position := Von;
      Teil.CopyFrom(Datei, Bis - Von + 1);
    end;
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
begin
  try
    // Erst pruefen, ob eine Datei gefragt ist. Die Entscheidung faellt in
    // UWebApi, damit sie ohne laufenden Server pruefbar bleibt.
    case ResolveFileRequest(fBridge, ARequest.PathInfo, fWebRoot,
                            Pfad, ContentType) of
      waDatei:
        begin
          SendeDatei(Pfad, ContentType, ARequest, AResponse);
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
    AResponse.Code := HandleWebRequest(fBridge, ARequest.PathInfo,
                                       ARequest.QueryFields,
                                       ContentType, Body);
    AResponse.ContentType := ContentType;
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
