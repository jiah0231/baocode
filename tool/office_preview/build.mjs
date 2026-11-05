// SPDX-License-Identifier: AGPL-3.0-only
// Packages the unchanged NoteBoard preview modules for BaoCode's local host.
import {build} from 'esbuild';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {cspCompatibleRuntime} from './vendor/noteboard/plugins/cad/cspRuntime.mjs';

const here=path.dirname(fileURLToPath(import.meta.url));
const output=path.resolve(here,'../../assets/office_preview');
const upstream=path.join(here,'vendor/noteboard');
const ids=['word','excel','powerpoint','pdf','cad','epub','notability','goodnotes'];
const pkg=JSON.parse(await fs.readFile(path.join(here,'package.json'),'utf8'));
const source=JSON.parse(await fs.readFile(path.join(upstream,'source-files.json'),'utf8'));
const corresponding=JSON.parse(await fs.readFile(path.join(here,'corresponding_source/manifest.json'),'utf8'));
for(const archive of corresponding.archives){
  const bytes=await fs.readFile(path.join(here,'corresponding_source',archive.file));
  if(bytes.length!==archive.bytes||createHash('sha256').update(bytes).digest('hex')!==archive.sha256)throw new Error(`Missing or changed corresponding source: ${archive.file}`);
}

await fs.mkdir(output,{recursive:true});
for(const item of source.files){
  const content=await fs.readFile(path.join(upstream,item.path));
  const hash=createHash('sha1').update(`blob ${content.length}\0`).update(content).digest('hex');
  if(hash!==item.sha)throw new Error(`Vendored source changed without a recorded patch: ${item.path}`);
}
const base={absWorkingDir:here,bundle:true,write:false,metafile:true,platform:'browser',target:'chrome109',minify:true,legalComments:'inline'};
const pdfAssets={cmaps:{},fonts:{}};
for(const [key,dir]of [['cmaps','cmaps'],['fonts','standard_fonts']]){
  const folder=path.join(here,'node_modules/pdfjs-dist',dir);
  for(const name of (await fs.readdir(folder)).sort())if(!/license/i.test(name))pdfAssets[key][name]=(await fs.readFile(path.join(folder,name))).toString('base64');
}
const dxf=await build({...base,entryPoints:[path.join(upstream,'plugins/cad/dxf-worker.mjs')],format:'esm'});
const scene=await build({...base,entryPoints:[path.join(upstream,'plugins/cad/scene-worker.mjs')],format:'iife'});
const cadDir=path.join(here,'node_modules/@flyfish-dev/cad-viewer/dist/wasm');
const cadAssets={
  worker:await fs.readFile(path.join(cadDir,'dwg-worker.js'),'utf8'),
  module:cspCompatibleRuntime(await fs.readFile(path.join(cadDir,'libredwg-web.js'),'utf8')),
  wasm:(await fs.readFile(path.join(cadDir,'libredwg-web.wasm'))).toString('base64'),
  dxfWorker:dxf.outputFiles[0].text,sceneWorker:scene.outputFiles[0].text,
};
const inlineAssets={name:'local-noteboard-resources',setup(builder){
  builder.onResolve({filter:/\?raw$/},({path:request})=>({path:path.join(here,'node_modules',request.slice(0,-4)),namespace:'raw'}));
  builder.onLoad({filter:/.*/,namespace:'raw'},async({path:resource})=>({contents:await fs.readFile(resource,'utf8'),loader:'text'}));
  builder.onResolve({filter:/^noteboard:(pdf|cad)-assets$/},({path:request})=>({path:request,namespace:'inline'}));
  builder.onLoad({filter:/.*/,namespace:'inline'},({path:request})=>({contents:`export default ${JSON.stringify(request.includes('pdf')?pdfAssets:cadAssets)}`,loader:'js'}));
}};
const inputFiles=new Set(Object.keys(dxf.metafile.inputs));
const artifacts=[];
async function save(name,bytes){await fs.writeFile(path.join(output,name),bytes);artifacts.push({name,size:Buffer.byteLength(bytes),sha256:createHash('sha256').update(bytes).digest('hex')});}
for(const id of ids){
  const result=await build({...base,entryPoints:[path.join(upstream,'plugins',id,'index.mjs')],format:'esm',plugins:[inlineAssets],banner:{js:`/* NoteBoard ${id} preview, AGPL-3.0-only; upstream ${source.commit}. See THIRD_PARTY_NOTICES.txt and bundled corresponding source. */`}});
  Object.keys(result.metafile.inputs).forEach(file=>inputFiles.add(file));
  await save(`${id}.js`,result.outputFiles[0].contents);
  process.stdout.write(`${id}: ${Math.round(result.outputFiles[0].contents.length/1024)} KiB\n`);
}
const host=await build({...base,entryPoints:['viewer.mjs'],format:'iife',external:ids.map(id=>`./${id}.js`)});
await save('viewer.js',host.outputFiles[0].contents);
for(const filename of ['index.html','viewer.css'])await save(filename,await fs.readFile(path.join(here,filename)));

