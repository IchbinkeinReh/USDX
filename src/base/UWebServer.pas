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
  UWebBridge;

type
  TWebServerThread = class(TThread)
    private
      fServer:  TFPHttpServer;
      fBridge:  TWebBridge;
      fPort:    word;
      procedure HandleRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest;
                              var AResponse: TFPHTTPConnectionResponse);
    protected
      procedure Execute; override;
    public
      constructor Create(ABridge: TWebBridge; APort: word);
      destructor Destroy; override;
      procedure Stop;
  end;

const
  WEB_DEFAULT_PORT = 8080;

implementation

uses
  ULog,
  UWebApi;

constructor TWebServerThread.Create(ABridge: TWebBridge; APort: word);
begin
  fBridge := ABridge;
  fPort := APort;
  FreeOnTerminate := false;
  inherited Create(false);
end;

destructor TWebServerThread.Destroy;
begin
  fServer.Free;
  inherited;
end;

procedure TWebServerThread.Stop;
begin
  Terminate;
  if Assigned(fServer) then
    fServer.Active := false;
end;

procedure TWebServerThread.HandleRequest(Sender: TObject;
  var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  ContentType, Body: UTF8String;
begin
  try
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
      Log.LogError('Web request failed: ' + E.Message, 'UWebServer');
      AResponse.Code := 500;
      AResponse.ContentType := 'text/plain; charset=utf-8';
      AResponse.Content := 'Fehler';
    end;
  end;
end;

procedure TWebServerThread.Execute;
begin
  fServer := TFPHttpServer.Create(nil);
  try
    fServer.Port := fPort;
    fServer.Threaded := true;
    fServer.OnRequest := HandleRequest;
    Log.LogStatus(Format('Web interface on port %d', [fPort]), 'UWebServer');
    try
      fServer.Active := true;   // blockiert bis Active := false
    except
      on E: Exception do
        Log.LogError('Web server stopped: ' + E.Message, 'UWebServer');
    end;
  finally
    // fServer wird im Destruktor freigegeben
  end;
end;

end.
