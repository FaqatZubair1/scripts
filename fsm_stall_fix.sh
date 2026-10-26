#!/usr/bin/env bash
# fsm_stall_fix.sh - run from the kernel root (android_kernel_motorola_sm6375).
#
# Fixes the ~2 s audio stall when a call rings on speaker+wired headset while
# media is playing: the FS1815 vbat monitor sends AFE get_params for
# AFE_MODULE_ID_FSADSP_RX on port 0xb030 while that module is not in the running
# topology, the DSP never answers, and afe_apr_send_pkt() waits 2 s while holding
# the global this_afe.afe_apr_lock (blocking every other AFE command).
#
# Changes (all-or-nothing; originals saved as *.orig):
#  1. q6afe.c : afe_apr_send_pkt() waits only Q6FSM_AFE_TIMEOUT_MS (500) for
#               q6fsm's own queries (other AFE commands keep the 2 s timeout).
#  2. q6fsm-v3.h: mark q6fsm's calls as "short timeout"; latch a timeout so the
#               RX module is not queried again until the monitor is re-enabled;
#               fix bool q6fsm_get_rx_status() returning -EINVAL (== true);
#               start the vbat monitor 500 ms after the port start, not at once.
#  3. optional: pass the speaker topology id(s) as arguments and the vbat monitor
#               is only started when the RX port topology is one of them, e.g.
#                   ./fsm_stall_fix.sh 0x000112fa
#
# Usage:  bash fsm_stall_fix.sh [topology_id ...]
set -euo pipefail

AFE=techpack/audio/dsp/q6afe.c
HDR=techpack/audio/include/dsp/q6fsm-v3.h

