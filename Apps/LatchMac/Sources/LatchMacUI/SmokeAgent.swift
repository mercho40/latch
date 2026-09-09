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
}
