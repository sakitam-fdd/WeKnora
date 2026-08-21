#!/usr/bin/env bash
set -euo pipefail

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git remote add tencent-upstream https://github.com/Tencent/WeKnora.git 2>/dev/null || true
git fetch --no-tags tencent-upstream refs/pull/2494/head:refs/remotes/tencent-upstream/pr-2494

set +e
git merge --no-commit --no-ff refs/remotes/tencent-upstream/pr-2494
merge_rc=$?
set -e

if [ "$merge_rc" -eq 0 ]; then
  echo "Expected the known current-main conflict, but upstream merged cleanly; refusing an unreviewed topology change."
  exit 1
fi

mapfile -t conflicts < <(git diff --name-only --diff-filter=U)
printf 'Conflicts: %s\n' "${conflicts[*]}"
if [ "${#conflicts[@]}" -ne 1 ] || [ "${conflicts[0]}" != "internal/application/service/session_knowledge_qa.go" ]; then
  echo "Unexpected conflict surface; aborting."
  exit 1
fi

# Keep current-main helper/session structure. The new resolver responsibility is
# isolated into its own file instead of deleting current Agent override behavior.
git show HEAD:internal/application/service/session.go > internal/application/service/session.go
git show HEAD:internal/application/service/session_qa_helpers.go > internal/application/service/session_qa_helpers.go

python3 <<'PY'
from pathlib import Path
import re

path = Path("internal/application/service/session_knowledge_qa.go")
s = path.read_text()

# Resolve the only real conflict by retaining current main's Agent override and
# long-term-memory setup. Rerank precedence is established later, after needsRAG.
pattern = re.compile(
    r"<<<<<<< HEAD\n(.*?)=======\n>>>>>>> refs/remotes/tencent-upstream/pr-2494\n",
    re.S,
)
matches = list(pattern.finditer(s))
if len(matches) != 1:
    raise SystemExit(f"expected exactly one conflict marker block, got {len(matches)}")
s = pattern.sub(lambda m: m.group(1), s, count=1)

# Upstream eagerly loads RetrievalConfig before it knows whether the turn is
# retrieval-backed. Current-main resolution keeps pure chat free of rerank work.
upstream_preload = '''\t// Load tenant-level retrieval config (nil is safe; used for rerank model fallback)
\tvar rc *types.RetrievalConfig
\tif tenant, err2 := s.tenantService.GetTenantByID(ctx, retrievalTenantID); err2 == nil {
\t\trc = tenant.RetrievalConfig
\t}

'''
if s.count(upstream_preload) != 1:
    raise SystemExit("upstream retrieval-config preload anchor changed")
s = s.replace(upstream_preload, "", 1)

upstream_resolver = '''\t// Resolve the rerank model: request override (hard-failing 400/403) then
\t// agent config, then tenant RetrievalConfig, then auto-detect.
\t// Only when retrieval actually runs.
\tvar agentRerankModelID string
\tif req.CustomAgent != nil {
\t\tagentRerankModelID = req.CustomAgent.Config.RerankModelID
\t}
\tif needsRAG {
\t\tchatManage.RerankModelID, err = s.resolveRerankModelID(ctx, req.RerankModelID, agentRerankModelID, rc)
\t\tif err != nil {
\t\t\treturn err
\t\t}
\t}

'''
current_main_resolver = '''\t// Resolve the final rerank model only for retrieval turns. Current main
\t// applies Agent overrides above; resolving here intentionally makes an
\t// explicit request override win while preserving all other Agent settings.
\tif needsRAG {
\t\tvar agentRerankModelID string
\t\tif req.CustomAgent != nil {
\t\t\tagentRerankModelID = req.CustomAgent.Config.RerankModelID
\t\t}

\t\tvar retrievalConfig *types.RetrievalConfig
\t\tif s.tenantService != nil {
\t\t\ttenant, tenantErr := s.tenantService.GetTenantByID(ctx, retrievalTenantID)
\t\t\tif tenantErr == nil && tenant != nil {
\t\t\t\tretrievalConfig = tenant.RetrievalConfig
\t\t\t} else if tenantErr != nil {
\t\t\t\tlogger.Warnf(ctx, "Failed to load tenant retrieval config for rerank resolution: %v", tenantErr)
\t\t\t}
\t\t}

\t\tchatManage.RerankModelID, err = s.resolveRerankModelID(
\t\t\tctx, req.RerankModelID, agentRerankModelID, retrievalConfig,
\t\t)
\t\tif err != nil {
\t\t\treturn err
\t\t}
\t}

'''
if s.count(upstream_resolver) != 1:
    raise SystemExit("upstream rerank resolver anchor changed")
