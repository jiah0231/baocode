// SPDX-License-Identifier: AGPL-3.0-only
// Thin host only: rendering, toolbars and interactions remain upstream code.
const loaders={word:()=>import('./word.js'),excel:()=>import('./excel.js'),powerpoint:()=>import('./powerpoint.js'),pdf:()=>import('./pdf.js'),cad:()=>import('./cad.js'),epub:()=>import('./epub.js'),notability:()=>import('./notability.js'),goodnotes:()=>import('./goodnotes.js')};
const extensions={doc:'word',docx:'word',xls:'excel',xlsx:'excel',ppt:'powerpoint',pptx:'powerpoint',pdf:'pdf',dwg:'cad',dxf:'cad',epub:'epub',note:'notability',goodnotes:'goodnotes'};
const defaultExtension={word:'docx',excel:'xlsx',powerpoint:'pptx',cad:'dxf',notability:'note'};
const limits={word:100,excel:100,powerpoint:512,pdf:512,cad:50,epub:50,notability:50,goodnotes:50};
const container=document.getElementById('document-container');
const status=document.getElementById('status');
const toast=document.getElementById('toast');
let current=null,generation=0,toastTimer=0;
let sourceUrl='https://github.com/jiah0231/baocode';
function event(type,detail={}){
  const value={type,...detail};
  window.dispatchEvent(new CustomEvent('bao-office-event',{detail:value}));
  window.chrome?.webview?.postMessage(type==='error'?{type,message:String(detail.message??'文档无法打开')}:{type});
}
function notify(message){
  toast.textContent=String(message);toast.hidden=false;clearTimeout(toastTimer);
  toastTimer=setTimeout(()=>{toast.hidden=true;},3500);
}
function destroy(){
  ++generation;
  if(current){current.controller.abort();current.dispose?.();current.listeners.clear();current.host.remove();current=null;}
  container.replaceChildren();status.hidden=true;
}
function setTheme(theme={}){
  if(typeof theme.dark==='boolean'){document.documentElement.style.colorScheme=theme.dark?'dark':'light';document.documentElement.dataset.theme=theme.dark?'dark':'light';}
  if(typeof theme.sourceUrl==='string'){try{const source=new URL(theme.sourceUrl);if(source.protocol==='https:'&&source.hostname==='github.com'&&source.pathname.startsWith('/jiah0231/baocode/')&&!source.username&&!source.password&&!source.search&&!source.hash){sourceUrl=source.href;document.getElementById('source-url').textContent=sourceUrl;}}catch{}}
  const map={background:['--editor-bg','--editor-surface'],foreground:['--editor-text'],border:['--editor-border','--control-border'],accent:['--editor-accent'],muted:['--editor-text-muted'],surface:['--editor-surface'],toolbarHover:['--toolbar-hover'],toolbarActive:['--toolbar-active']};
  for(const [key,variables]of Object.entries(map))if(typeof theme[key]==='string'&&CSS.supports('color',theme[key]))for(const name of variables)document.documentElement.style.setProperty(name,theme[key]);
  // Fonts are intentionally not changed: upstream preserves authored fonts and
  // chooses its own declared fallback. The host theme only supplies chrome.
}
function resolveKind(kind,name){
  const supplied=String(kind??'').toLowerCase();
  const ext=String(name??'').split('.').pop().toLowerCase();
  const id=extensions[supplied]??(loaders[supplied]?supplied:extensions[ext]);
  if(!id)throw new Error('此文件格式没有对应的 NoteBoard 查看插件。');
  return {id,name:name?String(name).split(/[\\/]/).pop():`preview.${extensions[supplied]?supplied:defaultExtension[id]??id}`};
}
function safeDocumentUrl(value){
  const url=new URL(value??'/document',location.href);
  if(url.origin!==location.origin||url.pathname!=='/document'||url.username||url.password)throw new Error('只允许读取当前本地文档。');
  return url;
}
async function readBytes(url,limit,signal){
  const response=await fetch(url,{signal,cache:'no-store',credentials:'omit'});
  if(!response.ok)throw new Error('无法读取当前文档。');
  const declared=Number(response.headers.get('content-length'));
  if(Number.isFinite(declared)&&declared>limit)throw new Error('文档超过此格式的本地预览上限。');
  if(!response.body){const bytes=new Uint8Array(await response.arrayBuffer());if(bytes.length>limit)throw new Error('文档超过预览上限。');return bytes;}
  const reader=response.body.getReader(),chunks=[];let total=0;
  try{while(true){signal.throwIfAborted();const next=await reader.read();if(next.done)break;total+=next.value.length;if(total>limit){await reader.cancel();throw new Error('文档超过此格式的本地预览上限。');}chunks.push(next.value);}}
  finally{reader.releaseLock();}
  const bytes=new Uint8Array(total);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}return bytes;
}
async function load({kind,name,url='/document',bytes:input}={}){
  destroy();const token=generation;
  const controller=new AbortController(),host=document.createElement('div');host.className='plugin-host';
  const state={controller,host,dispose:null,listeners:new Set(),reading:false};current=state;
  container.append(host);status.textContent='正在打开本地文档…';status.hidden=false;
  try{
    const resolved=resolveKind(kind,name),limit=limits[resolved.id]*1024*1024;
    const plugin=await loaders[resolved.id]();controller.signal.throwIfAborted();
    const bytes=input instanceof Uint8Array?input:input instanceof ArrayBuffer?new Uint8Array(input):await readBytes(safeDocumentUrl(url),limit,controller.signal);
    if(bytes.byteLength>limit)throw new Error(`此格式支持 ${limits[resolved.id]} MB 以内的文件。`);
    controller.signal.throwIfAborted();
    const reading={get:()=>state.reading,set:value=>{state.reading=Boolean(value);state.listeners.forEach(listener=>listener(state.reading));},subscribe:listener=>{state.listeners.add(listener);return()=>state.listeners.delete(listener);}};
    const cleanup=await plugin.mount({container:host,name:resolved.name,bytes,signal:controller.signal,notify,reading});
    state.dispose=cleanup;
    if(token!==generation||controller.signal.aborted){cleanup?.();host.remove();return;}
    await document.fonts?.ready;
    if(token!==generation||controller.signal.aborted)return;
    status.hidden=true;event('loaded',{kind:resolved.id,generation:token});
  }catch(error){
    if(token!==generation||controller.signal.aborted)return;
    state.dispose?.();host.remove();
    const message=error?.message??String(error);status.textContent=`文档无法打开：${message}`;status.hidden=false;
    event('error',{message,kind,generation:token});
    throw error;
  }
}
function command(value){
  if(!value||typeof value!=='object')return;
  if(value.type==='load')void load(value).catch(()=>{});
  else if(value.type==='theme')setTheme(value.theme);
  else if(value.type==='destroy')destroy();
}
window.chrome?.webview?.addEventListener('message',message=>command(message.data));
window.addEventListener('keydown',key=>{
  if(key.key==='Escape'&&!key.defaultPrevented&&current?.reading){current.reading=false;current.listeners.forEach(listener=>listener(false));}
});
window.addEventListener('pagehide',destroy);
window.BaoOfficeViewer={load,setTheme,destroy,get root(){return current?.host.shadowRoot??null;},get supportedFormats(){return {...extensions};}};
const panel=document.getElementById('licenses');
document.getElementById('show-licenses').addEventListener('click',async()=>{
  panel.hidden=false;
  if(!panel.querySelector('pre').textContent){try{const response=await fetch('./THIRD_PARTY_NOTICES.txt',{credentials:'omit'});if(!response.ok)throw new Error('许可文件不可用');panel.querySelector('pre').textContent=await response.text();}catch(error){panel.querySelector('pre').textContent=error.message;}}
});
document.getElementById('close-licenses').addEventListener('click',()=>{panel.hidden=true;});
document.getElementById('copy-source').addEventListener('click',async()=>{
  try{await navigator.clipboard.writeText(sourceUrl);notify('已复制完整源代码地址');}catch{notify(`源代码地址：${sourceUrl}`);}
});
status.textContent='请选择文档。';event('ready',{formats:Object.keys(extensions)});
