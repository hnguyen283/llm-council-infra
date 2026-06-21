INSERT INTO prompt.standardized_prompt
    (key, schema_version, original_prompt_hash, f1, summary, source, status, created_at, updated_at, a1)
VALUES
    (
      'sp:v1:sha256:c04b18b2f387222e52c58be3f6c4041da6942eb2d8b47a7e93c869ee0efcef48',
      'standardized-prompt.v1',
      'sha256:c04b18b2f387222e52c58be3f6c4041da6942eb2d8b47a7e93c869ee0efcef48',
      '{"metadata":{"task_type":"test"},"instructions_requirements":{"objective":"test objective"},"context":{"audience":[]},"expected_outputs":{"output_mode":"test"},"data_inputs":{"missing_inputs":[]}}'::jsonb,
      '{"task_type":"test","objective":"test objective","audience":[],"output_mode":"test","missing_inputs":[],"has_a1":true,"has_f2":false,"has_a2":false}'::jsonb,
      '{"jobId": "test-job", "locale": "en_US", "originalPromptHash": "sha256:c04b18b2f387222e52c58be3f6c4041da6942eb2d8b47a7e93c869ee0efcef48", "originalPromptStored": false}'::jsonb,
      'ACTIVE',
      NOW(),
      NOW(),
      '{"sources": [], "conflicts": [], "self_eval": {"quality_band": "STRONG", "weighted_score": 95, "confidence_band": "HIGH", "critical_checks_pass": true}, "ambiguities": [], "draft_output": "This is a deterministic cached final report response!", "key_findings": [], "assumptions_used": [], "requirements_met": [], "degradation_notes": [], "requirements_unmet": [], "candidate_questions": [], "research_quality_scorecard": {"cost": {"gptCalls": 1, "geminiCalls": 1, "totalAiCalls": 2, "budgetedAiCalls": 15}, "lineage": {"jobId": "test-job-id", "sequenceName": "Research", "originalPromptHash": "sha256:c04b18b2f387222e52c58be3f6c4041da6942eb2d8b47a7e93c869ee0efcef48", "standardizedPromptKey": "sp:v1:sha256:c04b18b2f387222e52c58be3f6c4041da6942eb2d8b47a7e93c869ee0efcef48", "standardizedPromptSchemaVersion": "standardized-prompt.v1"}, "metrics": {"costEfficiency": 100, "sourceDiversity": 100, "answerUsefulness": 100, "evidenceCoverage": 100, "confidenceCalibration": 100, "contradictionHandling": 100}, "warnings": [], "qualityBand": "STRONG", "overallScore": 95, "schemaVersion": "research-quality-scorecard.v1"}}'::jsonb
    );
