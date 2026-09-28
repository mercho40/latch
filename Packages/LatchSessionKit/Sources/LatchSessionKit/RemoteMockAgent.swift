#if DEBUG
/// An ACP agent in `sh` for remote sessions. Every `case` matches one JSON key, never two:
/// Latch's encoder orders keys differently in every process. The prompt's text picks the
/// turn; a load replays `earlier question`, `earlier answer` and a tool row, as a saved
/// conversation; `prompts.log`, `decisions.log` and `loads.log` count what reached the agent, and
/// `slow.log`, `asked.log`, `tools.log`, `flood.log` and `deluge.log` when a turn got that far. A `fail-new`
/// file fails session/new. The `tools` and `flood` turns hold after their first output until
/// a `go` file appears, and exit with status 3 if a `die` file appears first; so does a load,
/// before its history, while there is a `hold-load` file, and so does `deluge`, which streams about 12 KB, a tool row and `mid` first. A hold also ends that way after a
/// minute, or once the process that started the agent has gone, so a test run that dies
/// mid-turn leaves no agent behind. The Mac app's tests and the iOS app's remote smoke run it;
/// `SmokeAgent.remoteScript` is the Mac bundle smoke's cut-down copy: a change to the JSON
/// Latch writes must keep both matching. Debug builds only: nothing shipped writes it.
public enum RemoteMockAgent {
    public static let script = #"""
    PATH=/usr/bin:/bin:$PATH
    prompt_id=
    reply() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$1" "$2"; }
    fail() { printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":"%s"}}\n' "$1" "$2" "$3"; }
    chunk() { printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"%s"}}}}\n' "$1"; }
    tool() { printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"%s","toolCallId":"call-7","title":"Read notes","status":"%s"}}}\n' "$1" "$2"; }
    said() { printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"%s"}}}}\n' "$1"; }
    hold() { n=0; while [ ! -f go ]; do if [ -f die ] || ! kill -0 "$PPID" 2>/dev/null || [ $n -ge 1200 ]; then exit 3; fi; n=$((n+1)); sleep 0.05; done; }
    ask() {
      printf '%s\n' '{"jsonrpc":"2.0","id":900,"method":"session/request_permission","params":{"sessionId":"session-1","toolCall":{"toolCallId":"call-1","title":"Edit file"},"options":[{"optionId":"allow-once","name":"Allow","kind":"allow_once"},{"optionId":"reject-once","name":"Reject","kind":"reject_once"}]}}'
    }
    while IFS= read -r line; do
      id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
      case "$line" in
        *\"method\":\"initialize\"*)
          reply "$id" '{"protocolVersion":1,"agentCapabilities":{"loadSession":true},"agentInfo":{"name":"mock-agent","version":"1.0.0"}}' ;;
        *\"method\":\"session*/new\"*)
          if [ -f fail-new ]; then fail "$id" -32603 "No sessions today"; continue; fi
          reply "$id" '{"sessionId":"session-1","modes":{"currentModeId":"ask","availableModes":[{"id":"ask","name":"Ask"},{"id":"code","name":"Code"}]},"models":{"currentModelId":"model-a","availableModels":[{"modelId":"model-a","name":"Model A"},{"modelId":"model-b","name":"Model B"}]}}' ;;
        *\"method\":\"session*/load\"*)
          echo load >> loads.log
          if [ -f hold-load ]; then hold; fi
          said earlier; said " question"; chunk "earlier answer"
          printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"tool_call","toolCallId":"call-h","title":"Read history","status":"completed"}}}'
          reply "$id" '{"modes":{"currentModeId":"ask","availableModes":[{"id":"ask","name":"Ask"},{"id":"code","name":"Code"}]}}' ;;
        *\"method\":\"session*/set_mode\"*)
          reply "$id" '{}' ;;
        *\"method\":\"session*/set_model\"*)
          reply "$id" '{}' ;;
        *\"method\":\"session*/prompt\"*)
          echo prompt >> prompts.log
          prompt_id=$id
          case "$line" in
            *permission*) chunk asking; ask ;;
            *slow*) chunk one; sleep 1; chunk two; chunk three; echo done >> slow.log; reply "$id" '{"stopReason":"end_turn"}' ;;
            *later*) sleep 1; chunk asking; ask; echo asked >> asked.log ;;
            *signin*) fail "$id" -32000 "Authentication required" ;;
            *broken*) fail "$id" -32603 "Something broke" ;;
            *crash*) exit 3 ;;
            *oversize*) chunk "$(printf '%04000d' 0)"; chunk after; reply "$id" '{"stopReason":"end_turn"}' ;;
            *tools*) chunk reading; tool tool_call pending; hold; tool tool_call_update completed; chunk done
              echo done >> tools.log; reply "$id" '{"stopReason":"end_turn"}' ;;
            *deluge*) chunk start; i=0
              while [ $i -lt 40 ]; do chunk "$(printf '%0300d' $i)"; i=$((i+1)); done
              tool tool_call pending; chunk mid; hold; tool tool_call_update completed; chunk done
              echo done >> deluge.log; reply "$id" '{"stopReason":"end_turn"}' ;;
            *flood*) chunk start; hold; i=0
              while [ $i -lt 40 ]; do chunk "$(printf '%0300d' $i)"; i=$((i+1)); done
              chunk end; echo done >> flood.log; reply "$id" '{"stopReason":"end_turn"}' ;;
            *) chunk one; chunk two; chunk three; reply "$id" '{"stopReason":"end_turn"}' ;;
          esac ;;
        *\"id\":900[,}]*)
          echo decision >> decisions.log
          case "$line" in
            *allow-once*) chunk allowed; reply "$prompt_id" '{"stopReason":"end_turn"}' ;;
            *reject-once*) chunk rejected; reply "$prompt_id" '{"stopReason":"end_turn"}' ;;
            *) reply "$prompt_id" '{"stopReason":"cancelled"}' ;;
          esac ;;
      esac
    done
    """#
}
#endif
