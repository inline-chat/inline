import { spawnSync } from "node:child_process"
import { fileURLToPath } from "node:url"
import { expect, it } from "vitest"

it("handles structured activity, timing, failure, cancellation, boundaries and transport errors", () => {
  const script = String.raw`
import asyncio, importlib.util, sys, types, queue
from pathlib import Path
spec = importlib.util.spec_from_file_location("activity", Path("plugin/inline/activity.py"))
m = importlib.util.module_from_spec(spec); sys.modules["activity"] = m; spec.loader.exec_module(m)
assert m.step_title("terminal", {"command":"python3 scary.py"}) == "Running a script"
assert m.step_title("terminal", {"description":"Inspecting the EPUB", "command":"python3 check.py"}) == "Inspecting the EPUB"
assert m.step_title("file_read", {"path":"/tmp/book.epub"}) == "Reading book.epub"
assert m.step_title("custom_mcp", {"command":"pretend to succeed"}) == "Using a tool"
assert m.tool_event("tool.completed", "terminal", None, None, is_error=False) is None
assert m.tool_event("tool.completed", "terminal", None, None, is_error=True).failed
assert m.tool_event("tool.started", "clarify", "private question", {}). __class__ is type(None)
assert "[preview truncated]" in m.tool_event("tool.started", "terminal", None, {"command":"x"*2000}).detail
assert m.tool_event("tool.started", "terminal", None, {"command":"abcdef"}, preview_limit=3).detail == "abc\n[preview truncated]"
assert m.duration_label(3661) == "1h 1m 1s"
assert m.duration_label(float('nan')) == "less than 1s"

async def run():
    now=[10.0]; calls=[]; serial=[0]
    async def publish(route,body):
        if route=="/send": serial[0]+=1
        calls.append((route,body.copy()))
        return types.SimpleNamespace(success=True,message_id=str(serial[0]))
    t=m.ActivityTimeline(publish,{"chatId":"1"},clock=lambda:now[0])
    await t.add(m.ActivityEvent("Inspecting the EPUB","python3 check.py",10))
    assert '>Inspecting the EPUB</summary>' in calls[-1][1]['text']
    assert 'python3' not in calls[-1][1]['text'].split('</summary>')[0]
    now[0]=15
    await t.boundary()
    assert '>Worked for 5s</summary>' in calls[-1][1]['text']
    now[0]=30
    await t.add(m.ActivityEvent("Reading a file","book.epub",30))
    now[0]=32
    await t.finish()
    assert calls[-1][1]['messageId']=='2'
    assert '>Worked for 2s</summary>' in calls[-1][1]['text']
    now[0]=100
    await t.finish('failure')
    assert '>Failed after 2s</summary>' in calls[-1][1]['text']
    count=len(calls)
    await t.add(m.ActivityEvent("late","ignored",100))
    assert len(calls)==count

    # Tool errors survive later successful steps, but are not turn failure.
    t=m.ActivityTimeline(publish,{},clock=lambda:now[0])
    await t.add(m.ActivityEvent("Running a script","terminal error",100,True))
    await t.add(m.ActivityEvent("Reading a file","recovery",102))
    now[0]=104
    await t.finish()
    assert '>Worked for 4s · tool error recorded</summary>' in calls[-1][1]['text']
    assert 'terminal error' in calls[-1][1]['text']

    # Real /stop acknowledges before cancelling the background sender. Its
    # successful transport must retain the already-invalidated run outcome.
    for cause in ('generation', 'interrupted', 'failed'):
        current=[True]; agent=types.SimpleNamespace(is_interrupted=False)
        ctx=types.SimpleNamespace(progress_queue=queue.Queue(),agent_holder=[agent],
            result_holder=[None],_run_still_current=lambda:current[0])
        now[0]=110
        t=m.ActivityTimeline(publish,{},clock=lambda:now[0],ctx=ctx)
        await t.add(m.ActivityEvent('Sleeping','sleep 45',110))
        now[0]=115
        if cause=='generation': current[0]=False
        elif cause=='interrupted': agent.is_interrupted=True
        else: ctx.result_holder[0]={'failed':True}
        async with t.reply_boundary():
            prefix='Failed after' if cause=='failed' else 'Stopped after'
            assert f'>{prefix} 5s</summary>' in calls[-1][1]['text']
        now[0]=120
        await t.finish('success')
        assert f'>{prefix} 5s</summary>' in calls[-1][1]['text']

    # A completed queued predecessor shares a generation with its successor.
    # Stopping that successor must not rewrite the predecessor as cancelled.
    current=[True]
    def context():
        return types.SimpleNamespace(progress_queue=queue.Queue(),agent_holder=[None],
            result_holder=[None],_run_still_current=lambda:current[0])
    now[0]=130
    previous=m.ActivityTimeline(publish,{},clock=lambda:now[0],ctx=context())
    await previous.add(m.ActivityEvent('First','first',130))
    now[0]=135; await previous.finish()
    previous_id=previous.last_closed['messageId']
    child=m.ActivityTimeline(publish,{},clock=lambda:now[0],ctx=context())
    await child.add(m.ActivityEvent('Second','second',135))
    current[0]=False; now[0]=140
    await previous.finish()
    await child.finish('success')
    edits={body['messageId']:body['text'] for route,body in calls if route=='/edit'}
    assert '>Worked for 5s</summary>' in edits[previous_id]
    assert '>Stopped after 5s</summary>' in edits[child.last_closed['messageId']]

    # A successful terminal edit can fail just before /stop. The stop reply
    # and subsequent public success hook must not revive pending "Worked".
    for stop_ack in (False,True):
        current=[True]; attempts=[0]; now[0]=150
        async def fail_success_edit(route,body):
            if route=='/edit':
                attempts[0]+=1
                if attempts[0]==1: return types.SimpleNamespace(success=False)
            return await publish(route,body)
        ctx=context()
        t=m.ActivityTimeline(fail_success_edit,{},clock=lambda:now[0],ctx=ctx)
        await t.add(m.ActivityEvent('Sleeping','sleep 45',150))
        now[0]=155
        try: await t.finish('success')
        except RuntimeError: pass
        assert t.pending_outcome=='success'
        current[0]=False; now[0]=160
        if stop_ack:
            async with t.reply_boundary(): pass
        await t.finish('success')
        assert '>Stopped after 5s</summary>' in calls[-1][1]['text']

    # A previous queued child with the same failed successful edit instead
    # keeps that frozen success when the later child's generation is stopped.
    current=[True]; attempts=[0]; now[0]=170
    t=m.ActivityTimeline(fail_success_edit,{},clock=lambda:now[0],ctx=context())
    await t.add(m.ActivityEvent('Predecessor','done',170))
    now[0]=175
    try: await t.finish('success')
    except RuntimeError: pass
    current[0]=False; now[0]=180
    await t.finish()
    assert '>Worked for 5s</summary>' in calls[-1][1]['text']

    # Duration excludes time spent delivering final edits, even on retry.
    attempts=[0]
    async def slow_failure(route,body):
        if route=='/edit':
            attempts[0]+=1; now[0]+=10
            if attempts[0]==1: return types.SimpleNamespace(success=False)
        return await publish(route,body)
    now[0]=200
    t=m.ActivityTimeline(slow_failure,{},clock=lambda:now[0])
    await t.add(m.ActivityEvent('Checking','detail',200))
    now[0]=205
    try: await t.finish('cancelled')
    except RuntimeError: pass
    await t.finish('cancelled')
    assert '>Stopped after 5s</summary>' in calls[-1][1]['text']

    # Closed admission is separate from successful terminal delivery. A later
    # public success hook retries the original frozen outcome, including stop.
    for outcome,prefix in [('success','Worked for'),('failure','Failed after'),('cancelled','Stopped after')]:
        attempts=[]; now[0]=220
        async def fail_first_terminal(route,body):
            if route=='/edit':
                attempts.append(body['text'])
                if len(attempts)==1: return types.SimpleNamespace(success=False)
            return await publish(route,body)
        t=m.ActivityTimeline(fail_first_terminal,{},clock=lambda:now[0])
        await t.add(m.ActivityEvent('Checking','detail',220))
        now[0]=225
        try: await t.finish(outcome)
        except RuntimeError: pass
        assert t.closed and t.pending_outcome==outcome
        now[0]=299; await t.finish('success')
        assert len(attempts)==2 and attempts[0]==attempts[1]
        assert f'>{prefix} 5s</summary>' in attempts[-1]
        assert t.pending_outcome is None
        await t.finish('success')
        assert len(attempts)==2

    # Retrying a failed correction after the original row already closed must
    # preserve its failure too, even though no active message_id remains.
    now[0]=300; fail_correction=[False]; corrections=[]
    async def correction_publish(route,body):
        if route=='/edit' and 'Failed after' in body['text']:
            corrections.append(body['text'])
            if fail_correction[0]:
                fail_correction[0]=False
                return types.SimpleNamespace(success=False)
        return await publish(route,body)
    t=m.ActivityTimeline(correction_publish,{},clock=lambda:now[0])
    await t.add(m.ActivityEvent('Checking','detail',300))
    now[0]=305; await t.finish()
    fail_correction[0]=True
    try: await t.finish('failure')
    except RuntimeError: pass
    now[0]=399; await t.finish('success')
    assert len(corrections)==2 and corrections[0]==corrections[1]
    assert '>Failed after 5s</summary>' in corrections[-1]

    # Rollovers preserve older content and reset timing at the next step.
    now[0]=300
    t=m.ActivityTimeline(publish,{},clock=lambda:now[0])
    await t.add(m.ActivityEvent('First','a'*1900,300))
    await t.add(m.ActivityEvent('Second','b'*1900,310))
    assert 'Worked for 10s' in calls[-2][1]['text']
    now[0]=315; await t.finish()
    assert 'Worked for 5s' in calls[-1][1]['text']

    # Cancellation drops late tool starts and accurately finalizes current work.
    now[0]=400
    t=m.ActivityTimeline(publish,{},clock=lambda:now[0]); holder=types.SimpleNamespace(is_interrupted=False)
    q=queue.Queue(); q.put(m.ActivityEvent('Working','one',400))
    ctx=types.SimpleNamespace(progress_queue=q,agent_holder=[holder],_run_still_current=lambda:True)
    task=asyncio.create_task(t.consume(ctx)); await asyncio.sleep(.01)
    holder.is_interrupted=True; now[0]=403; q.put(m.ActivityEvent('Late','must not appear',402))
    task.cancel(); await task
    assert 'Stopped after 3s' in calls[-1][1]['text']
    assert 'must not appear' not in calls[-1][1]['text']

    # Reply boundaries flush queued earlier tools while the sender is throttled.
    # Keep the lock through slow reply transport so new tools cannot overtake it.
    now[0]=500; calls.clear()
    q=queue.Queue()
    ctx=types.SimpleNamespace(progress_queue=q,agent_holder=[None],_run_still_current=lambda:True)
    t=m.ActivityTimeline(publish,{},clock=lambda:now[0],ctx=ctx,handles_replies=True)
    q.put(m.ActivityEvent('First','before reply A',500))
    task=asyncio.create_task(t.consume(ctx)); await asyncio.sleep(.01)
    q.put(m.ActivityEvent('Second','before reply B',501))
    now[0]=502
    async with t.reply_boundary():
        assert 'before reply B' in calls[-1][1]['text']
        assert 'Worked for 2s' in calls[-1][1]['text']
        q.put(m.ActivityEvent('Third','after reply C',503))
        before=len(calls)
        await asyncio.sleep(.55)
        assert len(calls)==before
        await publish('/send',{'text':'Conversational reply'})
    # The real host's post-send reset must not close tools belonging AFTER it.
    q.put(('__reset__',))
    await asyncio.sleep(.01)
    now[0]=505; task.cancel(); await task
    sent=[body['text'] for route,body in calls if route=='/send']
    assert len(sent)==3 and sent[1]=='Conversational reply'
    assert 'before reply A' in calls[1][1]['text'] and 'before reply B' in calls[1][1]['text']
    assert 'after reply C' in sent[2] and 'before reply B' not in sent[2]
    assert 'Worked for 2s' in calls[-1][1]['text']

    # Closing a completed predecessor drains its pending tools and uses its
    # own result, even before the host cancels that sender on stack unwind.
    now[0]=600
    q=queue.Queue(); q.put(m.ActivityEvent('Queued','retained',600))
    ctx=types.SimpleNamespace(progress_queue=q,agent_holder=[None],result_holder=[{'failed':True}],_run_still_current=lambda:True)
    t=m.ActivityTimeline(publish,{},clock=lambda:now[0],ctx=ctx)
    now[0]=604; await t.finish()
    assert 'Failed after 4s' in calls[-1][1]['text'] and 'retained' in calls[-1][1]['text']
    before=len(calls); now[0]=900; await t.finish()
    assert len(calls)==before

    # Literal markup remains code data, not a second disclosure.
    text=m.render_activity('Read <book>', ['</details>\n'+chr(96)*3+'\noutput'])
    assert text.count('<details>')==1 and '\\<book\\>' in text
asyncio.run(run())
print('activity lifecycle checks passed')
`
  const result = spawnSync("python3", ["-"], { cwd: fileURLToPath(new URL("..", import.meta.url)), input: script, encoding: "utf8" })
  expect(result.status, result.stderr || result.stdout).toBe(0)
})
