unit UWebCrypto;

(*
 * Verschluesselung der Liedateien fuer die Weboberflaeche.
 *
 * Wozu: Ohne das liegt hinter /api/song/N/audio eine fertige MP3. Wer die
 * Adresse kennt, laedt mit einer Zeile wget die ganze Sammlung herunter -
 * die Anmeldung am Vorschalt-Server schuetzt die Liste, nicht die Dateien
 * dahinter, sobald ein Zugang einmal vergeben ist.
 *
 * Was das NICHT leistet: Der Browser muss den Schluessel haben, sonst koennte
 * er nichts abspielen. Wer die Entwicklerwerkzeuge aufmacht, kommt also
 * heran. Das Ziel ist die Huerde, nicht die Unmoeglichkeit: aus "Adresse
 * aufrufen" wird "Sitzung anfordern, ChaCha20 nachbauen, Strom entschluesseln".
 *
 * Warum ChaCha20 und nicht AES: FPC 3.2.2 bringt kein brauchbares AES mit
 * (blowfish ist alles, was in fcl-base steht), und eine weitere Bibliothek
 * wollen wir hier so wenig wie den HTTP-Server oder das JSON. ChaCha20 ist
 * in hundert Zeilen vollstaendig hinzuschreiben - hier wie im Browser.
 *
 * Warum ein STROM-Verfahren und kein Blockverfahren mit Betriebsart: Das
 * Byte an Stelle N haengt nur von N ab, von keinem anderen Byte. Damit
 * bleibt der Teilbereich (Range) genau so, wie er ist - der Server
 * entschluesselt ab Stelle N weiter, ohne dass der Browser je den Anfang
 * der Datei gesehen haben muss. Mit CBC oder aehnlichem waere Springen im
 * Lied nicht mehr moeglich, und ohne Springen gibt es weder Dauer-Anzeige
 * noch Vorschau ab der Mitte.
 *)

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

interface

uses
  SysUtils,
  Classes,
  SyncObjs;

const
  // Wie lange eine ausgegebene Sitzung gilt. Lang genug fuer ein langes
  // Lied samt Pause, kurz genug, dass ein abgegriffener Schluessel nicht
  // ewig taugt. Jeder Zugriff schiebt die Frist weiter (siehe LookupKey).
  CRYPTO_TTL_SECONDS = 3600;

  // Obergrenze fuer gleichzeitige Sitzungen. Ohne sie koennte jemand durch
  // wiederholtes Anfordern beliebig viel Speicher belegen - die einzige
  // Route, die ohne weitere Angaben etwas anlegt.
  CRYPTO_MAX_SESSIONS = 256;

type
  TChaChaKey   = array[0..31] of byte;
  TChaChaNonce = array[0..11] of byte;

// Erzeugt Len Zufallsbytes aus der Quelle des Betriebssystems.
//
// AUSDRUECKLICH NICHT Random(): Das ist ein Mersenne-Twister, mit der Uhrzeit
// angestossen. Fuer einen Lobby-Code ist das recht; als Schluessel waere es
// in Minuten durchprobiert. Laesst sich keine Quelle oeffnen, fliegt eine
// Ausnahme - lieber keine Sitzung als eine mit vorhersagbarem Schluessel.
procedure SecureRandomBytes(var Buffer; Len: integer);

// Verschluesselt (und entschluesselt - beides ist dieselbe Rechnung) Data
// an Ort und Stelle. Offset ist die Stelle des ERSTEN Bytes in der
// vollstaendigen Datei, nicht im uebergebenen Stueck.
procedure ChaCha20XOR(const Key: TChaChaKey; const Nonce: TChaChaNonce;
                      Offset: int64; var Data; Len: integer);

// Der Einmalwert fuer eine Datei. Muss je Schluessel eindeutig sein, geheim
// muss er nicht sein - deshalb schlicht aus Liednummer und Dateiart
// gerechnet, statt ihn mit zu uebertragen. Der Browser rechnet dasselbe.
function NonceForFile(SongIndex, Kind: integer): TChaChaNonce;

function BytesToHex(const Buffer; Len: integer): UTF8String;
// False, wenn Hex nicht genau Len Bytes in sauberem Hex enthaelt.
function HexToBytes(const Hex: UTF8String; var Buffer; Len: integer): boolean;

