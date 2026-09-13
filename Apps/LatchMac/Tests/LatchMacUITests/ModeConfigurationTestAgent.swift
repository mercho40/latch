/// Test-owned mode protocol fixture, independent of the UI smoke agent.
/// Fast/deep are deliberately opaque offered mode IDs, not built-in permission policies.
enum ModeConfigurationTestAgent {
    enum Variant {
        case modern, rejectEffort, legacy, mixedLegacyEffort, updates
        case updateAfterNewSession, updateAfterConfigReply, updateBeforeConfigReply
        case updateAfterLegacyReply, updateBeforeLegacyReply, legacyUpdateAfterNewSession
        case rejectModernMode, rejectLegacyMode, exitOnSelection
        case replyOnTermination(markerPath: String)
    }

    static func script(variant: Variant) -> String {
        let scenario: String
        var marker = ""
        switch variant {
        case .modern: scenario = "modern"
        case .rejectEffort: scenario = "reject-effort"
        case .legacy: scenario = "legacy"
        case .mixedLegacyEffort: scenario = "mixed"
        case .updates: scenario = "updates"
        case .updateAfterNewSession: scenario = "new-update"
        case .updateAfterConfigReply: scenario = "reply-update"
        case .updateBeforeConfigReply: scenario = "update-reply"
        case .updateAfterLegacyReply: scenario = "legacy-update"
        case .updateBeforeLegacyReply: scenario = "legacy-before"
        case .legacyUpdateAfterNewSession: scenario = "legacy-new-update"
        case .rejectModernMode: scenario = "reject-modern"
        case .rejectLegacyMode: scenario = "reject-legacy"
        case .exitOnSelection: scenario = "exit"
        case let .replyOnTermination(path):
            scenario = "waiting"
            marker = path
        }
        let header = "scenario='\(scenario)'\nmarker='\(marker.replacingOccurrences(of: "'", with: "'\\''"))'\n"
        return header + #"""
        permission=fast
        effort=low
        pending=
        prompt_id=
        legacy_modes='{"currentModeId":"fast","availableModes":[{"id":"fast","name":"Fast"},{"id":"deep","name":"Deep"}]}'
        snapshot() {
          efforts='[{"value":"low","name":"Low"},{"value":"high","name":"High"}]'
          if [ "$permission" = deep ]; then efforts='[{"value":"high","name":"High"}]'; fi
          options='[{"id":"mode","name":"Mode","category":"mode","type":"select","currentValue":"'"$permission"'","options":[{"value":"fast","name":"Fast"},{"value":"deep","name":"Deep"}]},{"id":"effort","name":"Effort","category":"thought_level","type":"select","currentValue":"'"$effort"'","options":'"$efforts"'}]'
          if [ "$scenario" = mixed ]; then
            options='[{"id":"effort","name":"Effort","category":"thought_level","type":"select","currentValue":"'"$effort"'","options":'"$efforts"'}]'
          fi
        }
        config_update() {
          printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"config_option_update","configOptions":%s}}}\n' "$1"
        }
        mode_update() {
          printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"current_mode_update","currentModeId":"%s"}}}\n' "$1"
        }
        reply() {
          printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$id" "$1"
        }
        reject() {
          printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":"%s"}}\n' "$id" "$1"
        }
        message() {
          printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"%s"}}}}\n' "$1"
        }
        late_reply() {
          if [ -n "$pending" ]; then
            id=$pending
            reply '{"configOptions":'"$options"'}'
            printf '%s\n' "$pending" > "$marker"
          fi
          exit 0
        }
        trap late_reply TERM
        while IFS= read -r line; do
          line=$(printf '%s\n' "$line" | /usr/bin/sed 's@\\/@/@g')
          id=$(printf '%s\n' "$line" | /usr/bin/sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
          case "$line" in
            *\"method\":\"initialize\"*)
              reply '{"protocolVersion":1,"agentCapabilities":{"loadSession":false},"agentInfo":{"name":"mode-test-agent","version":"1.0.0"}}'
              ;;
            *\"method\":\"session/new\"*)
              snapshot
              case "$scenario" in
                legacy|legacy-update|legacy-before|reject-legacy)
                  reply '{"sessionId":"session-1","modes":'"$legacy_modes"'}'
                  ;;
                legacy-new-update)
                  printf '%s\n' "$(
                    reply '{"sessionId":"session-1","modes":'"$legacy_modes"'}'
                    mode_update deep
                    config_update '[]'
                  )"
                  ;;
                mixed)
                  reply '{"sessionId":"session-1","modes":'"$legacy_modes"',"configOptions":'"$options"'}'
                  ;;
                new-update)
                  initial_options=$options
                  permission=deep; effort=high; snapshot
                  printf '%s\n' "$(
                    reply '{"sessionId":"session-1","configOptions":'"$initial_options"'}'
                    config_update "$options"
                    message 'new-session burst delivered'
                  )"
                  ;;
                *) reply '{"sessionId":"session-1","configOptions":'"$options"'}' ;;
              esac
              ;;
            *\"method\":\"session/set_config_option\"*)
              if [ "$scenario" = exit ]; then exit 23; fi
              case "$line" in
                *\"configId\":\"effort\"*)
                  if [ "$scenario" = reject-effort ]; then reject 'Effort rejected'; continue; fi
                  case "$line" in
                    *\"value\":\"high\"*) effort=high ;;
                    *\"value\":\"low\"*) effort=low ;;
                    *) exit 92 ;;
                  esac
                  ;;
                *\"configId\":\"mode\"*)
                  if [ "$scenario" = reject-modern ]; then reject 'Mode rejected'; continue; fi
                  case "$line" in
                    *\"value\":\"deep\"*) permission=deep; effort=high ;;
                    *\"value\":\"fast\"*) permission=fast ;;
                    *) exit 93 ;;
                  esac
                  ;;
                *) exit 94 ;;
              esac
              snapshot
              case "$scenario" in
                waiting)
                  pending=$id
                  message 'selection waiting'
                  ;;
                reply-update|update-reply)
                  deep_options=$options
                  permission=fast; effort=low; snapshot
                  printf '%s\n' "$(
                    if [ "$scenario" = reply-update ]; then
                      reply '{"configOptions":'"$deep_options"'}'
                      config_update "$options"
                    else
                      config_update "$deep_options"
                      reply '{"configOptions":'"$options"'}'
                    fi
                    message 'config ordering delivered'
                  )"
                  ;;
                *) reply '{"configOptions":'"$options"'}' ;;
              esac
              ;;
            *\"method\":\"session/set_mode\"*)
              case "$scenario" in legacy|legacy-update|legacy-before|mixed|reject-legacy|legacy-new-update) ;; *) exit 95 ;; esac
              case "$line" in *\"modeId\":\"deep\"*) ;; *) exit 96 ;; esac
              case "$scenario" in
                reject-legacy) reject 'Mode rejected' ;;
                legacy-update|legacy-before)
                  printf '%s\n' "$(
                    if [ "$scenario" = legacy-before ]; then mode_update fast; fi
                    reply '{}'
                    if [ "$scenario" = legacy-update ]; then mode_update fast; fi
                    message 'legacy ordering delivered'
                  )"
                  ;;
                *) permission=deep; reply '{}' ;;
              esac
              ;;
            *\"method\":\"session/prompt\"*)
              if [ "$scenario" = updates ]; then
                permission=deep; effort=high; snapshot
                config_update "$options"
                printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"wrong-session","update":{"sessionUpdate":"config_option_update","configOptions":[]}}}'
                message 'updates delivered'
                reply '{"stopReason":"end_turn"}'
              elif [ "$scenario" = new-update ]; then
                message 'new-session updates drained'
                reply '{"stopReason":"end_turn"}'
              else
                prompt_id=$id
                message working
              fi
              ;;
            *\"method\":\"session/cancel\"*)
              id=$prompt_id
              reply '{"stopReason":"cancelled"}'
              ;;
          esac
        done
        late_reply
        """#
    }
}