s = s.replace(upstream_resolver, current_main_resolver, 1)

# Upstream applies Agent overrides after resolver because its helper no longer
# writes RerankModelID. We keep current main's helper and earlier invocation, so
# the later duplicate would incorrectly let Agent overwrite request override.
duplicate_agent_apply = '''\t// Apply custom agent overrides (system prompt, temperature, retrieval params,
\t// rewrite, fallback, FAQ strategy, history turns)
\ts.applyAgentOverridesToChatManage(ctx, req.CustomAgent, chatManage)

'''
if s.count(duplicate_agent_apply) != 2:
    raise SystemExit(f"expected two Agent override blocks after merge, got {s.count(duplicate_agent_apply)}")
idx = s.rfind(duplicate_agent_apply)
s = s[:idx] + s[idx + len(duplicate_agent_apply):]

if "<<<<<<<" in s or "=======" in s or ">>>>>>>" in s:
    raise SystemExit("unresolved conflict marker remains")
path.write_text(s)

# Isolate new rerank-resolution responsibility instead of editing the evolved
# session.go/session_qa_helpers.go files solely to host helper functions.
Path("internal/application/service/session_rerank_resolution.go").write_text(r'''package service

import (
    "context"
    "strings"

    apperrors "github.com/Tencent/WeKnora/internal/errors"
    "github.com/Tencent/WeKnora/internal/logger"
    "github.com/Tencent/WeKnora/internal/types"
    secutils "github.com/Tencent/WeKnora/internal/utils"
)

// ResolveRerankModel resolves an explicit rerank model ID or unique active-model name.
// Explicit invalid values fail closed instead of silently falling back to another model.
func (s *sessionService) ResolveRerankModel(ctx context.Context, requested string) (string, error) {
    requested = strings.TrimSpace(requested)
    if requested == "" {
        return "", nil
    }
    if s.modelService == nil {
        return "", apperrors.NewInternalServerError("model service not available")
    }

    models, err := s.modelService.ListModels(ctx)
    if err != nil {
        return "", err
    }

    var nameMatch string
    nameMatches := 0
    for _, model := range models {
        if model == nil || model.Type != types.ModelTypeRerank || model.Status != types.ModelStatusActive {
            continue
        }
        if model.ID == requested {
            return model.ID, nil
        }
        if model.Name == requested {
            nameMatch = model.ID
            nameMatches++
        }
    }

    if nameMatches > 1 {
        logger.Warnf(ctx, "Request provided ambiguous rerank model %s", secutils.SanitizeForLog(requested))
        return "", apperrors.NewBadRequestError("rerank_model_id matches multiple models")
    }
    if nameMatches == 1 {
        return nameMatch, nil
    }

    logger.Warnf(ctx, "Request provided invalid rerank model %s", secutils.SanitizeForLog(requested))
    return "", apperrors.NewForbiddenError("rerank model not found or not accessible")
}

// resolveRerankModelID applies the effective precedence for retrieval requests:
// request override > Custom Agent > tenant RetrievalConfig > first active rerank model.
func (s *sessionService) resolveRerankModelID(
    ctx context.Context,
    requested string,
    agentRerankModelID string,
    retrievalConfig *types.RetrievalConfig,
) (string, error) {
    if strings.TrimSpace(requested) != "" {
        resolved, err := s.ResolveRerankModel(ctx, requested)
        if err != nil {
            return "", err
        }
        logger.Infof(ctx, "Using request rerank model override: %s", secutils.SanitizeForLog(resolved))
        return resolved, nil
    }

    if strings.TrimSpace(agentRerankModelID) != "" {
        resolved, err := s.ResolveRerankModel(ctx, agentRerankModelID)
        if err != nil {
            return "", err
        }
        logger.Infof(ctx, "Using custom agent rerank model: %s", secutils.SanitizeForLog(resolved))
        return resolved, nil
    }

    if retrievalConfig != nil && retrievalConfig.RerankModelID != "" {
        logger.Infof(ctx, "Using tenant retrieval config rerank model: %s",
            secutils.SanitizeForLog(retrievalConfig.RerankModelID))
        return retrievalConfig.RerankModelID, nil
    }

    if s.modelService == nil {
        return "", nil
    }
    models, err := s.modelService.ListModels(ctx)
    if err != nil {
        logger.Warnf(ctx, "Failed to list rerank models for auto-detect, skipping rerank: %v", err)
        return "", nil
    }
    for _, model := range models {
        if model != nil && model.Type == types.ModelTypeRerank && model.Status == types.ModelStatusActive {
            logger.Infof(ctx, "Auto-detected first active rerank model: %s", secutils.SanitizeForLog(model.ID))
            return model.ID, nil
        }
    }
    return "", nil
}
''')

