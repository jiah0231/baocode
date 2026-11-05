import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import {createHash} from 'node:crypto';
const root=new URL('./vendor/noteboard/',import.meta.url);
const manifest=JSON.parse(await fs.readFile(new URL('source-files.json',root),'utf8'));
test('all vendored NoteBoard files equal the pinned upstream Git blobs',async()=>{
  for(const entry of manifest.files){const bytes=await fs.readFile(new URL(entry.path,root));assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'),entry.sha,entry.path);}
});
test('all distributed viewer assets match their build manifest',async()=>{
  const output=new URL('../../assets/office_preview/',import.meta.url);
  const built=JSON.parse(await fs.readFile(new URL('manifest.json',output),'utf8'));
  for(const item of built.artifacts){const bytes=await fs.readFile(new URL(item.name,output));assert.equal(bytes.length,item.size,item.name);assert.equal(createHash('sha256').update(bytes).digest('hex'),item.sha256,item.name);}
});
test('copyleft dependency source archives are present and intact',async()=>{
  const sources=new URL('./corresponding_source/',import.meta.url);
  const inventory=JSON.parse(await fs.readFile(new URL('manifest.json',sources),'utf8'));
  assert.equal(inventory.archives.length,4);
  for(const archive of inventory.archives){const bytes=await fs.readFile(new URL(archive.file,sources));assert.equal(bytes.length,archive.bytes,archive.file);assert.equal(createHash('sha256').update(bytes).digest('hex'),archive.sha256,archive.file);}
});