type
  TCryptoSession = record
    Sid: UTF8String;
    Key: TChaChaKey;
    LastSeen: TDateTime;
  end;

  // Die ausgegebenen Sitzungsschluessel.
  //
  // Eigene Einheit und eigenes Schloss, aus demselben Grund wie bei
  // TLobbyRegistry: Der Liederkatalog und die fluechtigen Schluessel sind
  // verschiedene Belange, und der Webserver-Thread greift hier bei JEDEM
  // Stueck Ton zu - das soll nicht am Katalog haengen.
  TCryptoSessions = class
    private
      fLock: TCriticalSection;
      fSessions: array of TCryptoSession;
      function IndexVonSid(const Sid: UTF8String): integer;  // nur unter Lock
      procedure Aufraeumen(Jetzt: TDateTime);                // nur unter Lock
    public
      constructor Create;
      destructor Destroy; override;

      // Legt eine Sitzung an und gibt Kennung und Schluessel heraus.
      procedure NewSession(out Sid: UTF8String; out Key: TChaChaKey);
      // Schluessel zu einer Kennung. False, wenn unbekannt oder abgelaufen.
      function LookupKey(const Sid: UTF8String; out Key: TChaChaKey): boolean;
      function Count: integer;
      // NUR fuer Tests: setzt LastSeen direkt, damit sich das Ablaufen
      // pruefen laesst, ohne CRYPTO_TTL_SECONDS lang zu warten.
      procedure SetzeLastSeenFuerTest(const Sid: UTF8String; Zeit: TDateTime);
  end;

implementation

{$IFDEF MSWINDOWS}
// Von Hand deklariert: FPCs windows-Unit kennt die CryptoAPI nicht.
const
  PROV_RSA_FULL       = 1;
  CRYPT_VERIFYCONTEXT = $F0000000;
  CRYPT_SILENT        = $00000040;

function CryptAcquireContextA(phProv: PPtrUInt; pszContainer, pszProvider: PAnsiChar;
  dwProvType, dwFlags: cardinal): longbool;
  stdcall; external 'advapi32.dll' name 'CryptAcquireContextA';
function CryptGenRandom(hProv: PtrUInt; dwLen: cardinal; pbBuffer: pointer): longbool;
  stdcall; external 'advapi32.dll' name 'CryptGenRandom';
function CryptReleaseContext(hProv: PtrUInt; dwFlags: cardinal): longbool;
  stdcall; external 'advapi32.dll' name 'CryptReleaseContext';
{$ENDIF}

// --- Zufall ---------------------------------------------------------------

procedure SecureRandomBytes(var Buffer; Len: integer);
{$IFDEF MSWINDOWS}
var
  Prov: PtrUInt;
  Ok: boolean;
begin
  if (Len <= 0) then Exit;
  Prov := 0;
  if not CryptAcquireContextA(@Prov, nil, nil, PROV_RSA_FULL,
                              CRYPT_VERIFYCONTEXT or CRYPT_SILENT) then
    raise Exception.Create('Keine Zufallsquelle verfuegbar (CryptoAPI)');
  try
    Ok := CryptGenRandom(Prov, cardinal(Len), @Buffer);
  finally
    CryptReleaseContext(Prov, 0);
  end;
  if not Ok then
    raise Exception.Create('Zufallsquelle lieferte nichts');
end;
{$ELSE}
var
  Datei: TFileStream;
begin
  if (Len <= 0) then Exit;
  // /dev/urandom, nicht /dev/random: urandom blockiert nicht und ist auf
  // jedem System, das dieses Jahrtausend gebaut wurde, genauso gut.
  try
    Datei := TFileStream.Create('/dev/urandom', fmOpenRead or fmShareDenyNone);
  except
    raise Exception.Create('Keine Zufallsquelle verfuegbar (/dev/urandom)');
  end;
  try
    Datei.ReadBuffer(Buffer, Len);
  finally
    Datei.Free;
  end;
end;
{$ENDIF}

// --- ChaCha20 (RFC 8439) --------------------------------------------------

// Ohne Ueberlauf- und Bereichspruefung. Das Verfahren rechnet ABSICHTLICH
// modulo 2^32; mit -Ciro (so bauen die Tests) flaege sonst bei der ersten
// Addition eine Ausnahme statt eines Schluesselstroms.
{$push}
{$Q-}
{$R-}

type
  TChaChaState = array[0..15] of cardinal;

function RotL(X: cardinal; N: byte): cardinal; {$IFDEF HasInline}inline;{$ENDIF}
begin
  Result := (X shl N) or (X shr (32 - N));
end;

procedure QuarterRound(var S: TChaChaState; A, B, C, D: integer);
  {$IFDEF HasInline}inline;{$ENDIF}
begin
  S[A] := S[A] + S[B];  S[D] := RotL(S[D] xor S[A], 16);
  S[C] := S[C] + S[D];  S[B] := RotL(S[B] xor S[C], 12);
  S[A] := S[A] + S[B];  S[D] := RotL(S[D] xor S[A], 8);
  S[C] := S[C] + S[D];  S[B] := RotL(S[B] xor S[C], 7);
end;

function LeWord(const B; Offset: integer): cardinal;
  {$IFDEF HasInline}inline;{$ENDIF}
var
  P: PByte;
