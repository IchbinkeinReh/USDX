program testwebcrypto;
(*
 * Prueft UWebCrypto - Schluesselstrom und Sitzungsschluessel.
 *
 * Der wichtigste Test ist der erste: ChaCha20 gegen die Testwerte aus
 * RFC 8439. Ein selbstgebautes Stromverfahren ver- und entschluesselt auch
 * dann fehlerfrei mit sich selbst, wenn es an einer Drehung oder einer
 * Bytereihenfolge danebenliegt - der Fehler faellt erst auf, wenn der
 * Browser die andere Haelfte rechnet. Gegen die Werte aus dem RFC geprueft,
 * rechnen beide Seiten nachweislich dasselbe.
 *
 * Die weiteren Zusagen:
 *   - Ab jeder Stelle einsteigen ergibt dasselbe wie am Stueck (sonst
 *     waere ein Teilbereich - Range - nicht mehr zu entschluesseln).
 *   - Schluessel kommen aus der Zufallsquelle des Systems, nicht aus Random.
 *   - Abgelaufene Sitzungen verschwinden, gueltige werden verlaengert.
 *)
{$MODE Delphi}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils,
  Classes,
  UWebCrypto;

var
  Bestanden, Fehlgeschlagen: integer;

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

// --- RFC 8439 -------------------------------------------------------------

// Die Leerzeichen stehen nur zum Lesen darin und fliegen vor dem Vergleich
// heraus - so laesst sich die Zeile im RFC danebenhalten.
function OhneLeer(const S: UTF8String): UTF8String;
begin
  Result := StringReplace(S, ' ', '', [rfReplaceAll]);
end;

function RfcKey: TChaChaKey;
var
  I: integer;
begin
  for I := 0 to 31 do
    Result[I] := byte(I);
end;

// Abschnitt 2.3.2: 00:00:00:09:00:00:00:4a:00:00:00:00
function RfcNonce: TChaChaNonce;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result[3] := $09;
  Result[7] := $4a;
end;

// Abschnitt 2.4.2 nimmt einen ANDEREN Einmalwert als 2.3.2 - vorne steht
// dort keine 9. Mit dem Wert aus 2.3.2 kommt ein sauberer, aber eben
// anderer Schluesseltext heraus; die Stelle uebersieht man leicht.
function RfcNonceText: TChaChaNonce;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result[7] := $4a;
end;

procedure PruefeRFC;
var
  Puffer: array[0..63] of byte;
  Erwartet, Bekommen: UTF8String;
begin
  // Der Schluesselstrom selbst ist das, was Nullbytes daraus machen.
  // Blocknummer 1 heisst Stelle 64.
  FillChar(Puffer, SizeOf(Puffer), 0);
  ChaCha20XOR(RfcKey, RfcNonce, 64, Puffer, SizeOf(Puffer));

  Erwartet := OhneLeer(
    '10f1e7e4 d13b5915 500fdd1f a32071c4 ' +
    'c7d1f4c7 33c06803 0422aa9a c3d46c4e ' +
    'd2826446 079faa09 14c2d705 d98b02a2 ' +
    'b5129cd1 de164eb9 cbd083e8 a2503c4e');

  Bekommen := BytesToHex(Puffer, SizeOf(Puffer));
  Check('ChaCha20-Block stimmt mit RFC 8439 2.3.2 ueberein',
        Bekommen = Erwartet, Bekommen);
end;

// Abschnitt 2.4.2: derselbe Schluessel und Einmalwert, Blocknummer 1, ein
// Satz Klartext - und der Schluesseltext dazu. Prueft zusaetzlich, dass
// Klartext und Strom richtig zusammenkommen.
procedure PruefeRFCText;
const
  Klartext = 'Ladies and Gentlemen of the class of ''99: ' +
             'If I could offer you only one tip for the future, ' +
             'sunscreen would be it.';
var
  Puffer: array of byte;
  Erwartet, Bekommen: UTF8String;
  I: integer;
begin
  SetLength(Puffer, Length(Klartext));
  for I := 1 to Length(Klartext) do
    Puffer[I - 1] := byte(Klartext[I]);

  ChaCha20XOR(RfcKey, RfcNonceText, 64, Puffer[0], Length(Puffer));

  Erwartet := OhneLeer(
    '6e2e359a 2568f980 41ba0728 dd0d6981 ' +
    'e97e7aec 1d4360c2 0a27afcc fd9fae0b ' +
    'f91b65c5 524733ab 8f593dab cd62b357 ' +
    '1639d624 e65152ab 8f530c35 9f0861d8 ' +
    '07ca0dbf 500d6a61 56a38e08 8a22b65e ' +
    '52bc514d 16ccf806 818ce91a b7793736 ' +
    '5af90bbf 74a35be6 b40b8eed f2785e42 ' +
    '874d');

  Bekommen := BytesToHex(Puffer[0], Length(Puffer));
  Check('ChaCha20 verschluesselt den RFC-Satz richtig',
        Bekommen = Erwartet, Bekommen);
end;

