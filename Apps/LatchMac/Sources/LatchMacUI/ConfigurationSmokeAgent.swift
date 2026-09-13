/// Provider-free ACP fixture shared by UI smoke runs and SessionModel integration tests.
/// Stdout is exclusively JSON-RPC. Request IDs are extracted rather than assumed.
enum ConfigurationSmokeAgent {
    enum Variant {
        case modern
        case permissionMode
        case rejectEffort
        case legacy
        /// Bursts session/new fast+low, then deep+high and a sentinel notification.
        case updateAfterNewSession
        /// Bursts a deep+high selection reply, then a newer fast+low notification.
        case updateAfterConfigReply
        /// Bursts deep+high notification, then the agent's canonical fast+low reply.
        case updateBeforeConfigReply
        /// A legacy acknowledgement is immediately superseded by current_model_update fast.
        case updateAfterLegacyReply
        /// Legacy models coexist with modern, effort-only config snapshots.
        case mixedLegacyEffort
        /// A prompt triggers a matching snapshot, then a deliberately wrong-session snapshot.
        case updates
        /// Holds selection until stdin closes or SIGTERM, then attempts the old reply.
        case replyOnTermination(markerPath: String)
        case exitOnSelection
    }

    /// Starts fast + low; high succeeds; deep returns a full snapshot offering only high effort.
    static let script = script(variant: .modern)

    static func script(variant: Variant) -> String {
        let mode: String
        var marker = ""
        switch variant {
        case .modern: mode = "modern"
        case .permissionMode: mode = "permission-mode"
        case .rejectEffort: mode = "reject-effort"
        case .legacy: mode = "legacy"
        case .updateAfterNewSession: mode = "new-update"
        case .updateAfterConfigReply: mode = "reply-update"
        case .updateBeforeConfigReply: mode = "update-reply"
        case .updateAfterLegacyReply: mode = "legacy-update"
        case .mixedLegacyEffort: mode = "mixed"
        case .updates: mode = "updates"
        case let .replyOnTermination(path):
            mode = "waiting"
            marker = path
        case .exitOnSelection: mode = "exit"
        }
        let header = "mode='\(mode)'\nmarker='\(marker.replacingOccurrences(of: "'", with: "'\\''"))'\n"
        return header + #"""
        model=fast
        effort=low
        permission=default
        pending=
        prompt_id=
        legacy_models='{"currentModelId":"fast","availableModels":[{"modelId":"fast","name":"Fast"},{"modelId":"deep","name":"Deep"}]}'
        snapshot() {
          efforts='[{"value":"low","name":"Low"},{"value":"high","name":"High"}]'
          if [ "$model" = deep ]; then efforts='[{"value":"high","name":"High"}]'; fi
          options='[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"'"$model"'","options":[{"value":"fast","name":"Fast"},{"value":"deep","name":"Deep"}]},{"id":"effort","name":"Effort","category":"thought_level","type":"select","currentValue":"'"$effort"'","options":'"$efforts"'}]'
          if [ "$mode" = permission-mode ]; then
            options=${options%]}' ,{"id":"mode","name":"Permission mode","category":"mode","type":"select","currentValue":"'"$permission"'","options":[{"value":"default","name":"Ask before edits"},{"value":"plan","name":"Plan only"}]}]'
          fi
          if [ "$mode" = mixed ]; then
            options='[{"id":"effort","name":"Effort","category":"thought_level","type":"select","currentValue":"'"$effort"'","options":'"$efforts"'}]'
          fi
        }
        config_update() {
          printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"config_option_update","configOptions":%s}}}\n' "$1"
        }
        reply() {
          printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$id" "$1"
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
          # ACP's encoder may escape slashes. No provider, jq, or PATH dependency.
          line=$(printf '%s\n' "$line" | /usr/bin/sed 's@\\/@/@g')
          id=$(printf '%s\n' "$line" | /usr/bin/sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
          case "$line" in
            *\"method\":\"initialize\"*)
              reply '{"protocolVersion":1,"agentCapabilities":{"loadSession":false},"agentInfo":{"name":"configuration-smoke","version":"1.0.0"}}'
              ;;
            *\"method\":\"session/new\"*)
              snapshot
              case "$mode" in
                legacy|legacy-update)
                  reply '{"sessionId":"session-1","models":'"$legacy_models"'}'
                  ;;
                mixed)
                  reply '{"sessionId":"session-1","models":'"$legacy_models"',"configOptions":'"$options"'}'
                  ;;
                new-update)
                  initial_options=$options
                  model=deep; effort=high; snapshot
                  # One stdout burst, without sleeps between reply and notifications.
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
              if [ "$mode" = exit ]; then exit 23; fi
              case "$line" in
                *\"configId\":\"effort\"*)
                  if [ "$mode" = reject-effort ]; then
                    printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":"Effort rejected"}}\n' "$id"
                    continue
                  fi
                  case "$line" in
                    *\"value\":\"high\"*) effort=high ;;
                    *\"value\":\"low\"*) effort=low ;;
                    *) exit 92 ;;
                  esac
                  ;;
                *\"configId\":\"mode\"*)
                  case "$line" in
                    *\"value\":\"plan\"*) permission=plan ;;
                    *\"value\":\"default\"*) permission=default ;;
                    *) exit 97 ;;
                  esac
                  ;;
                *\"configId\":\"model\"*)
                  case "$line" in
                    *\"value\":\"deep\"*) model=deep; effort=high ;;
                    *\"value\":\"fast\"*) model=fast ;;
                    *) exit 93 ;;
                  esac
                  ;;
                *) exit 94 ;;
              esac
              snapshot
              case "$mode" in
                waiting)
                  pending=$id
                  message 'selection waiting'
                  ;;
                reply-update|update-reply)
                  deep_options=$options
                  model=fast; effort=low; snapshot
                  printf '%s\n' "$(
                    if [ "$mode" = reply-update ]; then
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
            *\"method\":\"session/set_model\"*)
              case "$mode" in legacy|legacy-update|mixed) ;; *) exit 95 ;; esac
              case "$line" in *\"modelId\":\"deep\"*) ;; *) exit 96 ;; esac
              if [ "$mode" = legacy-update ]; then
                printf '%s\n' "$(
                  reply '{}'
                  printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"current_model_update","currentModelId":"fast"}}}'
                  message 'legacy ordering delivered'
                )"
              else
                model=deep
                reply '{}'
              fi
              ;;
            *\"method\":\"session/prompt\"*)
              if [ "$mode" = updates ]; then
                model=deep; effort=high; snapshot
                printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"config_option_update","configOptions":%s}}}\n' "$options"
                printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"wrong-session","update":{"sessionUpdate":"config_option_update","configOptions":[]}}}'
                message 'updates delivered'
                reply '{"stopReason":"end_turn"}'
              elif [ "$mode" = new-update ]; then
                # The immediate sentinel can arrive before SessionModel knows its session ID.
                # A post-connect prompt supplies a second ordered fence, without another snapshot.
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