begin
  P := PByte(@B) + Offset;
  Result := cardinal(P[0]) or (cardinal(P[1]) shl 8) or
            (cardinal(P[2]) shl 16) or (cardinal(P[3]) shl 24);
end;

// Ein Block Schluesselstrom (64 Byte) zur Blocknummer Counter.
procedure ChaChaBlock(const Key: TChaChaKey; const Nonce: TChaChaNonce;
                      Counter: cardinal; out Block: array of byte);
var
  S, Anfang: TChaChaState;
  I, Runde: integer;
  W: cardinal;
begin
  // "expand 32-byte k" - die vier festen Woerter aus RFC 8439.
  Anfang[0] := $61707865;
  Anfang[1] := $3320646E;
  Anfang[2] := $79622D32;
  Anfang[3] := $6B206574;
  for I := 0 to 7 do
    Anfang[4 + I] := LeWord(Key, I * 4);
  Anfang[12] := Counter;
  for I := 0 to 2 do
    Anfang[13 + I] := LeWord(Nonce, I * 4);

  S := Anfang;
  // 20 Runden = zehnmal Spalten- und Diagonalrunde.
  for Runde := 1 to 10 do
  begin
    QuarterRound(S, 0, 4,  8, 12);
    QuarterRound(S, 1, 5,  9, 13);
    QuarterRound(S, 2, 6, 10, 14);
    QuarterRound(S, 3, 7, 11, 15);
    QuarterRound(S, 0, 5, 10, 15);
    QuarterRound(S, 1, 6, 11, 12);
    QuarterRound(S, 2, 7,  8, 13);
    QuarterRound(S, 3, 4,  9, 14);
  end;

  for I := 0 to 15 do
  begin
    W := S[I] + Anfang[I];
    Block[I * 4]     := byte(W);
    Block[I * 4 + 1] := byte(W shr 8);
    Block[I * 4 + 2] := byte(W shr 16);
    Block[I * 4 + 3] := byte(W shr 24);
  end;
end;

procedure ChaCha20XOR(const Key: TChaChaKey; const Nonce: TChaChaNonce;
                      Offset: int64; var Data; Len: integer);
var
  Block: array[0..63] of byte;
  Ziel: PByte;
  Counter: int64;
  Im, Nimm, I, Getan: integer;
begin
  if (Len <= 0) then Exit;
  if (Offset < 0) then
    raise Exception.Create('ChaCha20: negative Stelle');

  Ziel := PByte(@Data);
  // Der Strom ist in 64-Byte-Bloecke geteilt. Welcher Block das erste Byte
  // enthaelt und wie weit es darin steht, ergibt sich allein aus der Stelle -
  // genau deshalb laesst sich mitten in der Datei einsteigen.
  Counter := Offset div 64;
  Im := Offset mod 64;
  Getan := 0;

  while (Getan < Len) do
  begin
    ChaChaBlock(Key, Nonce, cardinal(Counter), Block);
    Nimm := 64 - Im;
    if (Nimm > Len - Getan) then Nimm := Len - Getan;
    for I := 0 to Nimm - 1 do
      Ziel[Getan + I] := Ziel[Getan + I] xor Block[Im + I];
    Inc(Getan, Nimm);
    Inc(Counter);
    Im := 0;
  end;
end;

{$pop}

function NonceForFile(SongIndex, Kind: integer): TChaChaNonce;
var
  I: integer;
  Wert: int64;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result[0] := byte(Kind);
  // Liednummer als 64-Bit-Wert, kleinstwertiges Byte zuerst. Zusammen mit
  // der Dateiart ist das je Schluessel eindeutig - mehr braucht ein
  // Einmalwert nicht.
  Wert := SongIndex;
  for I := 0 to 7 do
    Result[4 + I] := byte(Wert shr (I * 8));
end;

// --- Hex ------------------------------------------------------------------

function BytesToHex(const Buffer; Len: integer): UTF8String;
const
  Ziffern: array[0..15] of char = '0123456789abcdef';
var
  P: PByte;
  I: integer;
begin
  SetLength(Result, Len * 2);
  P := PByte(@Buffer);
  for I := 0 to Len - 1 do
  begin
    Result[I * 2 + 1] := Ziffern[P[I] shr 4];
    Result[I * 2 + 2] := Ziffern[P[I] and $0F];
  end;
end;

function HexZiffer(C: char; out Wert: integer): boolean;
begin
  Result := True;
  case C of
    '0'..'9': Wert := Ord(C) - Ord('0');
    'a'..'f': Wert := Ord(C) - Ord('a') + 10;
    'A'..'F': Wert := Ord(C) - Ord('A') + 10;
  else
    Wert := 0;
    Result := False;
  end;
end;

function HexToBytes(const Hex: UTF8String; var Buffer; Len: integer): boolean;
var
  P: PByte;
  I, Hoch, Tief: integer;
