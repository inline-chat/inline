import { describe, expect, test } from "bun:test"
import { execFile, execFileSync } from "node:child_process"
import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"
import { WatchdogLease } from "./watchdog.js"

const identity = { runId: "fixture-run", claimEpoch: 1, generation: 2 }
const fixtureDirectory = mkdtempSync(join(tmpdir(), "grid-supervisor-test-"))
const nodeExecutable = execFileSync(process.env.GRID_TRANSCRIPTION_TEST_NODE ?? "node", ["--print", "process.execPath"], { encoding: "utf8" }).trim()
const nodeVersion = execFileSync(nodeExecutable, ["--version"], { encoding: "utf8" }).trim()
// Keep fixtures as bounded diagnostic evidence; no workspace or environment files are read.
writeFileSync(join(fixtureDirectory, "package.json"), '{"type":"module"}')
execFileSync(nodeExecutable, [fileURLToPath(new URL("../node_modules/typescript/bin/tsc", import.meta.url)),
  "--ignoreConfig", "--target", "ES2022", "--module", "NodeNext", "--moduleResolution", "NodeNext", "--strict", "--noUncheckedIndexedAccess",
  "--skipLibCheck", "--types", "node", "--verbatimModuleSyntax", "--outDir", fixtureDirectory,
  fileURLToPath(new URL("./supervisor.ts", import.meta.url)), fileURLToPath(new URL("./watchdog.ts", import.meta.url)),
], { cwd: fileURLToPath(new URL("..", import.meta.url)), env: {}, encoding: "utf8" })
const roomChildPath = join(fixtureDirectory, "room-fixture.js")
writeFileSync(roomChildPath, `
import { appendFileSync } from 'node:fs';
let config;
const record = (event) => appendFileSync(config.events, JSON.stringify({event, at:Number(process.hrtime.bigint()/1000000n)})+'\\n');
process.on('SIGTERM', () => { record('term'); if(config.mode !== 'stubborn') process.exit(0); });
process.on('disconnect', () => process.exit(0));
process.on('message', (message) => {
  if(message.type === 'start') {
    config=message.payload;
    setInterval(() => process.send?.({type:'heartbeat',sentAtMs:Number(process.hrtime.bigint()/1000000n)}),100);
    record(process.env.GRID_SUPERVISOR_INHERITED_FIXTURE === undefined ? 'environment-clean' : 'environment-leaked');
    record(process.env.EXPECTED_CREDENTIAL === 'fixture-value' ? 'credential-present' : 'credential-missing');
    if(config.mode !== 'never-ready') process.send({type:'ready'});
  } else if(message.type === 'stop') {
    record('stop-'+message.reason);
    process.send({type:'stopped'});
    if(config.mode === 'graceful') setTimeout(() => process.exit(0), 80);
  } else if(message.type === 'renew') record('renew-'+message.payload?.marker);
});
`)
const moduleUrl = pathToFileURL(join(fixtureDirectory, "supervisor.js")).href
const watchdogUrl = pathToFileURL(join(fixtureDirectory, "watchdog.js")).href
const standardHarness = `
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {setTimeout as delay} from 'node:timers/promises';
import {NativeRoomSupervisor} from ${JSON.stringify(moduleUrl)};
import {monotonicMilliseconds as now} from ${JSON.stringify(watchdogUrl)};
process.env.GRID_SUPERVISOR_INHERITED_FIXTURE='must-not-leak';
const events=${JSON.stringify(join(fixtureDirectory, "events-"))}+process.pid+'.jsonl';
const identity={runId:'fixture-run',claimEpoch:1,generation:2};
const supervisor=new NativeRoomSupervisor({roomChildPath:${JSON.stringify(roomChildPath)},environment:{EXPECTED_CREDENTIAL:'fixture-value'},
 heartbeatIntervalMs:100,heartbeatTimeoutMs:2500,stoppingGraceMs:5000,authorityGraceMs:10,termGraceMs:100,killExitTimeoutMs:2000,startupTimeoutMs:10000});
const start=(mode,leaseMs=15000)=>supervisor.start({identity,requestedAtMs:now(),leaseMs,expiresAtMs:now()+30000,payload:{mode,events}});
const records=()=>readFileSync(events,'utf8').trim().split('\\n').map(line=>JSON.parse(line));
const absent=pid=>{try{process.kill(pid,0);return false;}catch(error){return error.code==='ESRCH';}};
`
const crashParentPath = join(fixtureDirectory, "crash-parent.js")
writeFileSync(crashParentPath, standardHarness + "const ready=await start('stubborn');process.send({type:'ready',pid:ready.pid});")
const brokenWatchdogPath = join(fixtureDirectory, "broken-watchdog.js")
writeFileSync(brokenWatchdogPath, "process.disconnect();setTimeout(()=>process.exit(0),50);")
function runNode(script: string): Promise<unknown> {
  return new Promise((resolve, reject) => {
    execFile(nodeExecutable, ["--input-type=module", "--eval", standardHarness + script], {
      timeout: 25_000, maxBuffer: 16 * 1024, env: {},
    }, (error, stdout, stderr) => {
      if (error) { reject(new Error(`Compiled ${nodeVersion} fixture failed: ${stderr.slice(0, 4_000)}`)); return }
      try { resolve(JSON.parse(stdout)) } catch { reject(new Error("Fixture result protocol")) }
    })
  })
}

