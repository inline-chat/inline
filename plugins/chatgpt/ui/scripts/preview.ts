import { sampleThread } from "./fixtures"

const root = new URL("../", import.meta.url)
const html = await Bun.file(new URL("dist/thread.html", root)).text()
const fixtures = JSON.stringify([sampleThread(), sampleThread("801", "Launch review")]).replace(/</g, "\\u003c")
const wrapper = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Inline thread local preview</title><style>
*{box-sizing:border-box}body{margin:0;font:13px/1.5 -apple-system,BlinkMacSystemFont,sans-serif;background:#f7f7f8;color:#333}header{max-width:1040px;margin:30px auto 18px;padding:0 16px}header p{margin:5px 0;color:#777}.layout{display:flex;gap:20px;max-width:1040px;margin:auto;padding:0 16px;align-items:flex-start}.notes{flex:1;min-width:240px;padding:20px;background:white;border:1px solid #e5e5e8;border-radius:14px}.notes p{color:#777}.frame{width:460px;max-width:100%;border:1px solid #e5e5e8;border-radius:14px;overflow:hidden;box-shadow:0 10px 35px #00000006;background:#fff}iframe{border:0;width:100%;height:640px;display:block}button{font:inherit;padding:6px 10px;border:1px solid #ddd;border-radius:7px;background:#fff;cursor:pointer;margin:4px 3px 4px 0}pre{white-space:pre-wrap;overflow-wrap:anywhere;font-size:11px;color:#777;max-height:220px;overflow:auto}label{display:block;margin-top:10px;font-size:12px}@media(max-width:700px){.layout{display:block}.notes{margin-bottom:16px}.frame{width:100%}header{margin-top:15px}}
</style></head><body><header><strong>Inline thread · local component preview</strong><p>Sample data, a simulated host, and the production React bundle. No Inline account is connected.</p></header><div class="layout"><aside class="notes"><strong>“Get my teammates’ opinion, then continue when they answer.”</strong><p>This preview exercises the real MCP Apps bridge and the focused Inline thread view.</p><button id="reply">Simulate teammate reply</button><button id="other">Open another thread</button><button id="theme">Toggle appearance</button><label><input id="fail" type="checkbox"> Simulate unconfirmed message delivery</label><p id="context-label">Select messages in the thread, then add them to ChatGPT.</p><pre id="context"></pre></aside><div class="frame"><iframe title="Inline thread" src="/thread" sandbox="allow-scripts allow-popups"></iframe></div></div><script>
const threads=${fixtures};let active=threads[0],theme="light",widgetState=null;const frame=document.querySelector("iframe");
const notify=(method,params)=>frame.contentWindow.postMessage({jsonrpc:"2.0",method,params},"*");
const respond=(id,result)=>frame.contentWindow.postMessage({jsonrpc:"2.0",id,result},"*");
window.addEventListener("message",(event)=>{if(event.source!==frame.contentWindow)return;const rpc=event.data;if(rpc?.previewWidgetState){widgetState=rpc.previewWidgetState;return}if(rpc?.jsonrpc!=="2.0")return;
if(rpc.method==="ui/initialize"){respond(rpc.id,{protocolVersion:"2026-01-26",hostCapabilities:{updateModelContext:{}},hostContext:{theme}});setTimeout(()=>notify("ui/notifications/tool-result",{structuredContent:active}),10)}
else if(rpc.method==="tools/call"){const args=rpc.params.arguments;const thread=threads.find(t=>t.chat.chatId===args.chatId);if(!thread){respond(rpc.id,{isError:true,content:[]});return}if(rpc.params.name==="messages.send"){if(document.querySelector("#fail").checked){respond(rpc.id,{isError:true,content:[]});return}const id=String(Number(thread.messages.at(-1)?.id||80000)+1);thread.messages.push({id,chatId:args.chatId,text:args.text,out:true,fromId:"1",date:String(Math.floor(Date.now()/1000)),replyToMsgId:args.replyToMsgId||null,editDate:null,media:null,links:[]});respond(rpc.id,{structuredContent:{ok:true,chatId:args.chatId,messageId:id}})}else{active=thread;respond(rpc.id,{structuredContent:thread})}}
else if(rpc.method==="ui/update-model-context"){document.querySelector("#context").textContent=rpc.params.content[0].text;respond(rpc.id,{})}
else if(rpc.method==="ui/notifications/size-changed"&&rpc.params.height>0){frame.style.height=rpc.params.height+"px"}});
document.querySelector("#reply").onclick=()=>{const id=String(Number(active.messages.at(-1).id)+1);active.messages.push({id,chatId:active.chat.chatId,text:"One more thought: test the waiting workflow with the view closed, too.",out:false,fromId:"2",senderDisplayName:"Sam",date:String(Math.floor(Date.now()/1000)),replyToMsgId:null,editDate:null,media:null,links:[]});notify("ui/notifications/tool-result",{structuredContent:active})};
document.querySelector("#other").onclick=()=>{active=threads.find(t=>t!==active);notify("ui/notifications/tool-result",{structuredContent:active})};
document.querySelector("#theme").onclick=()=>{theme=theme==="light"?"dark":"light";notify("ui/notifications/host-context-changed",{theme})};
</script></body></html>`

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: 59767,
  fetch(request) {
    const path = new URL(request.url).pathname
    if (path === "/thread") return new Response(html.replace('<script type="module">', '<script>window.openai={setWidgetState:(state)=>window.parent.postMessage({previewWidgetState:state},"*")};</script><script type="module">'), { headers: { "content-type": "text/html; charset=utf-8" } })
    if (path === "/") return new Response(wrapper, { headers: { "content-type": "text/html; charset=utf-8" } })
    return new Response("Not found", { status: 404 })
  },
})
console.log(`Inline thread preview: ${server.url}`)