begin
  Result := False;
  if (Length(Hex) <> Len * 2) then Exit;
  P := PByte(@Buffer);
  for I := 0 to Len - 1 do
  begin
    if not HexZiffer(Hex[I * 2 + 1], Hoch) then Exit;
    if not HexZiffer(Hex[I * 2 + 2], Tief) then Exit;
    P[I] := byte((Hoch shl 4) or Tief);
  end;
  Result := True;
end;

// --- Sitzungen ------------------------------------------------------------

constructor TCryptoSessions.Create;
begin
  inherited Create;
  fLock := TCriticalSection.Create;
end;

destructor TCryptoSessions.Destroy;
begin
  SetLength(fSessions, 0);
  fLock.Free;
  inherited;
end;

function TCryptoSessions.IndexVonSid(const Sid: UTF8String): integer;
var
  I: integer;
begin
  Result := -1;
  if (Sid = '') then Exit;
  for I := 0 to High(fSessions) do
    if (fSessions[I].Sid = Sid) then
    begin
      Result := I;
      Exit;
    end;
end;

procedure TCryptoSessions.Aufraeumen(Jetzt: TDateTime);
var
  I, Ziel: integer;
  Grenze: TDateTime;
begin
  // Dieselbe Rechnung wie in UWebLobby: TDateTime zaehlt in Tagen.
  Grenze := Jetzt - (CRYPTO_TTL_SECONDS / 86400.0);
  Ziel := 0;
  for I := 0 to High(fSessions) do
    if (fSessions[I].LastSeen >= Grenze) then
    begin
      if (Ziel <> I) then
        fSessions[Ziel] := fSessions[I];
      Inc(Ziel);
    end
    else
      // Schluessel ueberschreiben, nicht nur den Eintrag fallen lassen.
      FillChar(fSessions[I].Key, SizeOf(TChaChaKey), 0);
  SetLength(fSessions, Ziel);
end;

procedure TCryptoSessions.NewSession(out Sid: UTF8String; out Key: TChaChaKey);
var
  Roh: array[0..15] of byte;
  N, I: integer;
begin
  // Zuerst wuerfeln, dann das Schloss nehmen: /dev/urandom zu lesen kann
  // kurz warten, und daran soll kein anderer Abruf haengen bleiben.
  SecureRandomBytes(Roh, SizeOf(Roh));
  SecureRandomBytes(Key, SizeOf(Key));
  Sid := BytesToHex(Roh, SizeOf(Roh));

  fLock.Acquire;
  try
    Aufraeumen(Now);
    // Ist die Grenze erreicht, faellt die aelteste Sitzung heraus. Sie ist
    // die mit dem groessten Abstand zu jetzt - fSessions ist nicht sortiert,
    // aber bei dieser Groessenordnung genuegt ein Durchlauf.
    if (Length(fSessions) >= CRYPTO_MAX_SESSIONS) then
    begin
      N := 0;
      for I := 1 to High(fSessions) do
        if (fSessions[I].LastSeen < fSessions[N].LastSeen) then N := I;
      FillChar(fSessions[N].Key, SizeOf(TChaChaKey), 0);
      for I := N to High(fSessions) - 1 do
        fSessions[I] := fSessions[I + 1];
      SetLength(fSessions, Length(fSessions) - 1);
    end;

    N := Length(fSessions);
    SetLength(fSessions, N + 1);
    fSessions[N].Sid := Sid;
    fSessions[N].Key := Key;
    fSessions[N].LastSeen := Now;
  finally
    fLock.Release;
  end;
end;

function TCryptoSessions.LookupKey(const Sid: UTF8String;
                                   out Key: TChaChaKey): boolean;
var
  I: integer;
begin
  Result := False;
  FillChar(Key, SizeOf(Key), 0);
  fLock.Acquire;
  try
    Aufraeumen(Now);
    I := IndexVonSid(Sid);
    if (I < 0) then Exit;
    // Jeder Zugriff schiebt die Frist weiter: Ein Lied kann laenger dauern
    // als die Frist, und mitten im Refrain den Ton zu verlieren waere die
    // aergerlichste Art, eine Sitzung ablaufen zu lassen.
    fSessions[I].LastSeen := Now;
    Key := fSessions[I].Key;
    Result := True;
  finally
    fLock.Release;
  end;
end;

procedure TCryptoSessions.SetzeLastSeenFuerTest(const Sid: UTF8String;
                                                Zeit: TDateTime);
var
  I: integer;
begin
  fLock.Acquire;
  try
    I := IndexVonSid(Sid);
    if (I >= 0) then
      fSessions[I].LastSeen := Zeit;
  finally
    fLock.Release;
  end;
end;

function TCryptoSessions.Count: integer;
begin
  fLock.Acquire;
  try
    Aufraeumen(Now);
    Result := Length(fSessions);
  finally
    fLock.Release;
  end;
end;

end.
