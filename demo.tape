# demo.tape - VHS script for the ValkeyConf 2026 operator demo.
#
# Produces a silent screencast (MP4 + GIF) you narrate live.
# Prereqs: run scripts/00-setup.sh first (off camera), and have the demo
# ValkeyCluster NOT yet applied (this tape applies it on camera).
#
# Record with:   vhs demo.tape
# Output:        out/demo.mp4  and  out/demo.gif
#
# Layout: this tape builds the tmux layout, then drives PANE 0 (commands).
# Panes 1 (write-load) and 2 (roles) update live on their own.

Output out/demo.mp4

# --- Look & feel (light theme, readable on a projector) ---
Set Shell "bash"
Set Theme "Github"
Set FontSize 20
Set Width 1920
Set Height 1080
Set Padding 24
Set TypingSpeed 60ms
Set PlaybackSpeed 1.0

# --- Enter the pre-built tmux layout ---
Hide
Type "./scripts/tmux-layout.sh && tmux attach -t demo" Enter
Sleep 2s
Show

# ============================================================
# 1. DEPLOY  (TLS + ACL + config already in the manifest)
# ============================================================
Type "# 1) Deploy a production-grade cluster: TLS, ACL, 3 shards x 1 replica" Enter
Sleep 1s
Type "kubectl -n demo apply -f manifests/valkeycluster.yaml" Enter
Sleep 2s
Type "kubectl -n demo get valkeycluster -w" Enter
# Wait for the cluster to reach Ready (watch exits when you Ctrl-C).
Sleep 45s
Ctrl+C
Sleep 1s
Type "kubectl -n demo get valkeynodes" Enter
Sleep 3s

# ============================================================
# 2. START THE WRITE LOAD  (counter appears in the top-right pane)
# ============================================================
Type "" Enter
Type "# 2) Start a continuous write load - watch 'LOST' stay at 0" Enter
Sleep 1s
Type "./scripts/start-writeload.sh" Enter
Sleep 5s

# ============================================================
# 3. UPGRADE the Valkey version  (replicas first, primary last)
# ============================================================
Type "" Enter
Type "# 3) Upgrade the Valkey image - rolling, replicas first" Enter
Sleep 1s
Type "kubectl -n demo patch valkeycluster my-cluster --type merge --patch-file manifests/upgrade-patch.yaml" Enter
Sleep 2s
Type "# watch the ROLE column (bottom-right) as nodes roll" Enter
Sleep 40s

# ============================================================
# 4. SCALE OUT then IN  (slot migration; needs Valkey 9.0+)
# ============================================================
Type "" Enter
Type "# 4) Scale out 3 -> 4 shards (slots rebalance)" Enter
Sleep 1s
Type `kubectl -n demo patch valkeycluster my-cluster --type merge -p '{"spec":{"shards":4}}'` Enter
Sleep 35s
Type "# ...and back in 4 -> 3 (slots drain first)" Enter
Sleep 1s
Type `kubectl -n demo patch valkeycluster my-cluster --type merge -p '{"spec":{"shards":3}}'` Enter
Sleep 35s

# ============================================================
# 5. DELETE A PRIMARY POD  (automatic failover; LOST stays 0)
# ============================================================
Type "" Enter
Type "# 5) Delete a primary pod - Valkey fails over, operator heals it" Enter
Sleep 1s
Type `PRIMARY=$(kubectl -n demo get valkeynodes -o jsonpath='{.items[?(@.status.role=="primary")].status.podName}' | awk '{print $1}')` Enter
Sleep 1s
Type "echo deleting primary pod: $PRIMARY" Enter
Sleep 1s
Type "kubectl -n demo delete pod $PRIMARY" Enter
Type "# watch a replica's ROLE flip to primary, then the pod rejoin as replica" Enter
Sleep 40s

# ============================================================
# WRAP
# ============================================================
Type "" Enter
Type "kubectl -n demo get valkeynodes" Enter
Sleep 4s
Type "# Zero acked writes lost throughout." Enter
Sleep 4s

# --- Tear down the session so the attached shell exits and VHS can finalize ---
# Without this, the tape ends while 'tmux attach' is still running, the pane 2
# 'watch kubectl' loop keeps firing once per second, and VHS blocks forever
# waiting for the shell to return (pegged CPU, no output written).
Hide
Type "tmux kill-session -t demo" Enter
Sleep 2s
