import { describe, expect, test } from "bun:test"
import { execFile, execFileSync } from "node:child_process"
import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"
import { claimedRun, claimResponse, renewedRun, RunControlClient, WorkerControlClient } from "./api.js"
import { MAX_TURN_TEXT_BYTES, TranscriptionError } from "./protocol.js"

// Current claim wire shape comes from server/src/modules/grid/transcription/worker.ts:
// its claim response uses run.sourceRoomId and participant.userId as database numbers.
const claimFixture = {
  runId: "4fef7f47-4d65-4b71-8efb-1eab3185ab05", claimEpoch: 1, roomId: 42, generation: 3,
  runToken: "fixture-run-token", providerTarget: "inline-grid-room-42-generation-3",
  livekit: { serverUrl: "wss://media.example.test", token: "fixture-livekit-token" },
  model: "meeting", leaseMs: 15_000, expiresAt: "2030-01-01T02:00:00.000Z",
  participants: [{ identity: "inline-grid-user-7-member", userId: 7, membershipId: "member" }],
}
const renewalFixture = {
  state: "stopping", allowFinalFlush: true, leaseExpiresAt: "2030-01-01T00:00:15.000Z",
  participants: claimFixture.participants, spaceId: 9,
}
const segmentId = "78190417-5200-43ee-ae16-c891fd067d7e"

function expectFailure(action: () => unknown, code: TranscriptionError["code"] = "protocol") {
  try { action(); throw new Error("Expected safe failure") }
  catch (error) {
    expect(error).toBeInstanceOf(TranscriptionError)
    if (!(error instanceof TranscriptionError)) throw error
    expect(error.code).toBe(code)
    expect(error.message).toBe(`Grid transcription ${code}`)
  }
}

describe("API wire parsing", () => {
  test("lost claim recovery returns only stop authority and cannot supply microphone credentials", () => {
    const stopped = claimResponse({ runId: claimFixture.runId, claimEpoch: 2, runToken: "fixture-recovery-token", stopImmediately: true })
    expect(stopped).toEqual({ runId: claimFixture.runId, claimEpoch: 2, runToken: "fixture-recovery-token", stopImmediately: true })
    expect("livekit" in stopped).toBe(false)
    expectFailure(() => claimResponse({ runId: claimFixture.runId, claimEpoch: 0, runToken: "fixture-recovery-token", stopImmediately: true }))
  })
  test("accepts the server's numeric room and participant IDs as exact positive decimal IDs", () => {
    const claim = claimedRun(claimFixture)
    expect(claim.roomId).toBe("42")
    expect(claim.participants[0]?.userId).toBe("7")
    expect(claim.livekit).toEqual(claimFixture.livekit)
    expect(Object.isFrozen(claim)).toBe(true)
    expect(Object.isFrozen(claim.participants[0])).toBe(true)
    expect(claimedRun({ ...claimFixture, roomId: "42" }).roomId).toBe("42")
    for (const roomId of [0, -1, 1.5, Number.MAX_SAFE_INTEGER + 1, "0", "01", "-2", "1e3", ""]) {
      expectFailure(() => claimedRun({ ...claimFixture, roomId }))
    }
  })

  test("rejects invalid media URLs, ID bounds and leases using safe errors", () => {
    for (const serverUrl of ["private malformed URL", "https://media.example.test"]) {
      expectFailure(() => claimedRun({ ...claimFixture, livekit: { ...claimFixture.livekit, serverUrl } }))
    }
    for (const leaseMs of [0, 15_001, Infinity]) expectFailure(() => claimedRun({ ...claimFixture, leaseMs }))
    expectFailure(() => claimedRun({ ...claimFixture, participants: [
      ...claimFixture.participants, ...claimFixture.participants,
    ] }))
    expectFailure(() => claimedRun({ ...claimFixture, participants: [{ ...claimFixture.participants[0], identity: "a".repeat(129) }] }))
  })

  test("defaults an omitted final-flush grant to false and accepts only explicit boolean grants", () => {
    expect(renewedRun(renewalFixture).allowFinalFlush).toBe(true)
    expect(renewedRun({ ...renewalFixture, allowFinalFlush: undefined }).allowFinalFlush).toBe(false)
    expect(renewedRun({ ...renewalFixture, allowFinalFlush: false }).allowFinalFlush).toBe(false)
    for (const allowFinalFlush of [1, "true", null]) expectFailure(() => renewedRun({ ...renewalFixture, allowFinalFlush }))
    expectFailure(() => renewedRun({ ...renewalFixture, state: "interrupted" }))
  })

  test("URL constructors reject malformed URLs, credentials and unsupported path prefixes safely", () => {
    for (const baseUrl of ["private malformed URL", "http://example.test", "https://user:private@example.test",
      "https://example.test/prefix", "https://example.test/?secret=private", "https://example.test/#private"]) {
      expectFailure(() => new WorkerControlClient(baseUrl, "fixture-secret", "worker"))
      expectFailure(() => new RunControlClient(baseUrl, "fixture-token"))
    }
    expectFailure(() => new WorkerControlClient("https://example.test", "fixture-secret", "w".repeat(81)))
  })

  test("rejects over-limit admission IDs and UTF8 final text before making requests", async () => {
    const client = new RunControlClient("http://127.0.0.1:1", "fixture-token")
    for (const values of [["a".repeat(129), "track", "turn"], ["identity", "a".repeat(129), "turn"],
      ["identity", "track", "a".repeat(129)]]) {
      await expect(client.admit(values[0]!, values[1]!, values[2]!)).rejects.toThrow("Grid transcription protocol")
    }
    await expect(client.final(segmentId, "a".repeat(MAX_TURN_TEXT_BYTES + 1))).rejects.toThrow("Grid transcription overflow")
    await expect(client.final(segmentId, "界".repeat(Math.ceil(MAX_TURN_TEXT_BYTES / 3)))).rejects.toThrow("Grid transcription overflow")
    await expect(client.stopped("r".repeat(81))).rejects.toThrow("Grid transcription protocol")
  })
})