// --- Teilbereiche ---------------------------------------------------------

// Die Zusage, an der der ganze Aufbau haengt: Wer bei Stelle N einsteigt,
// bekommt dieselben Bytes wie der, der von vorne gerechnet hat. Ohne das
// waere ein Range nicht zu entschluesseln - und ohne Range gaebe es weder
// Dauer-Anzeige noch Springen im Lied.
procedure PruefeTeilbereiche;
var
  Key: TChaChaKey;
  Nonce: TChaChaNonce;
  AmStueck, Stueckweise: array of byte;
  I, Stelle, Laenge: integer;
  Gleich: boolean;
begin
  Key := RfcKey;
  Nonce := NonceForFile(7, 1);

  SetLength(AmStueck, 5000);
  SetLength(Stueckweise, 5000);
  for I := 0 to High(AmStueck) do
  begin
    AmStueck[I] := byte(I and $FF);
    Stueckweise[I] := byte(I and $FF);
  end;

  ChaCha20XOR(Key, Nonce, 0, AmStueck[0], Length(AmStueck));

  // Dieselben Daten in unregelmaessigen Stuecken - ausdruecklich nicht in
  // Vielfachen von 64, denn genau an einer Blockgrenze faellt ein falscher
  // Einstieg NICHT auf.
  Stelle := 0;
  Laenge := 1;
  while (Stelle < Length(Stueckweise)) do
  begin
    if (Stelle + Laenge > Length(Stueckweise)) then
      Laenge := Length(Stueckweise) - Stelle;
    ChaCha20XOR(Key, Nonce, Stelle, Stueckweise[Stelle], Laenge);
    Inc(Stelle, Laenge);
    Laenge := ((Laenge * 3) mod 97) + 1;
  end;

  Gleich := True;
  for I := 0 to High(AmStueck) do
    if (AmStueck[I] <> Stueckweise[I]) then Gleich := False;
  Check('stueckweise ab beliebiger Stelle ergibt dasselbe', Gleich);
end;

procedure PruefeHinUndZurueck;
var
  Key: TChaChaKey;
  Nonce: TChaChaNonce;
  Daten: array[0..999] of byte;
  I: integer;
  Heil, Veraendert: boolean;
begin
  Key := RfcKey;
  Nonce := NonceForFile(3, 0);
  for I := 0 to High(Daten) do
    Daten[I] := byte((I * 31) and $FF);

  ChaCha20XOR(Key, Nonce, 0, Daten, SizeOf(Daten));
  Veraendert := False;
  for I := 0 to High(Daten) do
    if (Daten[I] <> byte((I * 31) and $FF)) then Veraendert := True;
  Check('verschluesselt sieht anders aus als der Klartext', Veraendert);

  ChaCha20XOR(Key, Nonce, 0, Daten, SizeOf(Daten));
  Heil := True;
  for I := 0 to High(Daten) do
    if (Daten[I] <> byte((I * 31) and $FF)) then Heil := False;
  Check('zweimal angewandt ergibt wieder den Klartext', Heil);
end;

// Verschiedene Dateien derselben Sitzung duerfen NICHT denselben Strom
// bekommen - sonst verraet ein bekannter Klartext (etwa eine .txt) den
// Strom fuer die Tondatei daneben.
procedure PruefeEinmalwerte;
var
  A, B: TChaChaNonce;
  Gleich: boolean;
  I: integer;
begin
  A := NonceForFile(5, 0);
  B := NonceForFile(5, 1);
  Gleich := True;
  for I := 0 to 11 do
    if (A[I] <> B[I]) then Gleich := False;
  Check('gleiche Liednummer, andere Dateiart -> anderer Einmalwert', not Gleich);

  A := NonceForFile(5, 1);
  B := NonceForFile(6, 1);
  Gleich := True;
  for I := 0 to 11 do
    if (A[I] <> B[I]) then Gleich := False;
  Check('andere Liednummer -> anderer Einmalwert', not Gleich);
end;

// --- Hex ------------------------------------------------------------------

procedure PruefeHex;
var
  Key, Zurueck: TChaChaKey;
  Hex: UTF8String;
  I: integer;
  Gleich: boolean;
begin
  Key := RfcKey;
  Hex := BytesToHex(Key, SizeOf(Key));
  Check('Schluessel wird zu 64 Hexzeichen', Length(Hex) = 64, Hex);
  Check('Hex beginnt richtig', Copy(Hex, 1, 6) = '000102', Hex);

  Check('Hex laesst sich zurueckwandeln',
        HexToBytes(Hex, Zurueck, SizeOf(Zurueck)));
  Gleich := True;
  for I := 0 to 31 do
    if (Key[I] <> Zurueck[I]) then Gleich := False;
  Check('hin und zurueck ergibt denselben Schluessel', Gleich);

  Check('zu kurzes Hex wird abgelehnt',
        not HexToBytes('00ff', Zurueck, SizeOf(Zurueck)));
  Check('Hex mit Unfug darin wird abgelehnt',
        not HexToBytes(StringOfChar('z', 64), Zurueck, SizeOf(Zurueck)));