# Replace upstream's helper-structure assertion with a current-main ordering
# regression: Agent is applied first, then explicit request must overwrite only
# the final RerankModelID.
test_path = Path("internal/application/service/session_rerank_resolution_test.go")
test_src = test_path.read_text()
marker = "// --- applyAgentOverridesToChatManage regression ---"
if test_src.count(marker) != 1:
    raise SystemExit("upstream rerank structural-test marker changed")
prefix = test_src.split(marker, 1)[0]
test_src = prefix + r'''// --- current-main ordering regression ---

func TestCurrentMainRerankResolution_RequestOverridesPreAppliedAgent(t *testing.T) {
    ms := &rerankResolutionModelService{models: activeRerankModels()}
    svc := newRerankResolutionService(ms)
    ctx := context.Background()

    cm := &types.ChatManage{}
    agent := &types.CustomAgent{Config: types.CustomAgentConfig{RerankModelID: "rerank-2"}}
    svc.applyAgentOverridesToChatManage(ctx, agent, cm)
    require.Equal(t, "rerank-2", cm.RerankModelID)

    resolved, err := svc.resolveRerankModelID(ctx,
        "rerank-1", agent.Config.RerankModelID, &types.RetrievalConfig{RerankModelID: "tenant-model"})
    require.NoError(t, err)
    cm.RerankModelID = resolved
    assert.Equal(t, "rerank-1", cm.RerankModelID)
}
'''
test_path.write_text(test_src)
PY

gofmt -w \
  internal/application/service/session_knowledge_qa.go \
  internal/application/service/session_rerank_resolution.go \
  internal/application/service/session_rerank_resolution_test.go \
  internal/handler/session/qa.go \
  internal/handler/session/search_knowledge_test.go \
  internal/handler/session/types.go \
  internal/im/cmd_search.go \
  internal/types/interfaces/session.go \
  internal/types/qa_request.go

git add -A
if git diff --name-only --diff-filter=U | grep -q .; then
  echo "Unresolved conflicts remain"
  git diff --name-only --diff-filter=U
  exit 1
fi
git diff --cached --check

echo "=== resolver semantics ==="
go test ./internal/application/service -run 'TestResolveRerankModel|TestCurrentMainRerankResolution' -count=1

echo "=== HTTP error mapping / request wiring ==="
go test ./internal/handler/session -run 'TestSearchKnowledge' -count=1

echo "=== IM integration compile ==="
go test ./internal/im -run '^$' -count=1

# Temporary automation files are not part of the final business-code diff.
rm -f .github/workflows/tmp-pr2494-resolve.yml .github/scripts/resolve-pr2494.sh
git add -A
git diff --cached --check
git status --short

git commit -m "feat(chat): resolve rerank model wiring from upstream #2494"
git push origin HEAD:fix/pr-2494-rerank-resolution
