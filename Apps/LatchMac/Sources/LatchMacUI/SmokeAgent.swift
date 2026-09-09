enum SmokeAgent {
    static let script = #"""
    while IFS= read -r line; do
      case "$line" in
        *\"method\":\"initialize\"*)
          printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":false},"agentInfo":{"name":"mock-agent","version":"1.0.0"}}}'
          ;;
        *\"method\":\"session*new\"*)
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

    static let permissionScript = #"""
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
}