// Collect every package actually bundled, including transitive dependencies.
const packages=new Map();
for(const input of inputFiles){
  if(!input.includes('node_modules/')||/^(?:raw|inline):/.test(input))continue;
  let dir=path.dirname(path.resolve(here,input));
  while(dir!==path.dirname(dir)){
    const data=await fs.readFile(path.join(dir,'package.json'),'utf8').then(JSON.parse).catch(()=>null);
    if(data?.name){packages.set(`${data.name}@${data.version}`,{dir,data});break;}
    dir=path.dirname(dir);
  }
}
// Prebundled CAD packages already contain dependency code; include their
// declared runtime closure as well as esbuild's visible modules.
async function runtimeLicenses(name){
  const dir=path.join(here,'node_modules',name);
  const data=JSON.parse(await fs.readFile(path.join(dir,'package.json'),'utf8'));
  const key=`${data.name}@${data.version}`;
  if(packages.has(key))return;
  packages.set(key,{dir,data});
  for(const dependency of Object.keys(data.dependencies??{}))await runtimeLicenses(dependency);
}
for(const name of Object.keys(pkg.dependencies)){
  const data=JSON.parse(await fs.readFile(path.join(here,'node_modules',name,'package.json'),'utf8'));
  for(const dependency of Object.keys(data.dependencies??{}))await runtimeLicenses(dependency);
}
let notices=`BaoCode embedded NoteBoard preview\n\nOriginal repository: ${source.repository}\nOriginal commit: ${source.commit}\nCorresponding source, adaptations and build scripts are included under tool/office_preview in the matching BaoCode application source. The application About page gives the exact build revision. Project: https://github.com/jiah0231/baocode\n\nThe upstream NoteBoard sources remain AGPL-3.0-only. BaoCode's host adapters in this directory are AGPL-3.0-only. The surrounding BaoCode application remains under its stated GPL-3.0-only license; the GPLv3/AGPLv3 combination provisions and AGPL section 13 apply where applicable. Third-party components retain the following original licenses. No license is replaced by this notice.\n\n`;
notices+=await fs.readFile(path.join(upstream,'LICENSE'),'utf8');
for(const [name,{dir,data}]of [...packages].sort(([a],[b])=>a.localeCompare(b))){
  const licenseFiles=(await fs.readdir(dir)).filter(name=>/^(license|copying|notice)([._-]|$)/i.test(name)).sort();
  if(!licenseFiles.length&&data.name!=='@mlightcad/libredwg-web'&&data.name!=='isarray')throw new Error(`Missing distributed license: ${name}`);
  notices+=`\n\n===== ${name} (${data.license??'see below'}) =====\n`;
  if(data.name==='@mlightcad/libredwg-web')notices+=await fs.readFile(path.join(upstream,'licenses/GPL-3.0.txt'),'utf8');
  if(data.name==='isarray'){const readme=await fs.readFile(path.join(dir,'README.md'),'utf8');const at=readme.indexOf('## License');if(at<0)throw new Error('Missing isarray MIT text');notices+=readme.slice(at);}
  for(const file of licenseFiles){const stat=await fs.stat(path.join(dir,file));if(stat.isFile())notices+=await fs.readFile(path.join(dir,file),'utf8');}
}
notices+='\n\n===== LibreDWG / @mlightcad/libredwg-web 0.7.9: GPL-3.0-only =====\nSource: https://github.com/mlightcad/libredwg-web\n';
notices+=await fs.readFile(path.join(upstream,'licenses/GPL-3.0.txt'),'utf8');
for(const dir of ['cmaps','standard_fonts'])for(const name of(await fs.readdir(path.join(here,'node_modules/pdfjs-dist',dir))).filter(name=>/license/i.test(name)).sort()){
  notices+=`\n\n===== PDF.js ${dir}/${name} =====\n`+await fs.readFile(path.join(here,'node_modules/pdfjs-dist',dir,name),'utf8');
}
notices+='\n\n===== Lucide inline icons =====\n'+await fs.readFile(path.join(here,'licenses/LUCIDE.txt'),'utf8');
await save('THIRD_PARTY_NOTICES.txt',notices);
await fs.writeFile(path.join(output,'manifest.json'),JSON.stringify({schema:1,upstream:{repository:source.repository,commit:source.commit},dependencies:pkg.dependencies,artifacts:artifacts.sort((a,b)=>a.name.localeCompare(b.name))},null,2)+'\n');
