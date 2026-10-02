#!/usr/bin/env bash
#
# tmux-layout.sh - build the demo's 4-pane layout inside a tmux session.
#
#   +---------------------------+-------------------+
#   | action (your commands)    | write-load        |
#   | (deploy, upgrade, scale)  | (Writes/Acked/LOST)|
#   +---------------------------+-------------------+
#   | kubectl get valkeyclusters (STATE, full width)|
#   +-----------------------------------------------+
#   | kubectl get valkeynodes   (ROLE,  full width) |
#   +-----------------------------------------------+
#
# vhs attaches to this session and drives the action pane. The other three run
# their own long-lived commands so they update live while you type.
#
# Usage (normally called by demo.tape, but you can run it standalone to rehearse):
#   ./scripts/tmux-layout.sh
#   tmux attach -t demo
set -euo pipefail
cd "$(dirname "$0")/.."

SESSION="${SESSION:-demo}"
NS="${NS:-demo}"

# Grid geometry, computed from the VHS video settings so the layout matches
# whatever font size the tape uses. Keep these in sync with demo.tape's
# Set FontSize / Set Width / Set Height / Set Padding.
FONT_SIZE="${FONT_SIZE:-24}"
VID_WIDTH="${VID_WIDTH:-1920}"
VID_HEIGHT="${VID_HEIGHT:-1080}"
PADDING="${PADDING:-24}"

# VHS's default monospace advances ~0.6*FontSize px per column and ~1.2*FontSize
# px per row. Derive the character grid from the usable pixel area (video size
# minus padding on both sides). Integer math via awk.
COLS=$(awk -v w="$VID_WIDTH" -v p="$PADDING" -v f="$FONT_SIZE" \
  'BEGIN{printf "%d", (w-2*p)/(0.6*f)}')
ROWS=$(awk -v h="$VID_HEIGHT" -v p="$PADDING" -v f="$FONT_SIZE" \
  'BEGIN{printf "%d", (h-2*p)/(1.2*f)}')

# Write-load pane width (top-right column): the counter line
# "Writes: N Acked: N LOST: N" is ~42 chars, so a slim column suffices. Use ~30%
# of the grid but never below 50 cols, so the line never wraps (a wrapped line
# makes the client's \r redraw on the wrong row). The action pane keeps the rest.
RIGHT_COLS=$(awk -v c="$COLS" 'BEGIN{r=int(c*0.30); if (r<50) r=50; printf "%d", r}')
# valkeyclusters strip (full width): one header + one row, so a few lines.
CLUSTER_ROWS=4
# valkeynodes row (full width): header plus up to ~8 node rows with margin.
NODES_ROWS=$(awk -v r="$ROWS" 'BEGIN{n=11; m=int(r*0.40); if (n>m) n=m; printf "%d", n}')

tmux kill-session -t "$SESSION" 2>/dev/null || true

# Plain bash for every pane, with no personal rc files or plugins (e.g. zsh
# autosuggestions) in the recording. Each pane starts as the login shell, then
# exec's into a clean bash, replacing that process. Doing it via send-keys
# avoids version-specific quirks of default-command/new-session command args
# that were killing the session or erroring with "no server running".
BASH_BIN="$(command -v bash)"
EXEC_BASH="exec $BASH_BIN --norc --noprofile"

# Create the session at the computed grid size. Do NOT use window-size latest
# here: we want tmux to keep this exact grid (and our exact split sizes) rather
# than adopt the attaching client's size.
tmux new-session -d -s "$SESSION" -x "$COLS" -y "$ROWS"
tmux set-option -t "$SESSION" status off

# Layout:
#   +---------------------------+-------------------+
#   | action (commands)         | write-load        |
#   +---------------------------+-------------------+
#   | kubectl get valkeyclusters (FULL WIDTH)       |
#   +-----------------------------------------------+
#   | kubectl get valkeynodes (FULL WIDTH)          |
#   +-----------------------------------------------+
# The cluster and node tables are wide, so they get full width along the bottom.
# The write-load counter is short, so a narrow top-right pane is fine.
#
# Capture stable pane IDs (%N) from each split rather than relying on positional
# index renumbering, which varies with tmux settings.
PANE_ACTION="$(tmux display-message -p -t "$SESSION:.0" '#{pane_id}')"
# Split a full-width lower area off the action pane. This first split holds the
# cluster view; a second split carves the nodes view off its bottom.
PANE_CLUSTER="$(tmux split-window -v -t "$PANE_ACTION" -l "$((CLUSTER_ROWS + NODES_ROWS))" -P -F '#{pane_id}')"
PANE_NODES="$(tmux split-window -v -t "$PANE_CLUSTER" -l "$NODES_ROWS" -P -F '#{pane_id}')"
# Split the top row into action (left) + write-load (right).
PANE_WRITE="$(tmux split-window -h -t "$PANE_ACTION" -l "$RIGHT_COLS" -P -F '#{pane_id}')"

# A clean, minimal prompt for every pane, so the recording never shows the
# personal PS1 (long path, git branch, username, host). PROMPT_COMMAND is unset
# first because prompt tools like Starship set the prompt from that hook and
# would otherwise overwrite PS1 on every command.
CLEAN_PROMPT="unset PROMPT_COMMAND; PS1='$ '; clear"

# Cluster pane (full width, upper of the two bottom strips): high-level view of
# the ValkeyCluster (STATE, REASON). Default columns; READYSHARDS is left hidden
# (it is CRD priority 1, shown only with -o wide) because it behaves oddly during
# the upgrade and would raise confusing questions on camera. --differences
# flashes changed cells.
tmux send-keys -t "$PANE_CLUSTER" "$EXEC_BASH" C-m
tmux send-keys -t "$PANE_CLUSTER" "$CLEAN_PROMPT" C-m
tmux send-keys -t "$PANE_CLUSTER" \
  "watch -t -n0.5 --differences kubectl -n $NS get valkeyclusters" C-m

# Nodes pane (full width, bottom): per-node role view. This is the slide-15
# highlight (ROLE column). --differences highlights cells that changed since the
# last refresh, so a replica being promoted to primary visibly flashes.
tmux send-keys -t "$PANE_NODES" "$EXEC_BASH" C-m
tmux send-keys -t "$PANE_NODES" "$CLEAN_PROMPT" C-m
tmux send-keys -t "$PANE_NODES" \
  "watch -t -n0.5 --differences kubectl -n $NS get valkeynodes" C-m

# Write-load pane (top-right): the acked/lost counter. Idle until step 2 of the
# tape starts it. PS1's first line is a comment banner, then clear, so the
# banner shows with no typed command line above it.
WRITE_PROMPT="unset PROMPT_COMMAND; PS1='# Valkey client\n$ '; clear"
tmux send-keys -t "$PANE_WRITE" "$EXEC_BASH" C-m
tmux send-keys -t "$PANE_WRITE" "$WRITE_PROMPT" C-m
# Tag the pane with a title so start-writeload.sh can find it by title rather
# than a positional index (which depends on pane-base-index / renumbering).
tmux select-pane -t "$PANE_WRITE" -T writeload

# Action pane (top-left): the pane VHS records and types into.
tmux send-keys -t "$PANE_ACTION" "$EXEC_BASH" C-m
tmux send-keys -t "$PANE_ACTION" "$CLEAN_PROMPT" C-m

# Focus the commands pane.
tmux select-pane -t "$PANE_ACTION"
echo "tmux session '$SESSION' ready. Attach with: tmux attach -t $SESSION"
