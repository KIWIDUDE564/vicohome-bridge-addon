import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
class MQTTTests(unittest.TestCase):
    def shell(self,code,fail=''):
        with tempfile.TemporaryDirectory() as tmp:
            log=Path(tmp)/'log'
            script=r'''
source "$ROOT/vicohome_bridge/run.sh"
bashio::log.warning() { :; }; bashio::log.debug() { :; }
bashio::services.available() { return 0; }
bashio::services() { case "$2" in host) echo supervisor;; port) echo 1883;; username) echo user;; password) echo 'pass with spaces';; esac; }
bashio::config() { case "$1" in mqtt_host) echo "${HOST:-}";; mqtt_port) echo 1884;; mqtt_username) echo 'external user';; mqtt_password) echo 'password with spaces * $()';; mqtt_tls) echo false;; esac; }
mqtt_publish() {
 python3 -c 'import os,sys,json; open(os.environ["LOG"],"a").write(json.dumps(sys.argv[1:])+"\n")' "$@"
 [[ "$*" != *"$FAIL"* || -z "$FAIL" ]]
}
DATA_DIR="$DATA"; DISCOVERY_REFRESH_SECONDS=300; DISCOVERY_SESSION=test
BASE_TOPIC=vicohome; AVAILABILITY_TOPIC=vicohome/bridge/status; MQTT_ARGS=(-h broker)
''' + code
            result=subprocess.run(['bash','-c',script],env=dict(os.environ,ROOT=str(ROOT),DATA=tmp,LOG=str(log),FAIL=fail),capture_output=True,text=True)
            rows=[json.loads(x) for x in log.read_text().splitlines()] if log.exists() else []
            return result,rows

    def test_names_retention_templates_and_identities(self):
        result,rows=self.shell('ensure_discovery_published "Camera-A" \'Front "Door"\\Back\'')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(len(rows),6)
        configs=[json.loads(r[r.index('-m')+1]) for r in rows if r[r.index('-t')+1].endswith('/config')]
        self.assertTrue(all('-r' in r for r in rows))
        self.assertEqual(configs[0]['unique_id'],'vicohome_camera_v3_camera_a_last_event')
        self.assertEqual(configs[0]['device']['name'],'Vicohome Front "Door"\\Back')
        self.assertIn(".get(",configs[0]['value_template'])
        self.assertEqual(configs[1]['off_delay'],5)
        self.assertEqual(rows[-1][rows[-1].index('-m')+1],'OFF')

    def test_failed_discovery_does_not_set_marker(self):
        result,rows=self.shell('ensure_discovery_published A Test; ensure_discovery_published A Test',fail='/config')
        self.assertGreaterEqual(len(rows),2)
        self.assertNotEqual(result.returncode,0)

    def test_successful_discovery_is_cached(self):
        result,rows=self.shell('ensure_discovery_published A Test; ensure_discovery_published A Test')
        self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(len(rows),6)

    def test_external_settings_and_password_arguments(self):
        result,rows=self.shell('HOST=external; configure_mqtt; mqtt_publish "${MQTT_ARGS[@]}" -t test -m test')
        self.assertEqual(result.returncode,0,result.stderr)
        args=rows[0]
        self.assertEqual(args[args.index('-h')+1],'external')
        self.assertEqual(args[args.index('-P')+1],'password with spaces * $()')
        self.assertEqual(args[args.index('-p')+1],'1884')

    def test_supervisor_fallback(self):
        result,rows=self.shell('configure_mqtt; mqtt_publish "${MQTT_ARGS[@]}" -t test -m test')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(rows[0][rows[0].index('-h')+1],'supervisor')
        self.assertEqual(rows[0][rows[0].index('-P')+1],'pass with spaces')
