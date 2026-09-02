unit UWebPage;

(*
 * Die Weboberflaeche als eine Zeichenkette.
 *
 * Bewusst eingebettet statt als Datei daneben: Der Server soll auch dann
 * funktionieren, wenn das Spiel aus einem Archiv oder von einem Stick
 * gestartet wurde. Eine fehlende Datei waere ein Fehlerfall, den es so gar
 * nicht erst gibt.
 *
 * Kein Framework, keine externen Skripte - die Seite laedt im Heimnetz und
 * oft ohne Internet.
 *)

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

interface

function WebPageHTML: string;

implementation

function WebPageHTML: string;
begin
  Result :=
    '<!doctype html><html lang="de"><head>' +
    '<meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<title>UltraStar Deluxe</title><style>' +
    'body{font-family:system-ui,sans-serif;margin:0;background:#14161c;color:#e8e8ea}' +
    'header{padding:12px 16px;background:#1e2129;position:sticky;top:0}' +
    'h1{font-size:17px;margin:0 0 10px}' +
    'input,select{font-size:16px;padding:9px;border-radius:8px;border:1px solid #3a3f4b;' +
    'background:#0f1116;color:#e8e8ea}' +
    'input{width:100%;box-sizing:border-box;margin-bottom:8px}' +
    'select{width:100%}' +
    'ul{list-style:none;margin:0;padding:0}' +
    'li{padding:11px 16px;border-bottom:1px solid #262a33;cursor:pointer}' +
    'li:active{background:#2a2f3a}' +
    '.a{font-weight:600}.t{color:#b7bcc7;font-size:14px}' +
    '#msg{padding:10px 16px;color:#8f97a6;font-size:14px}' +
    '</style></head><body>' +
    '<header><h1>UltraStar Deluxe</h1>' +
    '<input id="q" placeholder="Suchen - auch abba OR queen, !live, 1990-1999">' +
    '<select id="m">' +
    '<option value="all">Alles</option>' +
    '<option value="title">Titel</option>' +
    '<option value="artist">Interpret</option>' +
    '<option value="genre">Genre</option>' +
    '<option value="language">Sprache</option>' +
    '<option value="edition">Edition</option>' +
    '<option value="year">Jahr</option>' +
    '</select></header>' +
    '<div id="msg">Lade …</div><ul id="l"></ul>' +
    '<script>' +
    'var q=document.getElementById("q"),m=document.getElementById("m"),' +
    'l=document.getElementById("l"),msg=document.getElementById("msg"),t=null;' +
    'function esc(s){var d=document.createElement("div");d.textContent=s;return d.innerHTML}' +
    'function suche(){' +
    'fetch("/api/songs?max=100&mode="+encodeURIComponent(m.value)+' +
    '"&q="+encodeURIComponent(q.value))' +
    '.then(function(r){return r.json()}).then(function(d){' +
    'l.innerHTML=d.map(function(s){return "<li data-i=\""+s.index+"\"><div class=\"a\">"+' +
    'esc(s.artist)+"</div><div class=\"t\">"+esc(s.title)+' +
    '(s.year?" · "+s.year:"")+"</div></li>"}).join("");' +
    'msg.textContent=d.length?d.length+" Treffer":"Nichts gefunden";' +
    '}).catch(function(){msg.textContent="Keine Verbindung zum Spiel"})}' +
    'q.addEventListener("input",function(){clearTimeout(t);t=setTimeout(suche,250)});' +
    'm.addEventListener("change",suche);' +
    'l.addEventListener("click",function(e){' +
    'var li=e.target.closest("li");if(!li)return;' +
    'fetch("/api/select?index="+li.dataset.i).then(function(){' +
    'msg.textContent="Ausgewählt - siehe Bildschirm"})});' +
    'suche();' +
    '</script></body></html>';
end;

end.
