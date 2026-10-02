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
Set FontSize 24
Set Width 1920
Set Height 1080
Set Framerate 30
Set Padding 24
Set TypingSpeed 40ms
Set PlaybackSpeed 1.0

# --- Enter the pre-built tmux layout ---
Hide
Type "./scripts/tmux-layout.sh && tmux attach -t demo" Enter
Sleep 2s
Show
# Hold a still, settled frame before any typing. This gives the H.264 encoder a
# clean keyframe to lock onto; starting straight into motion leaves the opening
# frames soft while rate control ramps up.
Sleep 2s

# ============================================================
# 1. DEPLOY  (TLS + ACL + config already in the manifest)
# ============================================================
Type "# 1) Deploy a cluster: 3 shards x 1 replica" Enter
Type "" Enter
Sleep 1s
Type "kubectl -n demo apply -f manifests/valkeycluster.yaml" Enter
Sleep 2s
Type "" Enter
# The valkeyclusters pane (middle) shows the cluster reach Ready live. It forms
# in ~23s from apply on a warm cluster; wait for that, then show the slot map:
# the 3 shards each own a slot range. This sets up the scale/migration story.
Sleep 30s
Type "" Enter
Type "# Each shard owns a range of the 16384 slots" Enter
Sleep 1s
Type "./scripts/show-topology.sh" Enter
Sleep 6s

# ============================================================
# 2. START THE WRITE LOAD  (counter appears in the top-right pane)
# ============================================================
Type "clear" Enter
Sleep 500ms
Type "# 2) Start a continuous write load - watch 'LOST' stay at 0" Enter
Type "" Enter
Sleep 1s
Type "./scripts/start-writeload.sh" Enter
Sleep 3s
# Narration pause: point out the live Writes/Acked/LOST counter, LOST at 0.
Sleep 5s

# ============================================================
# 3. UPGRADE the Valkey version  (replicas first, primary last)
# ============================================================
Type "clear" Enter
Sleep 500ms
Type "# 3) Upgrade the Valkey image - rolling, replicas first" Enter
Type "" Enter
Sleep 1s
Type `kubectl -n demo patch valkeycluster my-cluster --type merge -p '{"spec":{"image":"valkey/valkey:9.1.0"}}'` Enter
Sleep 2s
Type "" Enter
Type "# Watch the ROLE column as nodes roll (bottom pane)" Enter
# The rolling upgrade (replicas first, then each primary) must fully settle back
# to ClusterHealthy before the next step, or the scale-out starts on a cluster
# whose slots aren't fully covered and writes hit CLUSTERDOWN. Give it plenty of
# time; the tape advances on a fixed timer regardless of status.
Sleep 100s
# Narration pause: replicas upgraded first, primary last; LOST still 0.
Sleep 15s

# ============================================================
# 4. SCALE OUT then IN  (slot migration; needs Valkey 9.0+)
# ============================================================
Type "clear" Enter
Sleep 500ms
Type "# 4) Scale out 3 -> 4 shards (slots rebalance)" Enter
Type "" Enter
Sleep 1s
Type `kubectl -n demo patch valkeycluster my-cluster --type merge -p '{"spec":{"shards":4}}'` Enter
# Scale-out adds a shard (new pods) and rebalances slots onto it; must settle to
# healthy before scaling in, or the scale-in starts on uncovered slots.
Sleep 50s
Type "" Enter
Type "# ...and back in 4 -> 3 (slots drain first)" Enter
Sleep 1s
Type `kubectl -n demo patch valkeycluster my-cluster --type merge -p '{"spec":{"shards":3}}'` Enter
# Scale-in drains slots off the departing shard, then removes it.
Sleep 30s
# Narration pause: slots rebalanced out and drained back in; no writes lost.
Sleep 12s

# ============================================================
# 5. DELETE A PRIMARY POD  (automatic failover; LOST stays 0)
# ============================================================
Type "clear" Enter
Sleep 500ms
Type "# 5) Delete a primary pod - Valkey fails over, operator heals it" Enter
Type "" Enter
Sleep 1s
Type `PRIMARY=$(kubectl -n demo get valkeynodes -o jsonpath='{.items[?(@.status.role=="primary")].status.podName}' | awk '{print $1}')` Enter
Sleep 1s
Type "" Enter
Type "kubectl -n demo delete pod $PRIMARY --wait=false" Enter
# --wait=false returns immediately after the API accepts the delete, instead of
# blocking until the pod finishes terminating (which can take the full grace
# period). Without it the "pod deleted" output arrives late, in the middle of
# the next typed line.
Sleep 2s
Type "" Enter
Type "# Watch a replica's ROLE flip to primary, then the pod rejoin as replica" Enter
Sleep 15s
# Narration pause: replica promoted, deleted pod rejoined as replica; LOST 0.
Sleep 7s

# ============================================================
# WRAP
# ============================================================
# Close on the live panes (write-load counter at LOST 0, roles settled). The
# "zero acked writes lost" message is delivered live, not typed, to save time.
Sleep 5s

# --- Tear down the session so the attached shell exits and VHS can finalize ---
# Without this, the tape ends while 'tmux attach' is still running, the pane 2
# 'watch kubectl' loop keeps firing once per second, and VHS blocks forever
# waiting for the shell to return (pegged CPU, no output written).
Hide
Type "tmux kill-session -t demo" Enter
Sleep 2s