end;

// --- Zufall ---------------------------------------------------------------

procedure PruefeZufall;
var
  A, B: TChaChaKey;
  I, Verschieden, NichtNull: integer;
begin
  SecureRandomBytes(A, SizeOf(A));
  SecureRandomBytes(B, SizeOf(B));

  Verschieden := 0;
  NichtNull := 0;
  for I := 0 to 31 do
  begin
    if (A[I] <> B[I]) then Inc(Verschieden);
    if (A[I] <> 0) then Inc(NichtNull);
  end;
  // Kein Test auf Guete - das leistet ein Testprogramm nicht. Aber zwei
  // gleiche Schluessel hintereinander oder lauter Nullen verraten sofort,
  // dass die Quelle gar nicht gelesen wurde.
  Check('zwei Schluessel sind verschieden', Verschieden > 20, IntToStr(Verschieden));
  Check('Schluessel ist nicht lauter Nullen', NichtNull > 20, IntToStr(NichtNull));
end;

// --- Sitzungen ------------------------------------------------------------

procedure PruefeSitzungen;
var
  S: TCryptoSessions;
  SidA, SidB: UTF8String;
  KeyA, KeyB, Geholt: TChaChaKey;
  I, Gleich: integer;
begin
  S := TCryptoSessions.Create;
  try
    S.NewSession(SidA, KeyA);
    S.NewSession(SidB, KeyB);

    Check('Kennung ist 32 Hexzeichen', Length(SidA) = 32, SidA);
    Check('zwei Sitzungen haben verschiedene Kennungen', SidA <> SidB);

    Gleich := 0;
    for I := 0 to 31 do
      if (KeyA[I] = KeyB[I]) then Inc(Gleich);
    Check('zwei Sitzungen haben verschiedene Schluessel', Gleich < 12,
          IntToStr(Gleich));

    Check('Schluessel laesst sich nachschlagen', S.LookupKey(SidA, Geholt));
    Gleich := 0;
    for I := 0 to 31 do
      if (KeyA[I] = Geholt[I]) then Inc(Gleich);
    Check('nachgeschlagen kommt derselbe Schluessel', Gleich = 32);

    Check('unbekannte Kennung wird abgelehnt',
          not S.LookupKey('gibtesnicht', Geholt));
    Check('leere Kennung wird abgelehnt', not S.LookupKey('', Geholt));

    // Ablaufen: LastSeen weit genug zurueckdrehen.
    S.SetzeLastSeenFuerTest(SidA, Now - ((CRYPTO_TTL_SECONDS + 60) / 86400.0));
    Check('abgelaufene Sitzung wird abgelehnt', not S.LookupKey(SidA, Geholt));
    Check('die andere Sitzung lebt weiter', S.LookupKey(SidB, Geholt));
    Check('abgelaufene ist auch weggeraeumt', S.Count = 1, IntToStr(S.Count));

    // Und die Verlaengerung: Ein Zugriff kurz vor Schluss haelt sie am Leben.
    S.SetzeLastSeenFuerTest(SidB, Now - ((CRYPTO_TTL_SECONDS - 30) / 86400.0));
    Check('kurz vor Schluss noch gueltig', S.LookupKey(SidB, Geholt));
    S.SetzeLastSeenFuerTest(SidB, Now - ((CRYPTO_TTL_SECONDS - 30) / 86400.0));
    Check('und der Zugriff hat sie verlaengert', S.LookupKey(SidB, Geholt));
  finally
    S.Free;
  end;
end;

procedure PruefeObergrenze;
var
  S: TCryptoSessions;
  Sid: UTF8String;
  Key: TChaChaKey;
  I: integer;
begin
  S := TCryptoSessions.Create;
  try
    for I := 1 to CRYPTO_MAX_SESSIONS + 20 do
      S.NewSession(Sid, Key);
    Check('Zahl der Sitzungen bleibt begrenzt',
          S.Count <= CRYPTO_MAX_SESSIONS, IntToStr(S.Count));
    // Die zuletzt ausgegebene muss noch da sein - sonst fiele ausgerechnet
    // der gerade Fragende heraus.
    Check('die neueste Sitzung ueberlebt', S.LookupKey(Sid, Key));
  finally
    S.Free;
  end;
end;

begin
  Bestanden := 0;
  Fehlgeschlagen := 0;

  WriteLn('RFC 8439');
  PruefeRFC;
  PruefeRFCText;

  WriteLn('Teilbereiche');
  PruefeTeilbereiche;
  PruefeHinUndZurueck;
  PruefeEinmalwerte;

  WriteLn('Hex');
  PruefeHex;

  WriteLn('Zufall');
  PruefeZufall;

  WriteLn('Sitzungen');
  PruefeSitzungen;
  PruefeObergrenze;

  WriteLn;
  WriteLn(Format('%d bestanden, %d fehlgeschlagen', [Bestanden, Fehlgeschlagen]));
  if Fehlgeschlagen > 0 then
    Halt(1);
end.
