#!/usr/bin/env bash
# D2: table-tests for the pure channel-mapping helpers in misc/happier-common.func.
set -u
cd "$(dirname "$0")" || exit 1
# shellcheck disable=SC1091 # test-local helper, resolved at runtime
source ./lib.sh

# The shared lib expects the framework msg_* helpers; stub them.
msg_warn() { :; }
msg_error() { echo "ERR: $*" >&2; }
msg_info() { :; }
msg_ok() { :; }
# shellcheck disable=SC1091 # unit under test, resolved at runtime
source ../../misc/happier-common.func

test_normalize_happier_channel() {
  assert_eq "$(normalize_happier_channel "")" "stable" "empty->stable"
  assert_eq "$(normalize_happier_channel "stable")" "stable" "stable"
  assert_eq "$(normalize_happier_channel "PREVIEW")" "preview" "case-insensitive"
  assert_eq "$(normalize_happier_channel "  dev  ")" "dev" "whitespace-trimmed"
  assert_eq "$(normalize_happier_channel $'preview\r')" "preview" "CRLF-stripped"
  assert_eq "$(normalize_happier_channel "publicdev")" "dev" "publicdev alias"
  assert_fail "unknown channel rejected" normalize_happier_channel "nightly"
}

test_channel_cli_name() {
  assert_eq "$(channel_cli_name stable)" "happier" "stable cli"
  assert_eq "$(channel_cli_name preview)" "hprev" "preview cli"
  assert_eq "$(channel_cli_name dev)" "hdev" "dev cli"
  assert_fail "bad channel rejected" channel_cli_name bogus
}

test_channel_suffix_and_derived_paths() {
  assert_eq "$(channel_suffix stable)" "" "stable suffix"
  assert_eq "$(channel_suffix preview)" "-preview" "preview suffix"
  assert_eq "$(channel_suffix dev)" "-dev" "dev suffix"
  assert_eq "$(channel_relay_service_name stable)" "happier-server" "stable relay"
  assert_eq "$(channel_relay_service_name dev)" "happier-server-dev" "dev relay"
  assert_eq "$(channel_data_dir preview)" "/var/lib/happier-preview" "preview data dir"
  assert_eq "$(channel_config_env_path stable)" "/etc/happier/server.env" "stable env path"
  assert_eq "$(channel_config_env_path dev)" "/etc/happier-dev/server.env" "dev env path"
  assert_eq "$(channel_state_path preview)" "/opt/happier-preview/self-host-state.json" "preview state"
  assert_eq "$(channel_ui_current_dir stable)" "/var/lib/happier/ui-web/current" "stable ui dir"
  assert_fail "bad channel relay rejected" channel_relay_service_name bogus
}

test_channel_hosted_webapp_url() {
  assert_eq "$(channel_hosted_webapp_url stable)" "https://app.happier.dev" "stable webapp"
  assert_eq "$(channel_hosted_webapp_url preview)" "https://app.happier.dev" "preview webapp"
  assert_eq "$(channel_hosted_webapp_url dev)" "" "dev has no hosted webapp"
}

test_ui_release_tags_for_channel() {
  assert_eq "$(ui_release_tags_for_channel stable)" "ui-web-stable" "stable tags"
  assert_eq "$(ui_release_tags_for_channel preview)" $'ui-web-preview\nui-web-stable' "preview fallback chain"
  assert_eq "$(ui_release_tags_for_channel dev)" $'ui-web-dev\nui-web-preview\nui-web-stable' "dev fallback chain"
}

test_channel_default_stack_package() {
  assert_eq "$(channel_default_stack_package stable "")" "@happier-dev/stack@latest" "stable default"
  assert_eq "$(channel_default_stack_package preview "")" "@happier-dev/stack@next" "preview default"
  assert_eq "$(channel_default_stack_package dev "")" "@happier-dev/stack@latest" "dev default"
  assert_eq "$(channel_default_stack_package stable "@happier-dev/stack@preview")" "@happier-dev/stack@next" "preview dist-tag back-compat"
  assert_eq "$(channel_default_stack_package preview "@happier-dev/stack@1.2.3")" "@happier-dev/stack@1.2.3" "explicit spec wins"
}

run_tests
