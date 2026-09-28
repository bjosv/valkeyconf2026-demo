#!/usr/bin/env bash
#
# tmux-layout.sh - build the 3-pane demo layout inside a tmux session.
#
#   +-----------------------------+-----------------------+
#   | PANE 0: your commands        | PANE 1: write counter |
#   | (deploy, upgrade, scale...)  | (acked / LOST)        |
#   |                              +-----------------------+
#   |                              | PANE 2: watch roles   |
#   |                              | kubectl get valkeynodes|
#   +-----------------------------+-----------------------+
#
# vhs attaches to this session and drives PANE 0. Panes 1 and 2 run their own
# long-lived commands so they update live while you type in pane 0.
#
# Usage (normally called by demo.tape, but you can run it standalone to rehearse):
#   ./scripts/tmux-layout.sh
#   tmux attach -t demo
set -euo pipefail
cd "$(dirname "$0")/.."

SESSION="${SESSION:-demo}"
NS="${NS:-demo}"

tmux kill-session -t "$SESSION" 2>/dev/null || true

# Plain bash for every pane, with no personal rc files or plugins (e.g. zsh
# autosuggestions) in the recording. Each pane starts as the login shell, then
# exec's into a clean bash, replacing that process. Doing it via send-keys
# avoids version-specific quirks of default-command/new-session command args
# that were killing the session or erroring with "no server running".
BASH_BIN="$(command -v bash)"
EXEC_BASH="exec $BASH_BIN --norc --noprofile"

# Create the session (this starts the tmux server and keeps it alive).
tmux new-session -d -s "$SESSION" -x 210 -y 50

# Size windows to the attaching client (VHS's ttyd), not to a fixed geometry.
# With a pinned -x/-y session size, tmux can fail to reconcile against the
# client that attaches later and errors with "size missing"; sizing to the
# latest attached client avoids that.
tmux set-option -t "$SESSION" window-size latest
tmux set-option -t "$SESSION" aggressive-resize on
# Hide the tmux status bar; it is UI chrome that shouldn't appear in the video.
tmux set-option -t "$SESSION" status off

# Pane 0 left (commands). Split off a right column (panes 1 then 2). Use -l with
# an explicit cell count instead of the removed -p percentage flag (dropped in
# tmux 3.x). The session is 210 cols x 50 rows: 100 cols for the right column so
# the 'kubectl get valkeynodes' rows fit without wrapping; 28 rows is ~55% of
# that column for the bottom pane.
tmux split-window -h -t "$SESSION:.0" -l 100  # pane 1 (right, top)
tmux split-window -v -t "$SESSION:.1" -l 28   # pane 2 (right, bottom)

# Pane 2: live role view. This is the slide-15 highlight (ROLE column).
# --differences highlights cells that changed since the last refresh, so a
# A clean, minimal prompt for every pane, so the recording never shows the
# personal PS1 (long path, git branch, username, host). PROMPT_COMMAND is unset
# first because prompt tools like Starship set the prompt from that hook and
# would otherwise overwrite PS1 on every command.
CLEAN_PROMPT="unset PROMPT_COMMAND; PS1='$ '; clear"

# replica being promoted to primary visibly flashes on camera.
tmux send-keys -t "$SESSION:.2" "$EXEC_BASH" C-m
tmux send-keys -t "$SESSION:.2" "$CLEAN_PROMPT" C-m
tmux send-keys -t "$SESSION:.2" \
  "watch -t -n1 --differences kubectl -n $NS get valkeynodes" C-m

# Pane 1: write-load counter. Runs from inside a Valkey pod once the cluster is up.
# Idle until step 2 of the tape starts the counter. Give it a PS1 whose first
# line is a comment banner, then clear; the banner is redrawn by the prompt, so
# it shows on screen with no typed command line above it.
WRITE_PROMPT="unset PROMPT_COMMAND; PS1='# write-load\n$ '; clear"
tmux send-keys -t "$SESSION:.1" "$EXEC_BASH" C-m
tmux send-keys -t "$SESSION:.1" "$WRITE_PROMPT" C-m

# Pane 0: the pane VHS records and types into.
tmux send-keys -t "$SESSION:.0" "$EXEC_BASH" C-m
tmux send-keys -t "$SESSION:.0" "$CLEAN_PROMPT" C-m

# Focus the commands pane.
tmux select-pane -t "$SESSION:.0"
echo "tmux session '$SESSION' ready. Attach with: tmux attach -t $SESSION"