// The HTTP tests execute compiled production code on Node, rather than relying on Bun fetch behavior.
const fixtureDirectory = mkdtempSync(join(tmpdir(), "grid-api-test-"))
const nodeExecutable = execFileSync(process.env.GRID_TRANSCRIPTION_TEST_NODE ?? "node", ["--print", "process.execPath"], { encoding: "utf8" }).trim()
writeFileSync(join(fixtureDirectory, "package.json"), '{"type":"module"}')
execFileSync(nodeExecutable, [fileURLToPath(new URL("../node_modules/typescript/bin/tsc", import.meta.url)),
  "--ignoreConfig", "--target", "ES2022", "--module", "NodeNext", "--moduleResolution", "NodeNext", "--strict",
  "--noUncheckedIndexedAccess", "--skipLibCheck", "--types", "node", "--verbatimModuleSyntax", "--outDir", fixtureDirectory,
  fileURLToPath(new URL("./api.ts", import.meta.url)),
], { cwd: fileURLToPath(new URL("..", import.meta.url)), env: {}, encoding: "utf8" })
const harness = `
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {WorkerControlClient,RunControlClient} from ${JSON.stringify(pathToFileURL(join(fixtureDirectory, "api.js")).href)};
const claim=${JSON.stringify(claimFixture)},renewal=${JSON.stringify(renewalFixture)},segmentId=${JSON.stringify(segmentId)};
const safe=code=>error=>error.name==='TranscriptionError'&&error.code===code&&error.message==='Grid transcription '+code;
const listen=async handler=>{const server=createServer(handler);await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
return {server,url:'http://127.0.0.1:'+server.address().port,close:async()=>{server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}};};
const read=async request=>{const chunks=[];for await(const chunk of request)chunks.push(chunk);return JSON.parse(Buffer.concat(chunks).toString());};
const json=(response,value)=>{response.setHeader('Content-Type','application/json');response.end(JSON.stringify(value));};
`
function runNode(script: string): Promise<unknown> {
  return new Promise((resolve, reject) => {
    execFile(nodeExecutable, ["--input-type=module", "--eval", harness + script], { env: {}, timeout: 10_000, maxBuffer: 8000 },
      (error, stdout, stderr) => {
        if (error) { reject(new Error(`Native API fixture failed: ${stderr.slice(0, 4000)}`)); return }
        try { resolve(JSON.parse(stdout)) } catch { reject(new Error("Native API fixture result protocol")) }
      })
  })
}

