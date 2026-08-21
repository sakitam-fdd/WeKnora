package service

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
