#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ruby - "$ROOT_DIR" <<'RUBY'
root = ARGV.fetch(0)
actions_path = File.join(root, "Android/app/src/main/java/com/rosan/installer/ui/page/airsend/runtime/AirSendRuntimeAction.kt")
state_path = File.join(root, "Android/app/src/main/java/com/rosan/installer/ui/page/airsend/runtime/AirSendRuntimeState.kt")
matrix_path = File.join(root, "docs/airsend-android-macos-parity.md")

actions_source = File.read(actions_path)
state_source = File.read(state_path)
matrix = File.read(matrix_path)

actions = actions_source.scan(/\bdata\s+(?:object|class)\s+(\w+)/).flatten.uniq
state_block = state_source[/data class AirSendRuntimeState\((.*?)\n\) \{/m, 1]
abort("Unable to parse AirSendRuntimeState") unless state_block
state_fields = state_block.scan(/\bval\s+(\w+)\s*:/).flatten.uniq

missing_actions = actions.reject { |name| matrix.include?(name) }
missing_fields = state_fields.reject { |name| matrix.include?(name) }
forbidden = matrix.scan(/\b(?:planned|placeholder)\b/i).uniq

unless missing_actions.empty?
  warn "Parity matrix is missing Android actions: #{missing_actions.join(', ')}"
end
unless missing_fields.empty?
  warn "Parity matrix is missing Android state fields: #{missing_fields.join(', ')}"
end
unless forbidden.empty?
  warn "Parity matrix contains forbidden unfinished statuses: #{forbidden.join(', ')}"
end

exit 1 unless missing_actions.empty? && missing_fields.empty? && forbidden.empty?
puts "AirSend parity matrix covers #{actions.length} actions and #{state_fields.length} state fields"
RUBY