describe("native room supervisor on compiled Node", () => {
  test("a stopped native child is killed while parent and API lease stay healthy", async () => {
    const result = await runNode(`
const ready=await start('stubborn');
const renew=setInterval(()=>{try{supervisor.renew(identity,now(),15000);}catch{}},250);
process.kill(ready.pid,'SIGSTOP');
const receipt=await supervisor.exitReceipt;
clearInterval(renew);
assert.equal(receipt.reason,'child_stalled');
assert.equal(receipt.signal,'SIGKILL');
assert.equal(absent(ready.pid),true);
console.log(JSON.stringify({reason:receipt.reason,parentHealthy:true}));
`)
    expect(result).toEqual({ reason: "child_stalled", parentHealthy: true })
  }, 30_000)
  test("stop closes admissions synchronously; stopped IPC cannot unlock replacement before SIGKILL exit", async () => {
    const result = await runNode(`
const ready=await start('stubborn');
const exit=supervisor.stop('authority');
assert.equal(supervisor.admitting,false);
assert.throws(()=>start('stubborn'),/stopped/);
await delay(30);
assert.equal(supervisor.hasActiveChild,true);
const receipt=await exit;
assert.equal(receipt.pid,ready.pid);
assert.equal(receipt.signal,'SIGKILL');
assert.equal(receipt.hardKilled,true);
assert.equal(absent(ready.pid),true);
assert.equal(supervisor.hasActiveChild,false);
const second=await start('graceful');
const secondExit=await supervisor.stop('stopping');
assert.equal(secondExit.pid,second.pid);
assert.equal(secondExit.code,0);
const list=records();
assert(list.some(entry=>entry.event==='stop-authority'));
assert(list.some(entry=>entry.event==='term'));
assert(!list.some(entry=>entry.event==='environment-leaked'));
assert(list.some(entry=>entry.event==='credential-present'));
console.log(JSON.stringify({signal:receipt.signal,secondCode:secondExit.code,environmentClean:true}));
`)
    expect(result).toEqual({ signal: "SIGKILL", secondCode: 0, environmentClean: true })
  }, 30_000)
  test("watchdog kills its owned native child while the parent event loop is stalled", async () => {
    const result = await runNode(`
const ready=await start('stubborn');
const exit=supervisor.exitReceipt;
assert(exit);
const blockedAt=now();
while(now()-blockedAt<5000) {}
assert.equal(absent(ready.pid),true);
const receipt=await exit;
assert.equal(receipt.reason,'parent_stalled');
assert.equal(receipt.signal,'SIGKILL');
assert(receipt.exitedAtMs<blockedAt+4500);
console.log(JSON.stringify({reason:receipt.reason,killedDuringStall:true}));
`)
    expect(result).toEqual({ reason: "parent_stalled", killedDuringStall: true })
  }, 30_000)
  test("request-start lease expires despite healthy parent heartbeats", async () => {
    const result = await runNode(`
const ready=await start('stubborn');
await delay(5);
supervisor.renew(identity,now(),750);
const receipt=await supervisor.exitReceipt;
assert(receipt);
assert.equal(receipt.reason,'expired');
assert.equal(receipt.signal,'SIGKILL');
assert.equal(absent(ready.pid),true);
console.log(JSON.stringify({reason:receipt.reason}));
`)
    expect(result).toEqual({ reason: "expired" })
  }, 30_000)
  test("parent stall also ends the graceful stopping window", async () => {
    const result = await runNode(`
const ready=await start('stubborn');
const exit=supervisor.stop('stopping');
await delay(40);
const blockedAt=now();
while(now()-blockedAt<5000) {}
assert.equal(absent(ready.pid),true);
const receipt=await exit;
assert.equal(receipt.reason,'parent_stalled');
assert.equal(receipt.signal,'SIGKILL');
console.log(JSON.stringify({reason:receipt.reason}));
`)
    expect(result).toEqual({ reason: "parent_stalled" })
  }, 30_000)
  test("parent SIGKILL disconnect lets the independent watchdog reap the native child", async () => {
    const result = await runNode(`
import {fork} from 'node:child_process';
const parent=fork(${JSON.stringify(crashParentPath)},[],{execPath:process.execPath,execArgv:[],env:{},stdio:['ignore','ignore','ignore','ipc']});
const nativePid=await new Promise((resolve,reject)=>{parent.once('message',message=>resolve(message.pid));parent.once('error',reject);});
const parentExit=new Promise(resolve=>parent.once('exit',resolve));
parent.kill('SIGKILL');
await parentExit;
await delay(1000);
assert.equal(absent(nativePid),true);
console.log(JSON.stringify({parentCrashReapedChild:true}));
`)
    expect(result).toEqual({ parentCrashReapedChild: true })
  }, 30_000)
  test("a queued start after a terminal pre-start stop cannot create an unsupervised child", async () => {
    const result = await runNode(`
import {fork} from 'node:child_process';
import {existsSync} from 'node:fs';
const watchdog=fork(${JSON.stringify(join(fixtureDirectory, "watchdog.js"))},[],{execPath:process.execPath,execArgv:[],env:{},stdio:['ignore','ignore','ignore','ipc']});
const watchdogExit=new Promise(resolve=>watchdog.once('exit',resolve));
let rejectedBeforeStart=false;
watchdog.on('message',message=>{if(message.type==='error'&&message.code==='protocol')rejectedBeforeStart=true;});
watchdog.send({type:'stop',reason:'authority'},()=>{});
watchdog.send({type:'start',childPath:${JSON.stringify(roomChildPath)},environment:{EXPECTED_CREDENTIAL:'fixture-value'},identity,
 requestedAtMs:now(),leaseMs:3000,expiresAtMs:now()+10000,payload:{mode:'stubborn',events},
 timings:{heartbeatTimeoutMs:1000,stoppingGraceMs:1500,authorityGraceMs:10,termGraceMs:100,killExitTimeoutMs:1000,startupTimeoutMs:2000}},()=>{});
await watchdogExit;
assert.equal(rejectedBeforeStart,true);
assert.equal(existsSync(events),false);
console.log(JSON.stringify({terminalStartRejected:true}));
`)
    expect(result).toEqual({ terminalStartRejected: true })
  }, 30_000)
  test("lost watchdog IPC rejects an unconfirmed exit and leaves replacement fenced", async () => {
    const result = await runNode(`
const broken=new NativeRoomSupervisor({roomChildPath:${JSON.stringify(roomChildPath)},watchdogPath:${JSON.stringify(brokenWatchdogPath)},environment:{}});
const pending=broken.start({identity,requestedAtMs:now(),leaseMs:15000,expiresAtMs:now()+30000,payload:{}});
const exit=broken.exitReceipt;
await assert.rejects(pending,/watchdog|exit_unconfirmed/);
await assert.rejects(exit,/exit_unconfirmed/);
assert.equal(broken.admitting,false);
assert.equal(broken.hasActiveChild,true);
assert.throws(()=>broken.start({identity,requestedAtMs:now(),leaseMs:15000,expiresAtMs:now()+30000,payload:{}}),/stopped/);
console.log(JSON.stringify({unconfirmedFenced:true}));
`)
    expect(result).toEqual({ unconfirmedFenced: true })
  }, 30_000)
  test("ordinary stop allows admitted work to flush, then authority loss shortens that grace", async () => {
    const result = await runNode(`
const ready=await start('stubborn');
const stoppingAt=now();
const exit=supervisor.stop('stopping');
await delay(80);
assert.equal(absent(ready.pid),false);
supervisor.stop('authority');
const receipt=await exit;
assert.equal(receipt.reason,'authority');
assert(receipt.exitedAtMs-stoppingAt<1000);
assert(records().some(entry=>entry.event==='stop-stopping'));
assert(records().some(entry=>entry.event==='stop-authority'));
console.log(JSON.stringify({reason:receipt.reason}));
`)
    expect(result).toEqual({ reason: "authority" })
  }, 30_000)
  test("ready-less child startup is terminated, and replacement waits for its exit", async () => {
    const result = await runNode(`
const ready=start('never-ready');
const exit=supervisor.exitReceipt;
await assert.rejects(ready,/stopped/);
const receipt=await exit;
assert(receipt);
assert.equal(receipt.reason,'startup');
assert.equal(absent(receipt.pid),true);
console.log(JSON.stringify({reason:receipt.reason}));
`)
    expect(result).toEqual({ reason: "startup" })
  }, 30_000)
  test("renewal forwards participant replacement only while the original authority is current", async () => {
    const result = await runNode(`
await start('graceful');
await delay(5);
supervisor.renew(identity,now(),3000,{marker:'participants-replaced'});
await delay(30);
await supervisor.stop('stopping');
assert(records().some(entry=>entry.event==='renew-participants-replaced'));
console.log(JSON.stringify({renewed:true}));
`)
    expect(result).toEqual({ renewed: true })
  }, 30_000)
})

describe("watchdog lease monotonic fencing", () => {
  test("expiry is irreversible, delayed request start never grants a fresh duration", () => {
    let clock = 1_000
    const lease = new WatchdogLease(identity, clock, 1_000, 10_000, () => clock)
    clock = 1_900
    lease.renew(identity, 1_100, 1_000)
    expect(lease.deadline).toBe(2_100)
    clock = 2_100
    expect(() => lease.renew(identity, clock, 1_000)).toThrow("expired")
    clock = 2_200
    expect(() => lease.renew(identity, clock, 1_000)).toThrow("stopped")
  })
  test("out of order and stale identity renewals cannot extend the accepted authority", () => {
    let clock = 1_000
    const lease = new WatchdogLease(identity, clock, 1_000, 4_000, () => clock)
    clock = 1_100
    expect(lease.renew(identity, clock, 2_000)).toBe(true)
    expect(lease.renew(identity, 1_050, 30_000)).toBe(false)
    expect(lease.deadline).toBe(3_100)
    expect(() => lease.renew({ ...identity, claimEpoch: 2 }, clock, 2_000)).toThrow("protocol")
    clock = 2_000
    lease.renew(identity, clock, 30_000)
    expect(lease.deadline).toBe(4_000)
  })
})
