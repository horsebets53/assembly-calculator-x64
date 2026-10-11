'use strict';
const $ = id => document.getElementById(id);
const term = new Terminal({cursorBlink:true,fontSize:14,fontFamily:'"DejaVu Sans Mono", Consolas, monospace',scrollback:5000,disableStdin:true,theme:{background:'#101612',foreground:'#d9e9dc',cursor:'#a6d4b4',selectionBackground:'#395741'}});
const fit = new FitAddon.FitAddon();
term.loadAddon(fit);term.open($('terminal'));fit.fit();
let key='',session=null,cursor=0,generation=0,queue=Promise.resolve(),resizing;
try{$('key').value=sessionStorage.getItem('terminal-key')||''}catch{}
const message=text=>{$('message').textContent=text};
function controls(connected){$('interrupt').disabled=!connected;$('close').disabled=!connected;term.options.disableStdin=!connected;$('connect').disabled=connected;$('key').disabled=connected;}
async function api(path,body,timeout=20000){
 const response=await fetch(path,{method:body===undefined?'GET':'POST',headers:{'X-Terminal-Key':key,...(body===undefined?{}:{'Content-Type':'application/json'})},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(timeout)});
 let data;try{data=await response.json()}catch{throw Error(`Ответ прокси: HTTP ${response.status}`)}
 if(!response.ok)throw Error(data.error||`HTTP ${response.status}`);return data;
}
function b64(bytes){let s='';for(const b of bytes)s+=String.fromCharCode(b);return btoa(s);}
function input(data){
 const active=session,epoch=generation;
 if(!active)return;
 const bytes=new TextEncoder().encode(data);
 // Serialize input so a paste cannot overtake keystrokes. Do not auto-retry:
 // if an acknowledgement is lost, retrying could execute a command twice.
 queue=queue.then(async()=>{
  for(let offset=0;offset<bytes.length;offset+=4096){
   if(epoch!==generation||active!==session)return;
   await api('/api/input',{session:active,data:b64(bytes.subarray(offset,offset+4096))});
  }
 }).catch(e=>{message('Ошибка ввода: '+e.message+' Проверьте экран перед повтором.');});
}
term.onData(input);
async function resize(){
 fit.fit();if(!session)return;
 try{await api('/api/resize',{session,cols:Math.max(10,Math.min(500,term.cols)),rows:Math.max(2,Math.min(200,term.rows))})}catch(e){message(e.message)}
}
new ResizeObserver(()=>{clearTimeout(resizing);resizing=setTimeout(resize,150)}).observe($('terminal'));
async function poll(epoch,active){
 while(epoch===generation&&session===active){
  try{
   const output=await api(`/api/output?session=${encodeURIComponent(active)}&cursor=${cursor}`);
   if(epoch!==generation)return;
   if(output.dropped)term.writeln('\r\n[Старый вывод удалён из буфера сервера]\r\n');
   const bytes=Uint8Array.from(atob(output.data),c=>c.charCodeAt(0));
   if(bytes.length)await new Promise(resolve=>term.write(bytes,resolve));
   cursor=output.cursor;
   if(output.closed&&output.drained){session=null;controls(false);$('status').textContent='Сессия завершена';return;}
  }catch(e){
   if(epoch!==generation)return;
   message('Связь прервана: '+e.message+' Подключитесь снова; вывод будет восстановлен из буфера.');
   session=null;controls(false);$('status').textContent='Нет связи';return;
  }
 }
}
$('connect').onclick=async()=>{
 if(session)return;key=$('key').value.trim();$('connect').disabled=true;message('Подключаем…');
 try{
  const result=await api('/api/open',{});session=result.session;cursor=0;generation++;term.reset();
  try{sessionStorage.setItem('terminal-key',key)}catch{}
  controls(true);$('status').textContent='Bash · подключён';message('Начальный каталог: '+result.cwd);
  await resize();term.focus();poll(generation,session);
 }catch(e){message(e.message);controls(false);}
};
$('key').onkeydown=e=>{if(e.key==='Enter')$('connect').click()};
$('interrupt').onclick=()=>{input('\x03');term.focus()};
$('clear').onclick=()=>{term.clear();term.focus()};
$('close').onclick=async()=>{
 if(!session||!confirm('Завершить эту Bash-сессию? Работающие в ней задачи могут быть остановлены.'))return;
 const active=session;
 try{await api('/api/close',{session:active});generation++;session=null;controls(false);$('status').textContent='Сессия завершена';message('Сессия завершена. Для новой нажмите «Подключить».');}
 catch(e){message(e.message)}
};
term.writeln('Веб-терминал готов. Введите код доступа из чата.');