[ -f "$AFE" ] && [ -f "$HDR" ] || { echo "Run this from the kernel root (missing $AFE or $HDR)"; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required"; exit 1; }

python3 - "$AFE" "$HDR" "$@" <<'PY'
import sys, re

afe_path, hdr_path, *topo = sys.argv[1:]
afe = open(afe_path).read()
hdr = open(hdr_path).read()

if "q6fsm_short_timeout_task" in afe or "q6fsm_short_timeout_task" in hdr:
    print("Already patched, nothing to do.")
    sys.exit(0)

for t in topo:
    if not re.fullmatch(r"0[xX][0-9a-fA-F]+", t):
        sys.exit("Topology id must look like 0x000112fa, got: " + t)

def sub_once(text, old, new, what):
    n = text.count(old)
    if n != 1:
        sys.exit("ABORT (no files changed): anchor for '%s' found %d times, expected 1.\n"
                 "Your tree differs from the one I checked; send me that function." % (what, n))
    return text.replace(old, new)

# ---------------------------------------------------------------- q6fsm-v3.h
hdr = sub_once(hdr,
"static bool fsm_scene_status = false;\n",
"""static bool fsm_scene_status = false;

/*
 * q6fsm queries go through the global AFE command lock. If the FSADSP module
 * is not part of the running topology the DSP never answers, so use a short
 * wait for q6fsm's own commands (only the task that owns cmd_lock sets this)
 * and remember the failure until the monitor is re-enabled.
 */
#define Q6FSM_AFE_TIMEOUT_MS (500)
static struct task_struct *q6fsm_short_timeout_task;
static bool q6fsm_rx_dead;
""", "scene status decl")

# set_params call
hdr = sub_once(hdr,
"""				ret = q6afe_set_params(port_id, index, NULL,
					packed_param_data, packed_data_size);
				break;""",
"""				q6fsm_short_timeout_task = current;
				ret = q6afe_set_params(port_id, index, NULL,
					packed_param_data, packed_data_size);
				q6fsm_short_timeout_task = NULL;
				break;""", "q6afe_set_params call")

# get_params call
hdr = sub_once(hdr,
"""				ret = q6afe_get_params(port_id, NULL, param_hdr);
				break;""",
"""				q6fsm_short_timeout_task = current;
				ret = q6afe_get_params(port_id, NULL, param_hdr);
				q6fsm_short_timeout_task = NULL;
				break;""", "q6afe_get_params call")

# get_rx_status: bool fixes + latch
hdr = sub_once(hdr,
"""	if(fsm_scene_status == false){
		return -EINVAL;
	}

	if (!q6fsm_check_dsp_ready()) {
		fsm_info("DSP not ready yet!");
		return -EINVAL;
	}

	param_hdr.module_id = AFE_MODULE_ID_FSADSP_RX;
	param_hdr.instance_id = 0;
	param_hdr.reserved = 0;
	param_hdr.param_id = CAPI_V2_PARAM_FSADSP_RX_ENABLE;
	param_hdr.param_size = sizeof(enable);

	ret = q6fsm_afe_get_params(&param_hdr,
		(uint8_t *)&enable, sizeof(enable));
	if (ret) {
		fsm_err("Get params failed: %d", ret);
		return false;
	}

	return !!enable;""",
"""	if(fsm_scene_status == false){
		return false;
	}

	if (q6fsm_rx_dead)
		return false;

	if (!q6fsm_check_dsp_ready()) {
		fsm_info("DSP not ready yet!");
		return false;
	}

	param_hdr.module_id = AFE_MODULE_ID_FSADSP_RX;
	param_hdr.instance_id = 0;
	param_hdr.reserved = 0;
	param_hdr.param_id = CAPI_V2_PARAM_FSADSP_RX_ENABLE;
	param_hdr.param_size = sizeof(enable);

	ret = q6fsm_afe_get_params(&param_hdr,
		(uint8_t *)&enable, sizeof(enable));
	if (ret) {
		fsm_err("Get params failed: %d", ret);
		if (ret == -ETIMEDOUT)
			q6fsm_rx_dead = true;
		return false;
	}

	return !!enable;""", "q6fsm_get_rx_status body")

# monitor switch
topo_gate = ""
topo_def = ""
if topo:
    cond = " || ".join("(t) == %s" % t for t in topo)
    topo_def = "\n/* topology ids of the FS1815 speaker path (contain FSADSP_RX) */\n#define Q6FSM_TOPO_IS_SPK(t) (%s)\n" % cond
    topo_gate = """		if (!Q6FSM_TOPO_IS_SPK(afe_get_topology(Q6FSM_AFE_RX_PORT))) {
			fsm_info("no FSADSP in RX topology, skip vbat monitor");
			return;
		}
"""
    hdr = sub_once(hdr, "static bool q6fsm_rx_dead;\n", "static bool q6fsm_rx_dead;\n" + topo_def, "topo define")

hdr = sub_once(hdr,
"""		if (q6fsm->monitor_en)
			return;
		if(fsm_scene_status == false){
			fsm_info("no need to start vbat monitor");
			return;
		}
		q6fsm->monitor_en = true;
		queue_delayed_work(q6fsm->vbat_wq, &q6fsm->vbat_work, 0);
	} else {
		if (!q6fsm->monitor_en)
			return;""",
"""		if (q6fsm->monitor_en)
			return;
		q6fsm_rx_dead = false;
		if(fsm_scene_status == false){
			fsm_info("no need to start vbat monitor");
			return;
		}
""" + topo_gate + """		q6fsm->monitor_en = true;
		/* give the DSP time to bring the port up before the first query */
		queue_delayed_work(q6fsm->vbat_wq, &q6fsm->vbat_work,
				msecs_to_jiffies(500));
	} else {
		q6fsm_rx_dead = false;
		if (!q6fsm->monitor_en)
			return;""", "q6fsm_monitor_switch body")

# ------------------------------------------------------------------ q6afe.c
anchor = "static int afe_apr_send_pkt(void *data, wait_queue_head_t *wait)\n{"
start = afe.find(anchor)
if start < 0 or afe.count(anchor) != 1:
    sys.exit("ABORT (no files changed): afe_apr_send_pkt() not found exactly once.")
old_wait = "msecs_to_jiffies(2 * TIMEOUT_MS)"
pos = afe.find(old_wait, start)
end_of_func = afe.find("\n}\n", start)
if pos < 0 or pos > end_of_func:
    sys.exit("ABORT (no files changed): wait_event_timeout not found inside afe_apr_send_pkt().")
afe = afe[:pos] + "msecs_to_jiffies(AFE_APR_WAIT_MS())" + afe[pos+len(old_wait):]

macro = """#ifdef CONFIG_SND_SOC_FS1815
/* q6fsm's own queries must not hold afe_apr_lock for the full 2 s */
#define AFE_APR_WAIT_MS() ((q6fsm_short_timeout_task == current) ? \\
			   Q6FSM_AFE_TIMEOUT_MS : (2 * TIMEOUT_MS))
#else
#define AFE_APR_WAIT_MS() (2 * TIMEOUT_MS)
#endif

"""
comment_anchor = "/*\n * afe_apr_send_pkt : returns 0 on success, negative otherwise.\n */\n"
if afe.count(comment_anchor) != 1:
    sys.exit("ABORT (no files changed): afe_apr_send_pkt comment anchor not found once.")
afe = afe.replace(comment_anchor, macro + comment_anchor)

# --- all edits succeeded in memory: now write (with backups)
for p, orig in ((afe_path, None), (hdr_path, None)):
    pass
import shutil
shutil.copyfile(afe_path, afe_path + ".orig")
shutil.copyfile(hdr_path, hdr_path + ".orig")
open(afe_path, "w").write(afe)
open(hdr_path, "w").write(hdr)
print("Patched:\n  %s\n  %s\n(backups: *.orig)" % (afe_path, hdr_path))
if topo:
    print("Topology gate enabled for: " + ", ".join(topo))
else:
    print("No topology ids given -> relying on the short timeout + latch only.")
PY

echo
echo "Review with:  diff -u $AFE.orig $AFE; diff -u $HDR.orig $HDR"
echo "Revert with:  mv $AFE.orig $AFE; mv $HDR.orig $HDR"
