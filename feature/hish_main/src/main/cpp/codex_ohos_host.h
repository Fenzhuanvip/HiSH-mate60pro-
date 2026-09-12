#ifndef CODEX_OHOS_HOST_H
#define CODEX_OHOS_HOST_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t codex_ohos_host_start(const char* codex_home, const char* listen_url);
int32_t codex_ohos_host_is_running(void);
const char* codex_ohos_host_last_message(void);
const char* codex_ohos_host_server_url(void);
const char* codex_ohos_host_provider_config_json(const char* codex_home);
int32_t codex_ohos_host_save_provider_config(
    const char* codex_home,
    const char* base_url,
    const char* api_key,
    const char* model,
    const char* context_window,
    const char* model_auto_compact_token_limit);
const char* codex_ohos_host_provider_catalog_json(const char* codex_home);
int32_t codex_ohos_host_save_provider_catalog(const char* codex_home, const char* catalog_json);
const char* codex_ohos_host_skills_registry_json(const char* codex_home);
int32_t codex_ohos_host_save_skills_registry(const char* codex_home, const char* registry_json);
const char* codex_ohos_host_skills_repos_json(const char* codex_home);
int32_t codex_ohos_host_save_skills_repos(const char* codex_home, const char* repos_json);
const char* codex_ohos_host_compute_dir_hash(const char* dir_path);
const char* codex_ohos_host_prompts_registry_json(const char* codex_home);
int32_t codex_ohos_host_save_prompts_registry(const char* codex_home, const char* registry_json);
const char* codex_ohos_host_read_agents_md(const char* codex_home);
int32_t codex_ohos_host_write_agents_md(const char* codex_home, const char* content);

const char* codex_ohos_host_initialize(const char* config_json);
const char* codex_ohos_host_collaboration_mode_list(const char* params_json);
const char* codex_ohos_host_thread_start(const char* params_json);
const char* codex_ohos_host_thread_list(const char* params_json);
const char* codex_ohos_host_thread_read(const char* params_json);
const char* codex_ohos_host_thread_resume(const char* params_json);
const char* codex_ohos_host_thread_name_set(const char* params_json);
const char* codex_ohos_host_thread_archive(const char* params_json);
const char* codex_ohos_host_thread_compact_start(const char* params_json);
const char* codex_ohos_host_turn_start(const char* params_json);
const char* codex_ohos_host_turn_events(const char* thread_id, const char* turn_id);
const char* codex_ohos_host_turn_poll(const char* thread_id, const char* turn_id);
const char* codex_ohos_host_turn_interrupt(const char* thread_id, const char* turn_id);

const char* codex_ohos_host_approval_poll(void);
int32_t codex_ohos_host_approval_approve(const char* params_json);
int32_t codex_ohos_host_approval_decline(const char* params_json);

const char* codex_ohos_host_mcp_status_list(const char* params_json);
const char* codex_ohos_host_mcp_config_read(const char* params_json);
int32_t codex_ohos_host_mcp_config_write(const char* params_json);
int32_t codex_ohos_host_mcp_config_batch_write(const char* params_json);
int32_t codex_ohos_host_mcp_reload(void);
const char* codex_ohos_host_mcp_oauth_start(const char* params_json);

const char* codex_ohos_host_account_login(const char* params_json);
const char* codex_ohos_host_account_read(void);
const char* codex_ohos_host_check_workspace_access(const char* params_json);
const char* codex_ohos_host_token_usage_aggregate(const char* codex_home);

#ifdef __cplusplus
}
#endif

#endif