describe("control API over native loopback HTTP", () => {
  test("uses exact internal root paths, separate bearer credentials and server-shaped replies", async () => {
    expect(await runNode(`
const requests=[];let claims=0;
const fixture=await listen(async(request,response)=>{const body=await read(request);requests.push({path:request.url,method:request.method,auth:request.headers.authorization,body});
switch(request.url){
case '/_internal/grid-transcription/heartbeat':json(response,{ready:body.ready});break;
case '/_internal/grid-transcription/claim':if(claims++===0){response.writeHead(204);response.end();}else json(response,claim);break;
case '/_internal/grid-transcription/renew':json(response,renewal);break;
case '/_internal/grid-transcription/admit':json(response,{segmentId});break;
case '/_internal/grid-transcription/final':json(response,{messageId:12});break;
case '/_internal/grid-transcription/stopped':json(response,{stopped:true});break;
default:response.writeHead(404);response.end();}});
try{const worker=new WorkerControlClient(fixture.url,'worker-fixture-secret','worker-1');
await worker.heartbeat('meeting',true);assert.equal(await worker.claim(),undefined);assert.equal((await worker.claim()).roomId,'42');
const run=new RunControlClient(fixture.url,'run-fixture-token');assert.equal((await run.renew()).allowFinalFlush,true);
assert.equal(await run.admit('identity','track','turn'),segmentId);await run.final(segmentId,'a'.repeat(32768));await run.stopped('user_stop');
assert.equal(requests.length,7);assert(requests.every(value=>value.method==='POST'));
assert(requests.slice(0,3).every(value=>value.auth==='Bearer worker-fixture-secret'));
assert(requests.slice(3).every(value=>value.auth==='Bearer run-fixture-token'));
assert.deepEqual(requests[0].body,{workerId:'worker-1',model:'meeting',ready:true});assert.deepEqual(requests[3].body,{});
assert.deepEqual(requests[4].body,{participantIdentity:'identity',trackSid:'track',sourceTurnKey:'turn'});
assert.equal(requests[5].body.text.length,32768);console.log(JSON.stringify({requests:requests.length}));
}finally{await fixture.close();}
`)).toEqual({ requests: 7 })
  }, 15_000)

  test("maps HTTP rejections to safe codes without returning private error bodies", async () => {
    expect(await runNode(`
const statuses=[401,403,404,409,410,500];let index=0;
const fixture=await listen((_request,response)=>{response.writeHead(statuses[index++]);response.end('PRIVATE error detail '.repeat(10000));});
try{const client=new WorkerControlClient(fixture.url,'fixture-secret','worker');
for(const code of ['stopped','stopped','stopped','stopped','expired','provider'])await assert.rejects(()=>client.claim(),safe(code));
console.log(JSON.stringify({rejections:index}));}finally{await fixture.close();}
`)).toEqual({ rejections: 6 })
  }, 15_000)

  test("caps streamed success responses and fails safely on malformed JSON", async () => {
    expect(await runNode(`
let requests=0;const fixture=await listen((_request,response)=>{requests++;if(requests===1){response.write('"');response.end('a'.repeat(65536)+'"');}else response.end('PRIVATE malformed JSON');});
try{const client=new WorkerControlClient(fixture.url,'fixture-secret','worker');
await assert.rejects(()=>client.claim(),safe('overflow'));await assert.rejects(()=>client.claim(),safe('provider'));
console.log(JSON.stringify({requests}));}finally{await fixture.close();}
`)).toEqual({ requests: 2 })
  }, 15_000)

  test("times out both stalled headers and a stalled response body", async () => {
    expect(await runNode(`
let requests=0;const fixture=await listen((_request,response)=>{requests++;if(requests===2){response.writeHead(200,{'Content-Type':'application/json'});response.write('{');}});
try{const client=new WorkerControlClient(fixture.url,'fixture-secret','worker',120);
await assert.rejects(()=>client.claim(),safe('provider'));await assert.rejects(()=>client.claim(),safe('provider'));
console.log(JSON.stringify({requests}));}finally{await fixture.close();}
`)).toEqual({ requests: 2 })
  }, 15_000)
})
