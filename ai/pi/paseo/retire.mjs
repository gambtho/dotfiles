#!/usr/bin/env node
// Called only after shell-side unit/runtime/trial ownership and health preflight.
import fs from 'node:fs';
import path from 'node:path';
import {createRequire} from 'node:module';
import {pathToFileURL} from 'node:url';
import {randomUUID} from 'node:crypto';
const [trial, state] = process.argv.slice(2);
function fail(message) { throw new Error(message); }
try {
  const root=fs.realpathSync(trial), rootStat=fs.lstatSync(trial);
  if(!rootStat.isDirectory() || rootStat.uid!==process.getuid()) fail('trial root must be an owned real directory');
  const permitted=new Set(['home','runtime','paseo','password.txt','README.md','backups']);
  for(const name of fs.readdirSync(root)) if(!permitted.has(name)) fail('unknown trial root contents; refusing deletion');
  const requireRuntime=createRequire(path.join(root,'runtime/package.json'));
  const control=await import(pathToFileURL(requireRuntime.resolve('@getpaseo/server/daemon-control')));
  const pidFile=path.join(root,'home/paseo.pid');
  if(fs.existsSync(pidFile)) {
    let value; try{value=JSON.parse(fs.readFileSync(pidFile,'utf8'))}catch{fail('unknown trial process state')}
    if(!Number.isSafeInteger(value.pid)||value.pid<=0) fail('unknown trial process state');
  }
  if(await control.readDaemonInstance(path.join(root,'home'))) fail('trial still has an active supervisor');
  const mounts=fs.readFileSync('/proc/self/mountinfo','utf8').split('\n').filter(Boolean).map(line=>line.split(' ')[4]);
  if(mounts.some(m=>m===root||m.startsWith(root+'/'))) fail('mounted trial contents require separate handling');
  function walk(directory) {
    for(const entry of fs.readdirSync(directory,{withFileTypes:true})) {
      const file=path.join(directory,entry.name), stat=fs.lstatSync(file);
      if(stat.uid!==process.getuid()) fail('foreign trial contents; refusing deletion');
      if(entry.name==='.git') fail('Git repository/worktree found; source must be handled separately');
      if(stat.isSymbolicLink()) continue; // Unlink references; never walk their targets.
      if(stat.dev!==rootStat.dev) fail('mounted trial contents require separate handling');
      if(stat.isDirectory()) walk(file);
      else if(!stat.isFile()) fail('unknown trial file type; refusing deletion');
    }
  }
  walk(root);
  const evidence=[];
  for(const name of fs.readdirSync(state).filter(n=>n.startsWith('.rollback-trial.'))) {
    const dir=path.join(state,name), st=fs.lstatSync(dir);
    if(!st.isDirectory()||st.uid!==process.getuid()) fail('foreign rollback evidence');
    if(fs.readdirSync(dir).sort().join(',')!=='identity.json,unit') fail('unknown rollback evidence');
    const marker=JSON.parse(fs.readFileSync(path.join(dir,'identity.json'),'utf8'));
    if(marker.kind!=='dotfiles-paseo-trial-rollback'||marker.schemaVersion!==1) fail('foreign rollback evidence');
    for(const f of ['identity.json','unit']) if(!fs.lstatSync(path.join(dir,f)).isFile()) fail('foreign rollback evidence');
    evidence.push(dir);
  }
  // Move the positively identified tree before unlinking; do not recurse from a
  // name another process could replace with a symlink after preflight.
  const retired=path.join(path.dirname(root),`.paseo-trial-retired.${randomUUID()}`);
  fs.renameSync(root,retired);
  fs.rmSync(retired,{recursive:true});
  for(const dir of evidence) fs.rmSync(dir,{recursive:true});
  console.log('retired identified trial and obsolete password; original Pi/source state untouched');
} catch(error) {
  // Only our structural diagnostics are public, never a parser's file excerpts.
  const known=/^(trial|unknown|foreign|Git|mounted)/.test(error.message);
  console.error(`error: ${known?error.message:'trial retirement could not complete; preserving remaining evidence'}`);
  process.exitCode=1;
}
