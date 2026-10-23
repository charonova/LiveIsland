# Shares Claude Code's usage percentages with LiveIsland (opt-in).
#
# Claude Code hands its status line command a JSON object on stdin that includes
# `rate_limits.five_hour` and `rate_limits.seven_day`; it doesn't save them anywhere else.
# These lines go INSIDE your status line script, right after it reads stdin into $input
# (typed into a terminal they do nothing). LiveIsland's Settings › AI Agents can add them for you.

# LiveIsland: share Claude Code's usage limits with the island (delete these lines to stop).
if limits=$(printf '%s' "$input" | jq -c 'select(.rate_limits != null) | {observed_at: now, transcript_path, rate_limits}' 2>/dev/null) && [ -n "$limits" ]; then
  printf '%s\n' "$limits" > "$HOME/.claude/liveisland-limits.json.tmp" && mv -f "$HOME/.claude/liveisland-limits.json.tmp" "$HOME/.claude/liveisland-limits.json"
fi
