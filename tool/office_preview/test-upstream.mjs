// SPDX-License-Identifier: AGPL-3.0-only
import * as fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const here=path.dirname(fileURLToPath(import.meta.url));
const link=path.join(here,'vendor/noteboard/plugins/node_modules');
// Two unchanged upstream tests intentionally resolve their binary dependencies
// relative to the original plugins directory rather than Node's package path.
try{await fs.symlink(path.join(here,'node_modules'),link,process.platform==='win32'?'junction':'dir');}catch(error){if(error.code!=='EEXIST')throw error;}
const tests=(await fs.readdir(path.join(here,'vendor/noteboard/plugins/test'))).filter(name=>name.endsWith('.test.mjs')).sort().map(name=>path.join(here,'vendor/noteboard/plugins/test',name));
const child=spawnSync(process.execPath,['--test',...tests],{stdio:'inherit',cwd:here});
process.exitCode=child.status??1;
