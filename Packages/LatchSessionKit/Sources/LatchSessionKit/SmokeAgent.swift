public enum SmokeAgent {
    public static let script = #"""
    while IFS= read -r line; do
      case "$line" in
        *\"method\":\"initialize\"*)
          printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":false},"agentInfo":{"name":"mock-agent","version":"1.0.0"}}}'
          ;;
        *\"method\":\"session*new\"*)
          printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"review","description":"Review the current changes","input":{"hint":"what to focus on"}},{"name":"compact","description":"Summarise the conversation so far"},{"name":"init","description":"Write an AGENTS.md for this workspace"}]}}}'
          printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1"}}'
          ;;
        *\"method\":\"session*prompt\"*)
          printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"working"}}}}'
          ;;
        *\"method\":\"session*cancel\"*)
          printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"cancelled"}}'
          ;;
      esac
    done
    """#

    public static let permissionScript = #"""
    while IFS= read -r line; do
      case "$line" in
        *\"method\":\"initialize\"*)
          printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":false}}}'
          ;;
        *\"method\":\"session*new\"*)
          printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1"}}'
          ;;
        *\"method\":\"session*prompt\"*)
          printf '%s\n' '{"jsonrpc":"2.0","id":"permission-1","method":"session/request_permission","params":{"sessionId":"session-1","toolCall":{"toolCallId":"read-1","title":"Read example.txt","rawInput":{"path":"example.txt"}},"options":[{"optionId":"read-once","name":"Read once","kind":"allow_once"},{"optionId":"reject","name":"Do not read","kind":"reject_once"}]}}'
          ;;
        *\"id\":\"permission-1\"*)
          case "$line" in
            *\"optionId\":\"read-once\"*) text='permission selected' ;;
            *\"optionId\":\"reject\"*) text='permission rejected' ;;
            *) text='permission cancelled' ;;
          esac
          printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"'"$text"'"}}}}'
          printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'
          ;;
        *\"method\":\"session*cancel\"*)
          printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"cancelled"}}'
          ;;
      esac
    done
    """#

    /// The remote smoke's agent, run by a real `latch-server` from a file in its workspace.
    /// It writes its PID so the script can tell it outlived the app, and counts the prompts that
    /// reached it. `slow` pauses mid-turn, and writes `slow.log` once the rest of its turn is out,
    /// so the smoke can bring a dropped connection back only after that.
    /// The app tests' `RemoteMockAgent` is the fuller version; keep the two matching the JSON Latch writes.
    public static let remoteScript = #"""
    echo $$ > agent.pid
    prompt_id=
    reply() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$1" "$2"; }
    chunk() { printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"%s"}}}}\n' "$1"; }
    while IFS= read -r line; do
      id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
      case "$line" in
        *\"method\":\"initialize\"*)
          reply "$id" '{"protocolVersion":1,"agentCapabilities":{"loadSession":false},"agentInfo":{"name":"remote-smoke","version":"1.0.0"}}'
          ;;
        *\"method\":\"session*new\"*)
          reply "$id" '{"sessionId":"session-1"}'
          ;;
        *\"method\":\"session*prompt\"*)
          echo prompt >> prompts.log
          prompt_id=$id
          case "$line" in
            *permission*)
              chunk 'asking '
              printf '%s\n' '{"jsonrpc":"2.0","id":900,"method":"session/request_permission","params":{"sessionId":"session-1","toolCall":{"toolCallId":"edit-1","title":"Edit notes.txt"},"options":[{"optionId":"allow-once","name":"Allow","kind":"allow_once"},{"optionId":"reject-once","name":"Reject","kind":"reject_once"}]}}'
              ;;
            *slow*) chunk 'one '; sleep 1; chunk 'two '; chunk three; echo done >> slow.log; reply "$id" '{"stopReason":"end_turn"}' ;;
            *) chunk 'one '; chunk 'two '; chunk three; reply "$id" '{"stopReason":"end_turn"}' ;;
          esac
          ;;
        *\"id\":900[,}]*)
          case "$line" in
            *allow-once*) chunk allowed ;;
            *) chunk refused ;;
          esac
          reply "$prompt_id" '{"stopReason":"end_turn"}'
          ;;
      esac
    done
    """#
}
