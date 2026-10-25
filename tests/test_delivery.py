import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.data = Path(self.tmp.name)
        self.log = self.data / 'mqtt'
        self.shell('init_event_store')

    def shell(self, command, events=None, fail=''):
        (self.data / 'input').write_text(json.dumps(events or []))
        script = r'''
source "$ROOT/vicohome_bridge/run.sh"
bashio::log.warning() { echo "$*" >&2; }
bashio::log.debug() { :; }
bashio::log.info() { :; }
ensure_discovery_published() { return 0; }
mosquitto_pub() {
 python3 -c 'import json,os,sys; open(os.environ["LOG"],"a").write(json.dumps(sys.argv[1:])+"\n")' "$@"
 [[ "$*" != *"$FAIL"* || -z "$FAIL" ]]
}
DATA_DIR="$DATA"; BASE_TOPIC=vicohome; MQTT_ARGS=(); POLL_INTERVAL=60
BRIDGE_NOW=2000000000
init_event_store || exit 1
''' + command
        env = dict(os.environ, ROOT=str(ROOT), DATA=str(self.data), LOG=str(self.log), FAIL=fail)
        return subprocess.run(['bash', '-c', script], env=env, text=True, capture_output=True)

    def batch(self, events, mode='live', fail=''):
        result=self.shell('process_events "$(cat "$DATA/input")" '+mode, events, fail)
        self.assertEqual(result.returncode,0,result.stderr)
        return self.messages()

    def messages(self):
        rows=[json.loads(x) for x in self.log.read_text().splitlines()] if self.log.exists() else []
        return [(r[r.index('-t')+1],r[r.index('-m')+1]) for r in rows]

    def event(self, n, camera='A', ts=None):
        return dict(traceId=str(n), serialNumber=camera, timestamp=ts or 2000000000+n, eventType='motion')

    def test_initial_latest_per_camera_and_restart(self):
        old=[self.event(i,c,1999999900+i) for c in ['A','B'] for i in range(10)]
        self.batch(old[::-1])
        states=[json.loads(p) for t,p in self.messages() if t.endswith('/state')]
        self.assertEqual([(x['serialNumber'],x['traceId']) for x in states],[('A','9'),('B','9')])
        self.assertFalse(any(t.endswith(('/events','/motion')) for t,p in self.messages()))
        before=len(self.messages());self.batch(old)
        self.assertEqual(len(self.messages()),before)

    def test_order_multiple_cameras_and_no_replay(self):
        events=[self.event(3),self.event(2,'B'),self.event(1)]
        self.batch(events)
        sent=[json.loads(p)['traceId'] for t,p in self.messages() if t.endswith('/events')]
        self.assertEqual(sent,['1','2','3'])
        before=len(self.messages());self.batch(events)
        self.assertEqual(len(self.messages()),before)

    def test_large_backlog_bounded_and_drains(self):
        events=[self.event(i) for i in range(1,151)]
        self.batch(events[::-1]);self.assertEqual(sum(t.endswith('/events') for t,p in self.messages()),60)
        self.batch(events);self.batch(events)
        self.assertEqual(sum(t.endswith('/events') for t,p in self.messages()),150)
        self.batch(events);self.assertEqual(sum(t.endswith('/events') for t,p in self.messages()),150)

    def test_failed_publication_retryable(self):
        self.batch([self.event(1)],fail='/state')
        ledger=json.loads((self.data/'delivery.json').read_text())
        self.assertEqual(ledger['seen'],{})
        self.batch([self.event(1)])
        self.assertEqual(len(json.loads((self.data/'delivery.json').read_text())['seen']),1)

    def test_failed_initial_state_retryable(self):
        old=[self.event(1,ts=1999999900)]
        self.batch(old,fail='/state');self.batch(old)
        self.assertEqual(sum(t.endswith('/state') for t,p in self.messages()),2)
        self.assertFalse(any(t.endswith('/motion') for t,p in self.messages()))

    def test_empty_malformed_and_missing_fields(self):
        self.batch([]);self.batch([{},None,'bad',{'serialNumber':'A'}])
        result=self.shell('process_events "broken" live; process_events "[]" live')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.messages(),[])
        event=self.event(1);del event['eventType'];self.batch([event])
        self.assertFalse(any(t.endswith('/motion') for t,p in self.messages()))

    def test_late_event_does_not_regress_state(self):
        self.batch([self.event(3)]);self.batch([self.event(1)])
        states=[json.loads(p)['traceId'] for t,p in self.messages() if t.endswith('/state')]
        self.assertEqual(states,['3'])

    def test_bootstrap_bounded_no_motion(self):
        self.batch([self.event(i,c,1999999900+i) for c in ['A','B'] for i in range(80)],'history')
        self.assertEqual(sum(t.endswith('/state') for t,p in self.messages()),2)
        self.assertFalse(any(t.endswith(('/events','/motion')) for t,p in self.messages()))

    def test_history_more_than_batch_limit_cameras(self):
        events=[self.event(1,'camera'+str(i),1999999900) for i in range(65)]
        self.batch(events,'history')
        self.assertEqual(sum(t.endswith('/state') for t,p in self.messages()),60)
        self.batch(events,'history')
        self.assertEqual(sum(t.endswith('/state') for t,p in self.messages()),65)

    def test_same_timestamp_and_ids_are_scoped_to_camera(self):
        events=[self.event(1,c,2000000001) for c in ['A','B']]+[self.event(2,'A',2000000001)]
        self.batch(events);before=len(self.messages());self.batch(events[::-1])
        self.assertEqual(before,len(self.messages()))
        self.assertEqual(sum(t.endswith('/events') for t,p in self.messages()),3)

    def test_expired_ids_cannot_replay_after_pruning(self):
        self.batch([self.event(1)])
        result=self.shell('BRIDGE_NOW=2000600000; process_events "$(cat "$DATA/input")" live',[self.event(1),self.event(2,ts=2000600000)])
        self.assertEqual(result.returncode,0,result.stderr)
        ledger=json.loads((self.data/'delivery.json').read_text())
        self.assertEqual(len(ledger['seen']),1)
        self.assertEqual(sum(t.endswith('/events') for t,p in self.messages()),2)

    def test_empty_trace_ids_use_stable_fallback(self):
        events=[dict(self.event(i),traceId='') for i in [1,2]]
        self.batch(events)
        self.batch([dict(self.event(3),traceId='')])
        sent=[json.loads(p)['timestamp'] for t,p in self.messages() if t.endswith('/events')]
        self.assertEqual(sent,[2000000001,2000000002,2000000003])
        before=len(self.messages());self.batch(events)
        self.assertEqual(len(self.messages()),before)

    def test_large_persistent_ledger_does_not_hit_argv_limit(self):
        path=self.data/'delivery.json';ledger=json.loads(path.read_text())
        ledger['seen']={json.dumps(['A','old-event-'+str(i)]):2000000000 for i in range(50000)}
        path.write_text(json.dumps(ledger))
        self.batch([self.event(1)])
        self.assertEqual(sum(t.endswith('/events') for t,p in self.messages()),1)

    def test_nested_ledger_corruption_fails_closed(self):
        path=self.data/'delivery.json';original=json.loads(path.read_text())
        for field,value in [('seen',{'key':None}),('latest',{'A':{'ts':None,'key':'id'}}),('motion',{'A':'bad'})]:
            ledger=dict(original);ledger[field]=value;path.write_text(json.dumps(ledger))
            self.assertNotEqual(self.shell('init_event_store').returncode,0,field)
        self.assertEqual(self.messages(),[])

    def test_corrupt_store_fails_closed(self):
        (self.data/'delivery.json').write_text('broken')
        self.assertNotEqual(self.shell('init_event_store').returncode,0)
        self.assertEqual(self.messages(),[])

    def test_motion_reset_and_stale_events(self):
        self.batch([self.event(1)])
        result=self.shell('BRIDGE_NOW=2000000010; reset_motion')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn(('vicohome/a/motion','OFF'),self.messages())
        self.assertEqual(json.loads((self.data/'delivery.json').read_text())['motion'],{})
        self.shell('BRIDGE_NOW=2000000500; process_events "$(cat "$DATA/input")" live',[self.event(2)])
        self.assertEqual(sum(p=='ON' for t,p in self.messages()),1)

    def test_bootstrap_arguments_and_cli_failures(self):
        cli=self.data/'cli'
        cli.write_text('#!/bin/bash\nprintf "%s\\n" "$@" >> "'+str(self.data/'args')+'"\necho "${RESPONSE:-[]}"\nexit "${STATUS:-0}"\n')
        cli.chmod(0o755)
        command='VICO_CLI="$DATA/cli"; BOOTSTRAP_HISTORY=true; fetch_events live'
        result=self.shell(command)
        self.assertEqual(result.returncode,0,result.stderr)
        args=(self.data/'args').read_text()
        self.assertIn('--startTime',args);self.assertIn('--endTime',args);self.assertNotIn('--since',args)
        self.assertTrue(json.loads((self.data/'delivery.json').read_text())['history_complete'])
        for response,status in [('bad',0),('[]',1),('null',0),('{"error":"auth"}',0)]:
            result=self.shell('export RESPONSE='+json.dumps(response)+'; export STATUS='+str(status)+'; '+command)
            self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.messages(),[])

if __name__=='__main__': unittest.main()
